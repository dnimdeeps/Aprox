// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract MockPriceFeed is AggregatorV3Interface {
    address public owner;
    address public operator;
    int256 public latestAnswer;
    uint80 public latestRound;
    uint256 public latestTimestamp;

    uint256 public constant MAX_PRICE_CHANGE_BPS = 2000;

    error NotOperator();
    error NotOwner();
    error PriceChangeTooLarge(int256 current, int256 proposed);
    error InvalidPrice();

    event PriceUpdated(int256 indexed newPrice, uint80 indexed roundId, uint256 timestamp);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(address _operator, int256 _initialPrice) {
        if (_initialPrice <= 0) revert InvalidPrice();

        owner = msg.sender;
        operator = _operator;
        latestAnswer = _initialPrice;
        latestRound = 1;
        latestTimestamp = block.timestamp;
    }

    function updatePrice(int256 newPrice) external onlyOperator {
        if (newPrice <= 0) revert InvalidPrice();

        int256 diff = newPrice - latestAnswer;
        if (diff < 0) diff = -diff;

        uint256 changeBps = (uint256(diff) * 10_000) / uint256(latestAnswer);
        if (changeBps > MAX_PRICE_CHANGE_BPS) {
            revert PriceChangeTooLarge(latestAnswer, newPrice);
        }

        latestRound += 1;
        latestAnswer = newPrice;
        latestTimestamp = block.timestamp;

        emit PriceUpdated(newPrice, latestRound, latestTimestamp);
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert InvalidPrice();

        address oldOperator = operator;
        operator = newOperator;

        emit OperatorUpdated(oldOperator, newOperator);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (latestRound, latestAnswer, latestTimestamp, latestTimestamp, latestRound);
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "BTC / USD";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }
}
