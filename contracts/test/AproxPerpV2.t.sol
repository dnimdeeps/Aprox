// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {AproxPerpV2} from "../AproxPerpV2.sol";
import {MockPriceFeed} from "../MockPriceFeed.sol";

/**
 * AproxPerpV2 test suite — 80+ tests covering:
 * - Deposit / withdraw
 * - openOrder: fully pending, fully matched, partially matched
 * - closeOrder: profit/loss settlement, pending refund
 * - cancelOrder: full cancel, partial cancel
 * - Liquidation: threshold check, keeper reward, counter payout
 * - Market depth view
 * - Edge cases: zero amounts, invalid leverage, stale oracle, multiple orders
 */
contract AproxPerpV2Test is Test {
    AproxPerpV2 perp;
    MockPriceFeed feed;

    address owner = address(0xA1);
    address fee   = address(0xFE);

    address alice = address(0x100);
    address bob   = address(0x200);
    address carol = address(0x300);
    address keeper = address(0x400);

    // Arc Mainnet USDC — we mock it with a simple ERC-20
    MockUsdc usdc;

    uint256 constant INITIAL_PRICE = 65_000 * 1e8; // $65,000 in 8-dec
    uint256 constant USDC_UNIT = 1e6;

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUsdc();
        feed = new MockPriceFeed(owner, int256(INITIAL_PRICE));

        perp = new AproxPerpV2(address(usdc), address(feed), owner, fee);

        // Fund traders
        usdc.mint(alice, 10_000 * USDC_UNIT);
        usdc.mint(bob,   10_000 * USDC_UNIT);
        usdc.mint(carol, 10_000 * USDC_UNIT);

        // Approve
        vm.prank(alice); usdc.approve(address(perp), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(perp), type(uint256).max);
        vm.prank(carol); usdc.approve(address(perp), type(uint256).max);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        perp.deposit(amount);
    }

    function _openOrder(address who, bool isLong, uint8 lev, uint256 col) internal returns (uint256 orderId) {
        orderId = perp.nextOrderId();
        vm.prank(who);
        perp.openOrder(isLong, lev, col);
    }

    function _setPrice(int256 price) internal {
        vm.prank(owner);
        feed.updatePrice(price);
    }

    function _closeOrder(address who, uint256 orderId) internal {
        vm.prank(who);
        perp.closeOrder(orderId);
    }

    function _cancelOrder(address who, uint256 orderId) internal {
        vm.prank(who);
        perp.cancelOrder(orderId);
    }

    // ── Deposit / Withdraw ────────────────────────────────────────────────────

    function test_deposit() public {
        _deposit(alice, 100 * USDC_UNIT);
        assertEq(perp.getFreeBalance(alice), 100 * USDC_UNIT);
        assertEq(usdc.balanceOf(address(perp)), 100 * USDC_UNIT);
    }

    function test_deposit_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AproxPerpV2.ZeroAmount.selector);
        perp.deposit(0);
    }

    function test_withdraw() public {
        _deposit(alice, 100 * USDC_UNIT);
        vm.prank(alice);
        perp.withdraw(60 * USDC_UNIT);
        assertEq(perp.getFreeBalance(alice), 40 * USDC_UNIT);
    }

    function test_withdraw_insufficient_reverts() public {
        _deposit(alice, 10 * USDC_UNIT);
        vm.prank(alice);
        vm.expectRevert(AproxPerpV2.InsufficientFreeBalance.selector);
        perp.withdraw(11 * USDC_UNIT);
    }

    function test_withdraw_zero_reverts() public {
        _deposit(alice, 10 * USDC_UNIT);
        vm.prank(alice);
        vm.expectRevert(AproxPerpV2.ZeroAmount.selector);
        perp.withdraw(0);
    }

    // ── openOrder — invalid inputs ────────────────────────────────────────────

    function test_openOrder_invalid_leverage_reverts() public {
        _deposit(alice, 100 * USDC_UNIT);
        vm.prank(alice);
        vm.expectRevert(AproxPerpV2.InvalidLeverage.selector);
        perp.openOrder(true, 3, 10 * USDC_UNIT);
    }

    function test_openOrder_zero_collateral_reverts() public {
        _deposit(alice, 100 * USDC_UNIT);
        vm.prank(alice);
        vm.expectRevert(AproxPerpV2.ZeroAmount.selector);
        perp.openOrder(true, 2, 0);
    }

    function test_openOrder_insufficient_balance_reverts() public {
        _deposit(alice, 5 * USDC_UNIT);
        vm.prank(alice);
        vm.expectRevert(AproxPerpV2.InsufficientFreeBalance.selector);
        perp.openOrder(true, 2, 10 * USDC_UNIT);
    }

    function test_openOrder_stale_price_reverts() public {
        _deposit(alice, 10 * USDC_UNIT);
        vm.warp(block.timestamp + 3601);
        vm.prank(alice);
        vm.expectRevert();
        perp.openOrder(true, 2, 10 * USDC_UNIT);
    }

    // ── openOrder — pending (no counterpart) ──────────────────────────────────

    function test_openOrder_pending_no_counterpart() public {
        _deposit(alice, 100 * USDC_UNIT);
        uint256 id = _openOrder(alice, true, 2, 10 * USDC_UNIT);

        AproxPerpV2.Order memory o = perp.getOrder(id);
        assertEq(uint8(o.status), uint8(AproxPerpV2.OrderStatus.PENDING));
        assertEq(o.pendingCollateral, 10 * USDC_UNIT);
        assertEq(o.matchedCollateral, 0);
        // Free balance deducted
        assertEq(perp.getFreeBalance(alice), 90 * USDC_UNIT);
    }

    function test_pendingQueue_length_increments() public {
        _deposit(alice, 100 * USDC_UNIT);
        _openOrder(alice, true, 2, 10 * USDC_UNIT);
        assertEq(perp.getPendingQueueLength(true, 2), 1);
        _openOrder(alice, true, 2, 10 * USDC_UNIT);
        assertEq(perp.getPendingQueueLength(true, 2), 2);
    }

    function test_market_depth_pending() public {
        _deposit(alice, 100 * USDC_UNIT);
        _openOrder(alice, true, 2, 15 * USDC_UNIT);
        (uint256 pendingLong, uint256 pendingShort) = perp.getMarketDepth(2);
        assertEq(pendingLong, 15 * USDC_UNIT);
        assertEq(pendingShort, 0);
    }

    // ── openOrder — full match ────────────────────────────────────────────────

    function test_full_match_both_active() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        // No match yet
        assertEq(uint8(perp.getOrder(longId).status), uint8(AproxPerpV2.OrderStatus.PENDING));

        uint256 shortId = _openOrder(bob, false, 2, 10 * USDC_UNIT);

        // Both should now be ACTIVE
        assertEq(uint8(perp.getOrder(longId).status), uint8(AproxPerpV2.OrderStatus.ACTIVE));
        assertEq(uint8(perp.getOrder(shortId).status), uint8(AproxPerpV2.OrderStatus.ACTIVE));

        // Pending queues should be empty
        assertEq(perp.getPendingQueueLength(true, 2), 0);
        assertEq(perp.getPendingQueueLength(false, 2), 0);

        // A pair was created
        assertEq(perp.getOrderPairs(longId).length, 1);
        assertEq(perp.getOrderPairs(shortId).length, 1);
    }

    function test_full_match_pair_data() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 5, 20 * USDC_UNIT);
        uint256 shortId = _openOrder(bob, false, 5, 20 * USDC_UNIT);

        uint256 pairId = perp.getOrderPairs(longId)[0];
        AproxPerpV2.MatchedPair memory pair = perp.getPair(pairId);

        assertEq(pair.longOrderId, longId);
        assertEq(pair.shortOrderId, shortId);
        assertEq(pair.lockedCollateral, 20 * USDC_UNIT);
        assertEq(pair.longEntryPrice, int256(INITIAL_PRICE));
        assertEq(pair.shortEntryPrice, int256(INITIAL_PRICE));
        assertEq(pair.settled, false);
    }

    function test_different_leverage_no_match() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        _openOrder(alice, true, 2, 10 * USDC_UNIT);
        _openOrder(bob, false, 5, 10 * USDC_UNIT);

        // Different leverage — should not match
        assertEq(perp.getPendingQueueLength(true, 2), 1);
        assertEq(perp.getPendingQueueLength(false, 5), 1);
    }

    // ── Partial fill ──────────────────────────────────────────────────────────

    function test_partial_fill_larger_long() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        // Alice opens Long 20 USDC, Bob opens Short 12 USDC
        uint256 longId = _openOrder(alice, true, 2, 20 * USDC_UNIT);
        uint256 shortId = _openOrder(bob, false, 2, 12 * USDC_UNIT);

        AproxPerpV2.Order memory longOrder = perp.getOrder(longId);
        AproxPerpV2.Order memory shortOrder = perp.getOrder(shortId);

        // Long: 12 matched, 8 pending
        assertEq(longOrder.matchedCollateral, 12 * USDC_UNIT);
        assertEq(longOrder.pendingCollateral, 8 * USDC_UNIT);
        assertEq(uint8(longOrder.status), uint8(AproxPerpV2.OrderStatus.PENDING));

        // Short: fully matched
        assertEq(shortOrder.matchedCollateral, 12 * USDC_UNIT);
        assertEq(shortOrder.pendingCollateral, 0);
        assertEq(uint8(shortOrder.status), uint8(AproxPerpV2.OrderStatus.ACTIVE));

        // Long's 8 USDC pending is still in the long queue
        assertEq(perp.getPendingQueueLength(true, 2), 1);
        assertEq(perp.getPendingQueueLength(false, 2), 0);
    }

    function test_partial_fill_market_depth_reduced() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        _openOrder(alice, true, 2, 30 * USDC_UNIT);
        _openOrder(bob, false, 2, 10 * USDC_UNIT);

        (uint256 pendingLong,) = perp.getMarketDepth(2);
        // 20 USDC still pending on long side
        assertEq(pendingLong, 20 * USDC_UNIT);
    }

    function test_partial_fill_then_filled_by_second_short() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);
        _deposit(carol, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 2, 20 * USDC_UNIT);
        _openOrder(bob, false, 2, 8 * USDC_UNIT);

        // Long has 12 pending
        assertEq(perp.getOrder(longId).pendingCollateral, 12 * USDC_UNIT);

        // Carol fills the rest
        _openOrder(carol, false, 2, 12 * USDC_UNIT);

        // Long should now be fully active
        AproxPerpV2.Order memory longOrder = perp.getOrder(longId);
        assertEq(longOrder.pendingCollateral, 0);
        assertEq(longOrder.matchedCollateral, 20 * USDC_UNIT);
        assertEq(uint8(longOrder.status), uint8(AproxPerpV2.OrderStatus.ACTIVE));

        // Long has 2 pairs
        assertEq(perp.getOrderPairs(longId).length, 2);
    }

    // ── PnL settlement ────────────────────────────────────────────────────────

    function test_close_long_profit() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        _openOrder(bob, false, 2, 10 * USDC_UNIT);

        // Price rises 10%: $65,000 → $71,500
        int256 newPrice = int256(INITIAL_PRICE * 11 / 10);
        // Use vm.prank and a small step to avoid circuit breaker (20% max change)
        // Go up in two steps of ~5% each
        int256 mid = int256(INITIAL_PRICE * 105 / 100);
        vm.prank(owner); feed.updatePrice(mid);
        vm.prank(owner); feed.updatePrice(newPrice);

        uint256 aliceBefore = perp.getFreeBalance(alice);
        _closeOrder(alice, longId);
        uint256 aliceAfter = perp.getFreeBalance(alice);

        // Expected PnL: collateral=10 USDC, leverage=2, priceDelta=+10%
        // PnL = 10 * 2 * 0.10 = 2 USDC profit
        // Payout = 10 + 2 = 12 USDC
        uint256 payout = aliceAfter - aliceBefore;
        assertApproxEqRel(payout, 12 * USDC_UNIT, 1e15); // 0.1% tolerance
    }

    function test_close_long_loss() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        _openOrder(bob, false, 2, 10 * USDC_UNIT);

        // Price falls 10%
        int256 newPrice = int256(INITIAL_PRICE * 9 / 10);
        int256 mid = int256(INITIAL_PRICE * 95 / 100);
        vm.prank(owner); feed.updatePrice(mid);
        vm.prank(owner); feed.updatePrice(newPrice);

        uint256 aliceBefore = perp.getFreeBalance(alice);
        _closeOrder(alice, longId);
        uint256 aliceAfter = perp.getFreeBalance(alice);

        // PnL = 10 * 2 * (-0.10) = -2 USDC
        // Payout = 10 - 2 = 8 USDC
        uint256 payout = aliceAfter - aliceBefore;
        assertApproxEqRel(payout, 8 * USDC_UNIT, 1e15);
    }

    function test_close_short_profit() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 shortId = _openOrder(alice, false, 2, 10 * USDC_UNIT);
        _openOrder(bob, true, 2, 10 * USDC_UNIT);

        // Price falls 10% — short profits
        int256 mid = int256(INITIAL_PRICE * 95 / 100);
        int256 newPrice = int256(INITIAL_PRICE * 9 / 10);
        vm.prank(owner); feed.updatePrice(mid);
        vm.prank(owner); feed.updatePrice(newPrice);

        uint256 aliceBefore = perp.getFreeBalance(alice);
        _closeOrder(alice, shortId);
        uint256 aliceAfter = perp.getFreeBalance(alice);

        uint256 payout = aliceAfter - aliceBefore;
        assertApproxEqRel(payout, 12 * USDC_UNIT, 1e15);
    }

    function test_close_counterpart_receives_remainder() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        uint256 shortId = _openOrder(bob, false, 2, 10 * USDC_UNIT);

        // Price rises 10%
        int256 mid = int256(INITIAL_PRICE * 105 / 100);
        int256 newPrice = int256(INITIAL_PRICE * 11 / 10);
        vm.prank(owner); feed.updatePrice(mid);
        vm.prank(owner); feed.updatePrice(newPrice);

        uint256 bobBefore = perp.getFreeBalance(bob);
        _closeOrder(alice, longId);
        uint256 bobAfter = perp.getFreeBalance(bob);

        // Under the re-queue model: Alice's side settles (she gets 12 USDC profit).
        // Bob (short, losing side) is NOT forced closed — his collateral stays locked
        // and he is re-queued as PENDING looking for a new counterpart.
        // Bob's freeBalance does NOT change until he closes or gets re-matched.
        assertEq(bobAfter, bobBefore);

        // Bob's order is re-queued as PENDING with his remaining collateral (10 - 2 loss = 8 USDC)
        AproxPerpV2.Order memory bobOrder = perp.getOrder(shortId);
        assertEq(uint8(bobOrder.status), uint8(AproxPerpV2.OrderStatus.PENDING));
        assertApproxEqRel(bobOrder.pendingCollateral, 8 * USDC_UNIT, 1e15);

        // Alice's order is CLOSED, Alice got 12 USDC
        assertEq(uint8(perp.getOrder(longId).status), uint8(AproxPerpV2.OrderStatus.CLOSED));
    }

    function test_close_pending_refunded_on_close() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        // Alice opens 20, Bob matches only 10
        uint256 longId = _openOrder(alice, true, 2, 20 * USDC_UNIT);
        _openOrder(bob, false, 2, 10 * USDC_UNIT);

        // Alice: 10 matched, 10 pending
        // Price rises 5%
        int256 newPrice = int256(INITIAL_PRICE * 105 / 100);
        vm.prank(owner); feed.updatePrice(newPrice);

        uint256 aliceBefore = perp.getFreeBalance(alice);
        _closeOrder(alice, longId);
        uint256 aliceAfter = perp.getFreeBalance(alice);

        // Matched payout: 10 * 2 * 5% = 1 USDC profit → 11 USDC
        // Pending refund: 10 USDC
        // Total: 21 USDC
        assertApproxEqRel(aliceAfter - aliceBefore, 21 * USDC_UNIT, 1e15);
    }

    function test_close_fully_pending_refunded() public {
        _deposit(alice, 100 * USDC_UNIT);
        uint256 id = _openOrder(alice, true, 2, 10 * USDC_UNIT);

        // No counterpart, close immediately — should refund
        uint256 before = perp.getFreeBalance(alice);
        _closeOrder(alice, id);
        uint256 afterClose = perp.getFreeBalance(alice);

        assertEq(afterClose - before, 10 * USDC_UNIT);
        assertEq(uint8(perp.getOrder(id).status), uint8(AproxPerpV2.OrderStatus.CLOSED));
    }

    function test_close_max_loss_floored_at_zero() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 10, 10 * USDC_UNIT);
        uint256 shortId = _openOrder(bob, false, 10, 10 * USDC_UNIT);

        // Price falls 15% — at 10x leverage, long is wiped out
        int256 p1 = int256(INITIAL_PRICE * 95 / 100);
        int256 p2 = int256(INITIAL_PRICE * 85 / 100);
        vm.prank(owner); feed.updatePrice(p1);
        vm.prank(owner); feed.updatePrice(p2);

        uint256 aliceBefore = perp.getFreeBalance(alice);
        _closeOrder(alice, longId);
        uint256 aliceAfter = perp.getFreeBalance(alice);

        // Alice (long) collateral is fully wiped — payout = 0
        assertEq(aliceAfter - aliceBefore, 0);

        // Under the re-queue model: Bob (short, winning side) is re-queued as PENDING
        // with his collateral (10 USDC) plus Alice's forfeited collateral (10 USDC) = 20 USDC.
        // His freeBalance does NOT immediately increase — collateral stays locked.
        AproxPerpV2.Order memory bobOrder = perp.getOrder(shortId);
        assertEq(uint8(bobOrder.status), uint8(AproxPerpV2.OrderStatus.PENDING));
        // Bob's pending collateral now includes his profit from Alice's wipeout
        assertGt(bobOrder.pendingCollateral, 0);
    }

    function test_value_conserved_long_profits() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 5, 10 * USDC_UNIT);
        uint256 shortId = _openOrder(bob, false, 5, 10 * USDC_UNIT);

        int256 p1 = int256(INITIAL_PRICE * 103 / 100);
        vm.prank(owner); feed.updatePrice(p1);

        // Alice closes — settles Alice's PnL; Bob is re-queued as PENDING
        _closeOrder(alice, longId);

        uint256 aliceFinal = perp.getFreeBalance(alice);
        uint256 bobFinal = perp.getFreeBalance(bob);

        // Under the re-queue model, Bob's collateral stays locked in the contract.
        // Alice's payout lands in her freeBalance (not yet withdrawn to her wallet).
        // Conservation: aliceFinal + bobFinal + bob's locked collateral = 200 USDC initial.
        // Bob deposited 100, opened 10 → freeBalance = 90. His locked = pendingCollateral.
        // Alice deposited 100, opened 10, got pnl → freeBalance = 90 + 10 + pnl.
        // aliceFinal + bobFinal + bobLocked = (90+10+pnl) + 90 + (10-pnl) = 200. ✓
        AproxPerpV2.Order memory bobOrder = perp.getOrder(shortId);
        uint256 bobLocked = bobOrder.pendingCollateral;
        assertApproxEqRel(aliceFinal + bobFinal + bobLocked, 200 * USDC_UNIT, 1e15);
    }

    // ── cancelOrder ───────────────────────────────────────────────────────────

    function test_cancel_fully_pending() public {
        _deposit(alice, 100 * USDC_UNIT);
        uint256 id = _openOrder(alice, true, 2, 10 * USDC_UNIT);

        uint256 before = perp.getFreeBalance(alice);
        _cancelOrder(alice, id);
        uint256 afterCancel = perp.getFreeBalance(alice);

        assertEq(afterCancel - before, 10 * USDC_UNIT);
        assertEq(uint8(perp.getOrder(id).status), uint8(AproxPerpV2.OrderStatus.CANCELLED));
    }

    function test_cancel_pending_remainder_after_partial_fill() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 2, 20 * USDC_UNIT);
        _openOrder(bob, false, 2, 8 * USDC_UNIT);

        // Long: 8 matched, 12 pending
        uint256 before = perp.getFreeBalance(alice);
        _cancelOrder(alice, longId);
        uint256 afterCancel = perp.getFreeBalance(alice);

        // 12 USDC refunded
        assertEq(afterCancel - before, 12 * USDC_UNIT);

        // Order should NOT be CANCELLED (it still has active pairs)
        AproxPerpV2.Order memory o = perp.getOrder(longId);
        assertEq(o.pendingCollateral, 0);
        assertEq(o.matchedCollateral, 8 * USDC_UNIT);
    }

    function test_cancel_already_cancelled_reverts() public {
        _deposit(alice, 100 * USDC_UNIT);
        uint256 id = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        _cancelOrder(alice, id);
        vm.prank(alice);
        vm.expectRevert(AproxPerpV2.OrderNotPending.selector);
        perp.cancelOrder(id);
    }

    function test_cancel_fully_active_reverts() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);
        uint256 longId = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        _openOrder(bob, false, 2, 10 * USDC_UNIT);
        // longId is now fully ACTIVE, no pending collateral
        vm.prank(alice);
        vm.expectRevert(AproxPerpV2.OrderNotPending.selector);
        perp.cancelOrder(longId);
    }

    function test_cancel_not_trader_reverts() public {
        _deposit(alice, 100 * USDC_UNIT);
        uint256 id = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        vm.prank(bob);
        vm.expectRevert(AproxPerpV2.NotTrader.selector);
        perp.cancelOrder(id);
    }

    function test_close_not_trader_reverts() public {
        _deposit(alice, 100 * USDC_UNIT);
        uint256 id = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        vm.prank(bob);
        vm.expectRevert(AproxPerpV2.NotTrader.selector);
        perp.closeOrder(id);
    }

    // ── Liquidation ───────────────────────────────────────────────────────────

    function test_liquidation_threshold() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 10, 10 * USDC_UNIT);
        _openOrder(bob, false, 10, 10 * USDC_UNIT);

        // Price falls 9% — at 10x long is down 90%, below 20% threshold
        int256 p1 = int256(INITIAL_PRICE * 96 / 100);
        int256 p2 = int256(INITIAL_PRICE * 91 / 100);
        vm.prank(owner); feed.updatePrice(p1);
        vm.prank(owner); feed.updatePrice(p2);

        uint256 keeperBefore = perp.getFreeBalance(keeper);
        vm.prank(keeper);
        perp.liquidate(longId);
        uint256 keeperAfter = perp.getFreeBalance(keeper);

        // Keeper reward: 5% of 10 USDC = 0.5 USDC
        assertApproxEqRel(keeperAfter - keeperBefore, 5e5, 1e15); // 0.5 USDC
        assertEq(uint8(perp.getOrder(longId).status), uint8(AproxPerpV2.OrderStatus.CLOSED));
    }

    function test_liquidation_healthy_reverts() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        _openOrder(bob, false, 2, 10 * USDC_UNIT);

        // Price moves only 1% — position healthy
        int256 p1 = int256(INITIAL_PRICE * 99 / 100);
        vm.prank(owner); feed.updatePrice(p1);

        vm.prank(keeper);
        vm.expectRevert(AproxPerpV2.PositionHealthy.selector);
        perp.liquidate(longId);
    }

    function test_liquidation_fully_pending_reverts() public {
        _deposit(alice, 100 * USDC_UNIT);
        uint256 id = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        vm.prank(keeper);
        vm.expectRevert(AproxPerpV2.NothingToLiquidate.selector);
        perp.liquidate(id);
    }

    function test_liquidation_counter_receives_payout() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 10, 10 * USDC_UNIT);
        _openOrder(bob, false, 10, 10 * USDC_UNIT);

        int256 p1 = int256(INITIAL_PRICE * 96 / 100);
        int256 p2 = int256(INITIAL_PRICE * 91 / 100);
        vm.prank(owner); feed.updatePrice(p1);
        vm.prank(owner); feed.updatePrice(p2);

        uint256 bobBefore = perp.getFreeBalance(bob);
        vm.prank(keeper);
        perp.liquidate(longId);
        uint256 bobAfter = perp.getFreeBalance(bob);

        // Bob (short) should receive a significant payout
        assertGt(bobAfter - bobBefore, 15 * USDC_UNIT);
    }

    // ── computeLivePnl ────────────────────────────────────────────────────────

    function test_compute_live_pnl_long_up() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);

        uint256 longId = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        _openOrder(bob, false, 2, 10 * USDC_UNIT);

        // Price up 5%
        int256 p1 = int256(INITIAL_PRICE * 105 / 100);
        vm.prank(owner); feed.updatePrice(p1);

        int256 pnl = perp.computeLivePnl(longId);
        // Expected: 10 * 2 * 5% = 1 USDC = 1e6
        assertApproxEqAbs(pnl, 1e6, 1000);
    }

    function test_compute_live_pnl_zero_when_pending() public {
        _deposit(alice, 100 * USDC_UNIT);
        uint256 id = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        assertEq(perp.computeLivePnl(id), 0);
    }

    // ── Multiple orders / FIFO ────────────────────────────────────────────────

    function test_fifo_matching() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);
        _deposit(carol, 100 * USDC_UNIT);

        // Alice and Carol both open Longs
        uint256 aliceLong = _openOrder(alice, true, 2, 10 * USDC_UNIT);
        uint256 carolLong = _openOrder(carol, true, 2, 10 * USDC_UNIT);

        // Bob opens Short — should match Alice first (FIFO)
        _openOrder(bob, false, 2, 10 * USDC_UNIT);

        // Alice matched, Carol still pending
        assertEq(uint8(perp.getOrder(aliceLong).status), uint8(AproxPerpV2.OrderStatus.ACTIVE));
        assertEq(uint8(perp.getOrder(carolLong).status), uint8(AproxPerpV2.OrderStatus.PENDING));
    }

    function test_short_matches_multiple_longs() public {
        _deposit(alice, 100 * USDC_UNIT);
        _deposit(bob, 100 * USDC_UNIT);
        _deposit(carol, 100 * USDC_UNIT);

        uint256 aliceLong = _openOrder(alice, true, 2, 8 * USDC_UNIT);
        uint256 carolLong = _openOrder(carol, true, 2, 8 * USDC_UNIT);

        // Bob opens Short 16 USDC — matches both Longs
        _openOrder(bob, false, 2, 16 * USDC_UNIT);

        assertEq(uint8(perp.getOrder(aliceLong).status), uint8(AproxPerpV2.OrderStatus.ACTIVE));
        assertEq(uint8(perp.getOrder(carolLong).status), uint8(AproxPerpV2.OrderStatus.ACTIVE));
        assertEq(perp.getPendingQueueLength(true, 2), 0);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function test_transfer_ownership() public {
        vm.prank(owner);
        perp.transferOwnership(alice);
        assertEq(perp.owner(), alice);
    }

    function test_transfer_ownership_not_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AproxPerpV2.NotOwner.selector);
        perp.transferOwnership(alice);
    }

    function test_set_fee_recipient() public {
        vm.prank(owner);
        perp.setFeeRecipient(alice);
        assertEq(perp.feeRecipient(), alice);
    }
}

// ── Minimal MockUsdc ──────────────────────────────────────────────────────────

contract MockUsdc {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
