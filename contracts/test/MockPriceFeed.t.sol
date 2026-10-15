// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../MockPriceFeed.sol";

contract MockPriceFeedTest is Test {
    MockPriceFeed feed;

    address owner = address(this);
    address operator = makeAddr("operator");
    address stranger = makeAddr("stranger");

    int256 constant INITIAL_PRICE = 65_000 * 1e8; // $65,000 in 8 decimals

    function setUp() public {
        feed = new MockPriceFeed(operator, INITIAL_PRICE);
    }

    // ── Constructor ────────────────────────────────────────────────────────────

    function test_constructor_setsOwner() public view {
        assertEq(feed.owner(), owner);
    }

    function test_constructor_setsOperator() public view {
        assertEq(feed.operator(), operator);
    }

    function test_constructor_setsInitialPrice() public view {
        assertEq(feed.latestAnswer(), INITIAL_PRICE);
    }

    function test_constructor_setsRound1() public view {
        assertEq(feed.latestRound(), 1);
    }

    function test_constructor_revertsOnZeroPrice() public {
        vm.expectRevert(MockPriceFeed.InvalidPrice.selector);
        new MockPriceFeed(operator, 0);
    }

    function test_constructor_revertsOnNegativePrice() public {
        vm.expectRevert(MockPriceFeed.InvalidPrice.selector);
        new MockPriceFeed(operator, -1);
    }

    // ── Metadata ───────────────────────────────────────────────────────────────

    function test_decimals_returns8() public view {
        assertEq(feed.decimals(), 8);
    }

    function test_description_returnsBtcUsd() public view {
        assertEq(feed.description(), "BTC / USD");
    }

    function test_version_returns1() public view {
        assertEq(feed.version(), 1);
    }

    // ── latestRoundData ────────────────────────────────────────────────────────

    function test_latestRoundData_returnsCurrentValues() public view {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, INITIAL_PRICE);
        assertGt(updatedAt, 0);
        assertEq(answeredInRound, 1);
    }

    // ── updatePrice ────────────────────────────────────────────────────────────

    function test_updatePrice_succeeds() public {
        int256 newPrice = INITIAL_PRICE + 100 * 1e8; // +$100 (0.15%, within 20% circuit breaker)
        vm.prank(operator);
        feed.updatePrice(newPrice);

        assertEq(feed.latestAnswer(), newPrice);
        assertEq(feed.latestRound(), 2);
    }

    function test_updatePrice_bumpsRound() public {
        vm.prank(operator);
        feed.updatePrice(INITIAL_PRICE + 100 * 1e8);
        assertEq(feed.latestRound(), 2);

        vm.prank(operator);
        feed.updatePrice(INITIAL_PRICE + 200 * 1e8);
        assertEq(feed.latestRound(), 3);
    }

    function test_updatePrice_emitsEvent() public {
        int256 newPrice = INITIAL_PRICE + 100 * 1e8;
        vm.expectEmit(true, true, false, false);
        emit MockPriceFeed.PriceUpdated(newPrice, 2, block.timestamp);
        vm.prank(operator);
        feed.updatePrice(newPrice);
    }

    function test_updatePrice_revertsIfNotOperator() public {
        vm.prank(stranger);
        vm.expectRevert(MockPriceFeed.NotOperator.selector);
        feed.updatePrice(INITIAL_PRICE + 100 * 1e8);
    }

    function test_updatePrice_revertsOnZeroPrice() public {
        vm.prank(operator);
        vm.expectRevert(MockPriceFeed.InvalidPrice.selector);
        feed.updatePrice(0);
    }

    function test_updatePrice_revertsOnNegativePrice() public {
        vm.prank(operator);
        vm.expectRevert(MockPriceFeed.InvalidPrice.selector);
        feed.updatePrice(-1);
    }

    function test_updatePrice_revertsOnExactly20PctChange() public {
        // Exactly 20% over: 65000 * 1.2001 = 78000.65 → revert
        int256 tooHigh = (INITIAL_PRICE * 12001) / 10000;
        vm.prank(operator);
        vm.expectRevert();
        feed.updatePrice(tooHigh);
    }

    function test_updatePrice_allowsJustUnder20PctChange() public {
        // 19.99% move = fine
        int256 almostLimit = (INITIAL_PRICE * 11999) / 10000;
        vm.prank(operator);
        feed.updatePrice(almostLimit);
        assertEq(feed.latestAnswer(), almostLimit);
    }

    function test_updatePrice_circuitBreaker_downward() public {
        // >20% drop also triggers the circuit breaker
        int256 tooLow = (INITIAL_PRICE * 7999) / 10000;
        vm.prank(operator);
        vm.expectRevert();
        feed.updatePrice(tooLow);
    }

    // ── setOperator ────────────────────────────────────────────────────────────

    function test_setOperator_succeeds() public {
        address newOp = makeAddr("newOp");
        feed.setOperator(newOp);
        assertEq(feed.operator(), newOp);
    }

    function test_setOperator_emitsEvent() public {
        address newOp = makeAddr("newOp");
        vm.expectEmit(true, true, false, false);
        emit MockPriceFeed.OperatorUpdated(operator, newOp);
        feed.setOperator(newOp);
    }

    function test_setOperator_revertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockPriceFeed.NotOwner.selector);
        feed.setOperator(makeAddr("newOp"));
    }

    function test_setOperator_revertsOnZeroAddress() public {
        vm.expectRevert(MockPriceFeed.InvalidPrice.selector); // contract reuses InvalidPrice for zero address
        feed.setOperator(address(0));
    }
}
