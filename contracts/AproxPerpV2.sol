// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * AproxPerpV2 — Peer-to-Peer BTC/USD Perpetuals on Arc
 *
 * Design principles:
 * - Zero protocol reserve: Longs and Shorts are matched against each other.
 *   The contract is pure escrow and settlement — it never risks its own capital.
 * - Partial fills: a position fills up to the available counterpart liquidity.
 *   Any unmatched remainder stays PENDING and can be cancelled at any time.
 * - Peer-to-peer settlement: when either side closes, PnL is computed from the
 *   oracle price and settled between the two locked collateral pools.
 * - Gasless: all calls are compatible with ERC-4337 (no tx.origin checks).
 * - USDC-denominated: all amounts in 6-decimal USDC.
 *
 * Order lifecycle:
 *   openOrder()  → PENDING (collateral locked, awaiting counterpart)
 *   openOrder()  → triggers matchOrders() → matched pairs become ACTIVE
 *   closeOrder() → PnL settled between counterparts, both freed
 *   cancelOrder() → PENDING positions refunded, no counterpart involved
 *   liquidate()  → keeper can liquidate undercollateralised ACTIVE positions
 *
 * Matching algorithm:
 *   FIFO within each side (Long queue and Short queue).
 *   Partial fills are supported — an order can be split across multiple counterparts.
 *   Both sides must have the same leverage. Orders are matched by notional (collateral × leverage).
 *
 * Oracle:
 *   AggregatorV3Interface — 8-decimal price feed. Same interface as MockPriceFeed.sol.
 *   1 hour staleness limit.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract AproxPerpV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Types ──────────────────────────────────────────────────────────────────

    enum OrderStatus {
        PENDING,
        ACTIVE,
        CLOSED,
        CANCELLED
    }

    struct Order {
        address trader;
        bool isLong;
        uint8 leverage;
        // Total collateral this order represents (6-dec USDC)
        uint256 collateral;
        // How much of collateral is currently matched and active
        uint256 matchedCollateral;
        // How much collateral is still pending a counterpart
        uint256 pendingCollateral;
        // Weighted-average entry price across all matched fills (8-dec)
        int256 entryPrice;
        // Timestamp of the first match (used for funding rate / age display)
        uint256 matchedAt;
        // Timestamp the order was created
        uint256 openedAt;
        OrderStatus status;
    }

    // A single matched pair — tracks which two order IDs are matched and how much
    struct MatchedPair {
        uint256 longOrderId;
        uint256 shortOrderId;
        // Collateral on each side that is locked in this pair (same value for both)
        uint256 lockedCollateral;
        // Entry prices recorded at match time (may differ slightly if filled over time)
        int256 longEntryPrice;
        int256 shortEntryPrice;
        bool settled;
    }

    // ── State ─────────────────────────────────────────────────────────────────

    IERC20 public immutable usdc;
    AggregatorV3Interface public immutable priceFeed;
    address public owner;
    address public feeRecipient;

    uint256 public nextOrderId;
    uint256 public nextPairId;

    mapping(uint256 => Order) public orders;
    mapping(uint256 => MatchedPair) public pairs;

    // Per-trader free balance (settled payouts waiting to be withdrawn)
    mapping(address => uint256) public freeBalance;

    // Queues of pending order IDs per side+leverage
    // key: keccak256(abi.encode(isLong, leverage))
    mapping(bytes32 => uint256[]) private _pendingQueues;

    // Per-order list of pair IDs it participates in
    mapping(uint256 => uint256[]) public orderPairs;

    // Valid leverages
    uint8[3] private VALID_LEVERAGES = [2, 5, 10];

    uint256 public constant MAX_ORACLE_STALENESS = 3600; // 1 hour
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 2000; // 20% of collateral remaining
    uint256 public constant KEEPER_REWARD_BPS = 500; // 5% of original collateral

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotOwner();
    error InvalidLeverage();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidPrice();
    error StalePrice(uint256 updatedAt, uint256 blockTimestamp);
    error NotTrader();
    error OrderNotPending();
    error OrderNotActive();
    error PositionHealthy();
    error NothingToLiquidate();
    error InsufficientFreeBalance();

    // ── Events ────────────────────────────────────────────────────────────────

    event Deposited(address indexed trader, uint256 amount);
    event Withdrawn(address indexed trader, uint256 amount);
    event OrderOpened(uint256 indexed orderId, address indexed trader, bool isLong, uint8 leverage, uint256 collateral);
    event OrderMatched(uint256 indexed pairId, uint256 indexed longOrderId, uint256 indexed shortOrderId, uint256 lockedCollateral, int256 price);
    event PositionTransferred(
        uint256 indexed oldPairId,
        uint256 indexed newPairId,
        uint256 indexed survivingOrderId,
        address survivingTrader,
        int256 newEntryPrice
    );
    event OrderClosed(uint256 indexed orderId, address indexed trader, int256 pnl, uint256 payout);
    event OrderCancelled(uint256 indexed orderId, address indexed trader, uint256 refund);
    event Liquidated(uint256 indexed orderId, address indexed trader, address indexed keeper, uint256 keeperReward);

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address _usdc, address _priceFeed, address _owner, address _feeRecipient) {
        if (_usdc == address(0) || _priceFeed == address(0)) revert ZeroAddress();
        if (_owner == address(0) || _feeRecipient == address(0)) revert ZeroAddress();

        usdc = IERC20(_usdc);
        priceFeed = AggregatorV3Interface(_priceFeed);
        owner = _owner;
        feeRecipient = _feeRecipient;
        nextOrderId = 1;
        nextPairId = 1;
    }

    // ── Deposit / Withdraw ────────────────────────────────────────────────────

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        freeBalance[msg.sender] += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (freeBalance[msg.sender] < amount) revert InsufficientFreeBalance();
        freeBalance[msg.sender] -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ── Open Order ────────────────────────────────────────────────────────────

    /**
     * openOrder — place a Long or Short order.
     *
     * Collateral is taken from the caller's free balance.
     * The order is immediately matched against any existing counterpart orders
     * in the opposite queue (FIFO, same leverage). Any unmatched remainder
     * stays PENDING and can be cancelled later.
     *
     * @param isLong   true = Long (profit when BTC rises), false = Short
     * @param leverage 2, 5, or 10
     * @param collateral amount in 6-decimal USDC
     */
    function openOrder(bool isLong, uint8 leverage, uint256 collateral) external nonReentrant {
        if (!_isValidLeverage(leverage)) revert InvalidLeverage();
        if (collateral == 0) revert ZeroAmount();
        if (freeBalance[msg.sender] < collateral) revert InsufficientFreeBalance();

        (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (price <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) revert StalePrice(updatedAt, block.timestamp);

        // Deduct from free balance
        freeBalance[msg.sender] -= collateral;

        uint256 orderId = nextOrderId++;
        orders[orderId] = Order({
            trader: msg.sender,
            isLong: isLong,
            leverage: leverage,
            collateral: collateral,
            matchedCollateral: 0,
            pendingCollateral: collateral,
            entryPrice: 0,
            matchedAt: 0,
            openedAt: block.timestamp,
            status: OrderStatus.PENDING
        });

        emit OrderOpened(orderId, msg.sender, isLong, leverage, collateral);

        // Try to match immediately
        _matchOrder(orderId, price);
    }

    // ── Internal Matching ─────────────────────────────────────────────────────

    function _queueKey(bool isLong, uint8 leverage) internal pure returns (bytes32) {
        return keccak256(abi.encode(isLong, leverage));
    }

    function _matchOrder(uint256 newOrderId, int256 currentPrice) internal {
        Order storage newOrder = orders[newOrderId];
        bool counterIsLong = !newOrder.isLong;
        bytes32 counterKey = _queueKey(counterIsLong, newOrder.leverage);
        uint256[] storage counterQueue = _pendingQueues[counterKey];

        uint256 i = 0;
        while (i < counterQueue.length && newOrder.pendingCollateral > 0) {
            uint256 counterId = counterQueue[i];
            Order storage counterOrder = orders[counterId];

            // Skip stale entries (cancelled or fully matched)
            if (counterOrder.status == OrderStatus.CANCELLED || counterOrder.pendingCollateral == 0) {
                _removeFromQueue(counterQueue, i);
                continue;
            }

            // How much can we match?
            uint256 fillAmount = newOrder.pendingCollateral < counterOrder.pendingCollateral
                ? newOrder.pendingCollateral
                : counterOrder.pendingCollateral;

            // Record matched pair
            uint256 pairId = nextPairId++;
            uint256 longOrderId = newOrder.isLong ? newOrderId : counterId;
            uint256 shortOrderId = newOrder.isLong ? counterId : newOrderId;

            pairs[pairId] = MatchedPair({
                longOrderId: longOrderId,
                shortOrderId: shortOrderId,
                lockedCollateral: fillAmount,
                longEntryPrice: currentPrice,
                shortEntryPrice: currentPrice,
                settled: false
            });

            orderPairs[newOrderId].push(pairId);
            orderPairs[counterId].push(pairId);

            // Update new order
            _applyFill(newOrder, fillAmount, currentPrice);

            // Update counter order
            _applyFill(counterOrder, fillAmount, currentPrice);
            if (counterOrder.pendingCollateral == 0) {
                counterOrder.status = OrderStatus.ACTIVE;
                _removeFromQueue(counterQueue, i);
                // Don't increment i — we just removed element at i
            } else {
                i++;
            }

            emit OrderMatched(pairId, longOrderId, shortOrderId, fillAmount, currentPrice);
        }

        // Update new order status
        if (newOrder.pendingCollateral == 0) {
            newOrder.status = OrderStatus.ACTIVE;
        } else if (newOrder.matchedCollateral > 0) {
            // Partially matched — stays in queue for the pending remainder
            newOrder.status = OrderStatus.PENDING;
            _pendingQueues[_queueKey(newOrder.isLong, newOrder.leverage)].push(newOrderId);
        } else {
            // Nothing matched — fully pending
            newOrder.status = OrderStatus.PENDING;
            _pendingQueues[_queueKey(newOrder.isLong, newOrder.leverage)].push(newOrderId);
        }
    }

    function _applyFill(Order storage order, uint256 fillAmount, int256 price) internal {
        // Weighted-average entry price
        uint256 prevMatched = order.matchedCollateral;
        uint256 newMatched = prevMatched + fillAmount;
        if (prevMatched == 0) {
            order.entryPrice = price;
        } else {
            // Weighted average
            order.entryPrice = int256((uint256(order.entryPrice) * prevMatched + uint256(price) * fillAmount) / newMatched);
        }
        order.matchedCollateral = newMatched;
        order.pendingCollateral -= fillAmount;
        if (order.matchedAt == 0) order.matchedAt = block.timestamp;
    }

    function _removeFromQueue(uint256[] storage queue, uint256 index) internal {
        queue[index] = queue[queue.length - 1];
        queue.pop();
    }

    // ── Close Order ───────────────────────────────────────────────────────────

    /**
     * closeOrder — settle all matched pairs for an order and refund any pending remainder.
     *
     * For each matched pair, the closer side is settled at the current oracle price.
     * The counterparty side is transferred to a new counterpart from the opposite
     * pending queue when available; otherwise that collateral is re-queued as pending.
     */
    function closeOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        if (order.trader != msg.sender) revert NotTrader();
        if (order.status == OrderStatus.CLOSED || order.status == OrderStatus.CANCELLED) revert OrderNotActive();

        (, int256 exitPrice,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (exitPrice <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) revert StalePrice(updatedAt, block.timestamp);

        uint256 totalPayout = 0;
        int256 totalPnl = 0;

        uint256[] storage pairIds = orderPairs[orderId];
        for (uint256 i = 0; i < pairIds.length; i++) {
            uint256 pairId = pairIds[i];
            MatchedPair storage pair = pairs[pairId];
            if (pair.settled) continue;

            uint256 locked = pair.lockedCollateral;
            int256 pnl = _computePnlForOrderInPair(pair, orderId, exitPrice);
            int256 payoutInt = int256(locked) + pnl;
            uint256 closerPayout = payoutInt > 0 ? uint256(payoutInt) : 0;

            totalPnl += pnl;
            totalPayout += closerPayout;

            pair.settled = true;

            if (order.matchedCollateral >= locked) {
                order.matchedCollateral -= locked;
            } else {
                order.matchedCollateral = 0;
            }

            uint256 counterOrderId = pair.longOrderId == orderId ? pair.shortOrderId : pair.longOrderId;
            Order storage counterOrder = orders[counterOrderId];

            (bool transferred, uint256 newPairId) =
                _transferCounterpartyPosition(counterOrderId, order.isLong, locked, exitPrice);

            if (!transferred) {
                if (counterOrder.matchedCollateral >= locked) {
                    counterOrder.matchedCollateral -= locked;
                } else {
                    counterOrder.matchedCollateral = 0;
                }

                // The combined pool for this pair was 2 * locked.
                // The closer took `closerPayout` from it.
                // What remains for the surviving counterpart is the difference.
                uint256 combined = locked * 2;
                uint256 counterCollateral = combined > closerPayout ? combined - closerPayout : 0;
                counterOrder.pendingCollateral += counterCollateral;
                _ensureQueued(counterOrderId);
            }

            _recomputeEntryFromActivePairs(counterOrderId);

            if (_hasActiveUnsettledPair(counterOrderId)) {
                counterOrder.status = OrderStatus.ACTIVE;
            } else if (counterOrder.pendingCollateral > 0) {
                counterOrder.status = OrderStatus.PENDING;
                _ensureQueued(counterOrderId);
            }

            if (transferred) {
                emit PositionTransferred(
                    pairId,
                    newPairId,
                    counterOrderId,
                    counterOrder.trader,
                    counterOrder.entryPrice
                );
            }
        }

        // Refund any pending (unmatched) collateral
        if (order.pendingCollateral > 0) {
            totalPayout += order.pendingCollateral;
            order.pendingCollateral = 0;
        }

        order.matchedCollateral = 0;
        order.entryPrice = 0;
        order.status = OrderStatus.CLOSED;
        freeBalance[msg.sender] += totalPayout;

        emit OrderClosed(orderId, msg.sender, totalPnl, totalPayout);
    }

    function _computePnlForOrderInPair(MatchedPair storage pair, uint256 orderId, int256 exitPrice)
        internal
        view
        returns (int256 pnl)
    {
        bool isLong = pair.longOrderId == orderId;
        int256 entryPrice = isLong ? pair.longEntryPrice : pair.shortEntryPrice;
        int256 priceDelta = exitPrice - entryPrice;
        if (!isLong) priceDelta = -priceDelta;

        Order storage o = orders[orderId];
        pnl = (int256(pair.lockedCollateral) * int256(uint256(o.leverage)) * priceDelta) / entryPrice;
    }

    function _transferCounterpartyPosition(
        uint256 survivingOrderId,
        bool neededIsLong,
        uint256 lockedCollateral,
        int256 currentPrice
    ) internal returns (bool transferred, uint256 newPairId) {
        Order storage surviving = orders[survivingOrderId];
        bytes32 queueKey = _queueKey(neededIsLong, surviving.leverage);
        uint256[] storage queue = _pendingQueues[queueKey];

        uint256 i = 0;
        while (i < queue.length) {
            uint256 candidateId = queue[i];
            if (candidateId == survivingOrderId) {
                i++;
                continue;
            }

            Order storage candidate = orders[candidateId];

            if (
                candidate.status == OrderStatus.CANCELLED || candidate.status == OrderStatus.CLOSED
                    || candidate.pendingCollateral == 0 || candidate.leverage != surviving.leverage
                    || candidate.isLong != neededIsLong
            ) {
                _removeFromQueue(queue, i);
                continue;
            }

            if (candidate.pendingCollateral < lockedCollateral) {
                i++;
                continue;
            }

            newPairId = nextPairId++;
            uint256 longOrderId = surviving.isLong ? survivingOrderId : candidateId;
            uint256 shortOrderId = surviving.isLong ? candidateId : survivingOrderId;

            pairs[newPairId] = MatchedPair({
                longOrderId: longOrderId,
                shortOrderId: shortOrderId,
                lockedCollateral: lockedCollateral,
                longEntryPrice: currentPrice,
                shortEntryPrice: currentPrice,
                settled: false
            });

            orderPairs[survivingOrderId].push(newPairId);
            orderPairs[candidateId].push(newPairId);

            _applyFill(candidate, lockedCollateral, currentPrice);

            if (candidate.pendingCollateral == 0) {
                candidate.status = OrderStatus.ACTIVE;
                _removeFromQueue(queue, i);
            } else {
                candidate.status = OrderStatus.PENDING;
            }

            emit OrderMatched(newPairId, longOrderId, shortOrderId, lockedCollateral, currentPrice);

            transferred = true;
            return (transferred, newPairId);
        }

        return (false, 0);
    }

    function _ensureQueued(uint256 orderId) internal {
        Order storage order = orders[orderId];
        bytes32 key = _queueKey(order.isLong, order.leverage);
        uint256[] storage queue = _pendingQueues[key];

        for (uint256 i = 0; i < queue.length; i++) {
            if (queue[i] == orderId) {
                return;
            }
        }

        queue.push(orderId);
    }

    function _hasActiveUnsettledPair(uint256 orderId) internal view returns (bool) {
        uint256[] storage pairIds = orderPairs[orderId];
        for (uint256 i = 0; i < pairIds.length; i++) {
            if (!pairs[pairIds[i]].settled) return true;
        }
        return false;
    }

    function _recomputeEntryFromActivePairs(uint256 orderId) internal {
        Order storage order = orders[orderId];
        uint256[] storage pairIds = orderPairs[orderId];

        uint256 totalMatched = 0;
        uint256 weightedSum = 0;

        for (uint256 i = 0; i < pairIds.length; i++) {
            MatchedPair storage pair = pairs[pairIds[i]];
            if (pair.settled) continue;

            uint256 locked = pair.lockedCollateral;
            int256 entry = pair.longOrderId == orderId ? pair.longEntryPrice : pair.shortEntryPrice;

            totalMatched += locked;
            weightedSum += uint256(entry) * locked;
        }

        order.matchedCollateral = totalMatched;
        if (totalMatched == 0) {
            order.entryPrice = 0;
            return;
        }

        order.entryPrice = int256(weightedSum / totalMatched);
    }

    function _settlePair(MatchedPair storage pair, uint256 closingOrderId, int256 exitPrice)
        internal
        view
        returns (uint256 closerPayout, uint256 counterPayout, int256 pnl)
    {
        bool closerIsLong = pair.longOrderId == closingOrderId;
        int256 entryPrice = closerIsLong ? pair.longEntryPrice : pair.shortEntryPrice;
        uint256 locked = pair.lockedCollateral;

        // PnL for the closer (positive = profit, negative = loss)
        int256 priceDelta = exitPrice - entryPrice;
        if (!closerIsLong) priceDelta = -priceDelta;

        Order storage closingOrder = orders[closingOrderId];
        pnl = (int256(locked) * int256(uint256(closingOrder.leverage)) * priceDelta) / entryPrice;

        int256 closerPayoutInt = int256(locked) + pnl;
        // Floor closer payout at 0 (can't lose more than collateral)
        closerPayout = closerPayoutInt > 0 ? uint256(closerPayoutInt) : 0;
        // Counter gets what's left of the combined 2×locked pool
        uint256 combined = locked * 2;
        counterPayout = combined > closerPayout ? combined - closerPayout : 0;
    }

    function _allPairsSettled(uint256 orderId) internal view returns (bool) {
        uint256[] storage pairIds = orderPairs[orderId];
        for (uint256 i = 0; i < pairIds.length; i++) {
            if (!pairs[pairIds[i]].settled) return false;
        }
        return true;
    }

    // ── Cancel Order ──────────────────────────────────────────────────────────

    /**
     * cancelOrder — cancel the PENDING remainder of an order.
     *
     * If the order is partially matched (some ACTIVE pairs exist), those pairs
     * remain active and will be settled when closeOrder is eventually called.
     * Only the unmatched pendingCollateral is refunded.
     * If the order is fully pending (no matches at all), the full collateral is refunded
     * and the order is CANCELLED.
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        if (order.trader != msg.sender) revert NotTrader();
        if (order.status == OrderStatus.CLOSED || order.status == OrderStatus.CANCELLED) revert OrderNotPending();
        if (order.pendingCollateral == 0) revert OrderNotPending();

        uint256 refund = order.pendingCollateral;
        order.pendingCollateral = 0;

        // If nothing was matched, fully cancel
        if (order.matchedCollateral == 0) {
            order.status = OrderStatus.CANCELLED;
        }
        // If partially matched, leave as PENDING (active pairs remain open)
        // closeOrder will settle the matched portions later

        freeBalance[msg.sender] += refund;
        emit OrderCancelled(orderId, msg.sender, refund);
    }

    // ── Liquidation ───────────────────────────────────────────────────────────

    /**
     * liquidate — a keeper calls this when a position's remaining value drops below
     * LIQUIDATION_THRESHOLD_BPS (20%) of original collateral.
     *
     * Keeper receives KEEPER_REWARD_BPS (5%) of original collateral from the liquidated side.
     * The counterpart receives their share of remaining collateral.
     */
    function liquidate(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        if (order.matchedCollateral == 0) revert NothingToLiquidate();

        (, int256 currentPrice,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (currentPrice <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) revert StalePrice(updatedAt, block.timestamp);

        // Compute PnL across all active pairs for this order
        int256 totalPnl = 0;
        uint256[] storage pairIds = orderPairs[orderId];
        for (uint256 i = 0; i < pairIds.length; i++) {
            MatchedPair storage pair = pairs[pairIds[i]];
            if (pair.settled) continue;
            bool isLong = pair.longOrderId == orderId;
            int256 entry = isLong ? pair.longEntryPrice : pair.shortEntryPrice;
            int256 delta = currentPrice - entry;
            if (!isLong) delta = -delta;
            totalPnl += (int256(pair.lockedCollateral) * int256(uint256(order.leverage)) * delta) / entry;
        }

        int256 remainingInt = int256(order.matchedCollateral) + totalPnl;
        uint256 remaining = remainingInt > 0 ? uint256(remainingInt) : 0;

        // Check liquidation threshold: remaining < 20% of matched collateral
        if (remaining * 10_000 >= order.matchedCollateral * LIQUIDATION_THRESHOLD_BPS) {
            revert PositionHealthy();
        }

        // Keeper reward: 5% of matched collateral, capped at remaining
        uint256 keeperReward = (order.matchedCollateral * KEEPER_REWARD_BPS) / 10_000;
        if (keeperReward > remaining) keeperReward = remaining;

        // Settle all active pairs at current price
        for (uint256 i = 0; i < pairIds.length; i++) {
            MatchedPair storage pair = pairs[pairIds[i]];
            if (pair.settled) continue;
            pair.settled = true;

            uint256 counterOrderId = pair.longOrderId == orderId ? pair.shortOrderId : pair.longOrderId;
            Order storage counterOrder = orders[counterOrderId];

            // Counter gets both sides of locked collateral minus keeper reward (proportional)
            uint256 counterShare = pair.lockedCollateral * 2;
            uint256 pairKeeperReward = keeperReward * pair.lockedCollateral / order.matchedCollateral;
            uint256 counterPayout = counterShare > pairKeeperReward ? counterShare - pairKeeperReward : 0;
            freeBalance[counterOrder.trader] += counterPayout;

            if (_allPairsSettled(counterOrderId)) {
                if (counterOrder.pendingCollateral > 0) {
                    freeBalance[counterOrder.trader] += counterOrder.pendingCollateral;
                    counterOrder.pendingCollateral = 0;
                }
                counterOrder.status = OrderStatus.CLOSED;
            }
        }

        // Refund any pending collateral to the liquidated trader
        if (order.pendingCollateral > 0) {
            freeBalance[order.trader] += order.pendingCollateral;
            order.pendingCollateral = 0;
        }

        order.status = OrderStatus.CLOSED;
        freeBalance[msg.sender] += keeperReward;

        emit Liquidated(orderId, order.trader, msg.sender, keeperReward);
    }

    // ── View Functions ────────────────────────────────────────────────────────

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function getFreeBalance(address trader) external view returns (uint256) {
        return freeBalance[trader];
    }

    function getPendingQueueLength(bool isLong, uint8 leverage) external view returns (uint256) {
        return _pendingQueues[_queueKey(isLong, leverage)].length;
    }

    function getPendingQueue(bool isLong, uint8 leverage) external view returns (uint256[] memory) {
        return _pendingQueues[_queueKey(isLong, leverage)];
    }

    function getOrderPairs(uint256 orderId) external view returns (uint256[] memory) {
        return orderPairs[orderId];
    }

    function getPair(uint256 pairId) external view returns (MatchedPair memory) {
        return pairs[pairId];
    }

    /**
     * getMarketDepth — returns pending collateral on each side for a given leverage.
     * Useful for the frontend to show "X USDC Long / Y USDC Short pending".
     */
    function getMarketDepth(uint8 leverage) external view returns (uint256 pendingLong, uint256 pendingShort) {
        uint256[] storage longQueue = _pendingQueues[_queueKey(true, leverage)];
        for (uint256 i = 0; i < longQueue.length; i++) {
            Order storage o = orders[longQueue[i]];
            if (o.status != OrderStatus.CANCELLED) pendingLong += o.pendingCollateral;
        }
        uint256[] storage shortQueue = _pendingQueues[_queueKey(false, leverage)];
        for (uint256 i = 0; i < shortQueue.length; i++) {
            Order storage o = orders[shortQueue[i]];
            if (o.status != OrderStatus.CANCELLED) pendingShort += o.pendingCollateral;
        }
    }

    /**
     * computeLivePnl — off-chain helper: returns live PnL for an order at current oracle price.
     * Not used in settlement (closeOrder does its own read). Safe to call from frontend.
     */
    function computeLivePnl(uint256 orderId) external view returns (int256 pnl) {
        Order storage order = orders[orderId];
        if (order.matchedCollateral == 0) return 0;

        (, int256 currentPrice,,,) = priceFeed.latestRoundData();
        if (currentPrice <= 0) return 0;

        uint256[] storage pairIds = orderPairs[orderId];
        for (uint256 i = 0; i < pairIds.length; i++) {
            MatchedPair storage pair = pairs[pairIds[i]];
            if (pair.settled) continue;
            bool isLong = pair.longOrderId == orderId;
            int256 entry = isLong ? pair.longEntryPrice : pair.shortEntryPrice;
            int256 delta = currentPrice - entry;
            if (!isLong) delta = -delta;
            pnl += (int256(pair.lockedCollateral) * int256(uint256(order.leverage)) * delta) / entry;
        }
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    // ── Internal Helpers ──────────────────────────────────────────────────────

    function _isValidLeverage(uint8 leverage) internal view returns (bool) {
        for (uint256 i = 0; i < VALID_LEVERAGES.length; i++) {
            if (VALID_LEVERAGES[i] == leverage) return true;
        }
        return false;
    }
}
