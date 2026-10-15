// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AggregatorV3Interface} from "./MockPriceFeed.sol";

contract AproxPerp is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    AggregatorV3Interface public immutable priceFeed;
    address public owner;
    uint256 public liquidityReserve;

    mapping(address => uint256) public freeBalance;
    mapping(address => Position) public positions;

    struct Position {
        bool isOpen;
        bool isLong;
        uint8 leverage;
        uint256 collateral;
        int256 entryPrice;
        uint256 openedAt;
    }

    uint8[3] private VALID_LEVERAGES = [2, 5, 10];
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 2000;
    uint256 public constant KEEPER_REWARD_BPS = 500;

    // Maximum age of oracle price before it is considered stale (1 hour)
    uint256 public constant MAX_ORACLE_STALENESS = 3600;

    error NotOwner();
    error InvalidLeverage();
    error InsufficientBalance();
    error PositionAlreadyOpen();
    error NoOpenPosition();
    error InsufficientReserve(uint256 required, uint256 available);
    error InvalidPrice();
    error StalePrice(uint256 updatedAt, uint256 blockTimestamp);
    error PositionHealthy();
    error ZeroAmount();
    error ZeroAddress();

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event PositionOpened(address indexed user, bool isLong, uint8 leverage, uint256 collateral, int256 entryPrice);
    event PositionClosed(address indexed user, int256 pnl, uint256 payout, int256 exitPrice);
    event Liquidated(address indexed trader, address indexed keeper, uint256 keeperReward);
    event ReserveAdded(uint256 amount, uint256 newTotal);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _usdc, address _priceFeed, uint256 _initialReserve, address _owner) {
        if (_usdc == address(0) || _priceFeed == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        owner = _owner;
        usdc = IERC20(_usdc);
        priceFeed = AggregatorV3Interface(_priceFeed);

        if (_initialReserve > 0) {
            liquidityReserve = _initialReserve;
            usdc.safeTransferFrom(msg.sender, address(this), _initialReserve);
        }
    }

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        freeBalance[msg.sender] += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (freeBalance[msg.sender] < amount) revert InsufficientBalance();

        freeBalance[msg.sender] -= amount;
        usdc.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function openPosition(bool isLong, uint8 leverage, uint256 collateral) external nonReentrant {
        if (!_isValidLeverage(leverage)) revert InvalidLeverage();
        if (collateral == 0) revert ZeroAmount();
        if (freeBalance[msg.sender] < collateral) revert InsufficientBalance();
        if (positions[msg.sender].isOpen) revert PositionAlreadyOpen();

        uint256 required = collateral * uint256(leverage);
        if (required > liquidityReserve) revert InsufficientReserve(required, liquidityReserve);

        (, int256 entryPrice,, uint256 entryUpdatedAt,) = priceFeed.latestRoundData();
        if (entryPrice <= 0) revert InvalidPrice();
        if (block.timestamp - entryUpdatedAt > MAX_ORACLE_STALENESS) revert StalePrice(entryUpdatedAt, block.timestamp);

        freeBalance[msg.sender] -= collateral;
        positions[msg.sender] = Position({
            isOpen: true,
            isLong: isLong,
            leverage: leverage,
            collateral: collateral,
            entryPrice: entryPrice,
            openedAt: block.timestamp
        });

        emit PositionOpened(msg.sender, isLong, leverage, collateral, entryPrice);
    }

    function closePosition() external nonReentrant {
        Position memory pos = positions[msg.sender];
        if (!pos.isOpen) revert NoOpenPosition();

        (, int256 exitPrice,, uint256 exitUpdatedAt,) = priceFeed.latestRoundData();
        if (exitPrice <= 0) revert InvalidPrice();
        if (block.timestamp - exitUpdatedAt > MAX_ORACLE_STALENESS) revert StalePrice(exitUpdatedAt, block.timestamp);

        int256 pnl = _computePnL(pos.isLong, pos.collateral, pos.leverage, pos.entryPrice, exitPrice);

        int256 payoutInt = int256(pos.collateral) + pnl;
        uint256 payout = payoutInt > 0 ? uint256(payoutInt) : 0;
        uint256 actualPayout = payout;

        if (pnl > 0) {
            uint256 maxPayout = pos.collateral + liquidityReserve;
            if (actualPayout > maxPayout) {
                actualPayout = maxPayout;
            }

            uint256 profitAmount = actualPayout > pos.collateral ? actualPayout - pos.collateral : 0;
            if (profitAmount > 0) {
                liquidityReserve -= profitAmount;
            }
        } else if (pnl < 0) {
            // Loss is bounded by collateral (payout floor is 0, so forfeited = collateral - payout).
            // Cap reserve credit to actual forfeited collateral to prevent phantom reserve inflation.
            uint256 forfeited = pos.collateral - actualPayout;
            liquidityReserve += forfeited;
        }

        delete positions[msg.sender];
        freeBalance[msg.sender] += actualPayout;

        emit PositionClosed(msg.sender, pnl, actualPayout, exitPrice);
    }

    function liquidate(address trader) external nonReentrant {
        Position memory pos = positions[trader];
        if (!pos.isOpen) revert NoOpenPosition();

        (, int256 currentPrice,, uint256 liqUpdatedAt,) = priceFeed.latestRoundData();
        if (currentPrice <= 0) revert InvalidPrice();
        if (block.timestamp - liqUpdatedAt > MAX_ORACLE_STALENESS) revert StalePrice(liqUpdatedAt, block.timestamp);

        int256 currentPnL = _computeCurrentValue(positions[trader]);
        int256 remainingCollateralInt = int256(pos.collateral) + currentPnL;
        uint256 remainingCollateral = remainingCollateralInt > 0 ? uint256(remainingCollateralInt) : 0;

        if (remainingCollateral * 10_000 >= pos.collateral * LIQUIDATION_THRESHOLD_BPS) {
            revert PositionHealthy();
        }

        // Keeper reward is funded from actual forfeited collateral.
        // remainingCollateral is the real residual; keeperReward <= remainingCollateral.
        uint256 keeperReward = remainingCollateral >= (pos.collateral * KEEPER_REWARD_BPS) / 10_000
            ? (pos.collateral * KEEPER_REWARD_BPS) / 10_000
            : remainingCollateral;

        // Return what's left after keeper reward to trader; rest is forfeited to reserve.
        uint256 traderReturn = remainingCollateral - keeperReward;
        uint256 forfeited = pos.collateral - remainingCollateral; // lost to reserve

        delete positions[trader];
        freeBalance[msg.sender] += keeperReward;
        if (traderReturn > 0) freeBalance[trader] += traderReturn;
        liquidityReserve += forfeited;

        emit Liquidated(trader, msg.sender, keeperReward);
    }

    function addToReserve(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        liquidityReserve += amount;

        emit ReserveAdded(amount, liquidityReserve);
    }

    function getPosition(address trader) external view returns (Position memory) {
        return positions[trader];
    }

    function getFreeBalance(address trader) external view returns (uint256) {
        return freeBalance[trader];
    }

    function getReserveBalance() external view returns (uint256) {
        return liquidityReserve;
    }

    function _computePnL(bool isLong, uint256 collateral, uint8 leverage, int256 entryPrice, int256 exitPrice)
        internal
        pure
        returns (int256 pnl)
    {
        int256 priceDelta = exitPrice - entryPrice;
        if (!isLong) priceDelta = -priceDelta;

        pnl = (int256(collateral) * int256(uint256(leverage)) * priceDelta) / entryPrice;
    }

    function _computeCurrentValue(Position storage pos) internal view returns (int256 currentPnL) {
        (, int256 currentPrice,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (currentPrice <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) revert StalePrice(updatedAt, block.timestamp);

        currentPnL = _computePnL(pos.isLong, pos.collateral, pos.leverage, pos.entryPrice, currentPrice);
    }

    function _isValidLeverage(uint8 leverage) internal view returns (bool) {
        for (uint256 i = 0; i < VALID_LEVERAGES.length; i++) {
            if (VALID_LEVERAGES[i] == leverage) {
                return true;
            }
        }
        return false;
    }
}
