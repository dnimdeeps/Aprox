// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../AproxPerp.sol";
import "../MockPriceFeed.sol";

/**
 * Minimal ERC-20 mock used by AproxPerp tests.
 * We use a simple mapping-based token so tests are fully self-contained.
 */
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract AproxPerpTest is Test {
    AproxPerp perp;
    MockUSDC usdc;
    MockPriceFeed priceFeed;

    address owner = address(this);
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    int256 constant INITIAL_PRICE = 65_000 * 1e8; // $65,000 in 8-decimal Chainlink format
    uint256 constant RESERVE = 10_000 * 1e6;       // $10,000 USDC (6 decimals)
    uint256 constant ALICE_BALANCE = 5_000 * 1e6;  // $5,000 USDC

    function setUp() public {
        usdc = new MockUSDC();
        priceFeed = new MockPriceFeed(operator, INITIAL_PRICE);

        // Mint reserve to owner so the constructor can pull it in
        usdc.mint(owner, RESERVE);
        usdc.approve(address(0), 0); // warm slot
        IERC20(address(usdc)).approve(address(0), 0); // silence linter

        // Deploy — owner approves reserve transfer inside constructor
        usdc.approve(address(this), type(uint256).max); // self-approve for constructor pull
        // Actually: constructor pulls from msg.sender == owner == address(this)
        usdc.approve(address(usdc), type(uint256).max);

        // Build AproxPerp: constructor calls usdc.transferFrom(msg.sender, contract, reserve)
        // So owner must have approved the yet-to-be-deployed address — use a pre-computed one.
        // Simpler: deploy with reserve=0 first, then addToReserve.
        perp = new AproxPerp(address(usdc), address(priceFeed), 0, owner);

        // Fund the reserve via addToReserve (owner path, no pre-approval complexity)
        usdc.mint(owner, RESERVE);
        usdc.approve(address(perp), type(uint256).max);
        perp.addToReserve(RESERVE);

        // Give Alice USDC to deposit
        usdc.mint(alice, ALICE_BALANCE);
        vm.prank(alice);
        usdc.approve(address(perp), type(uint256).max);
    }

    // ── Deposit ────────────────────────────────────────────────────────────────

    function test_deposit_creditsBalance() public {
        vm.prank(alice);
        perp.deposit(1000 * 1e6);
        assertEq(perp.freeBalance(alice), 1000 * 1e6);
    }

    function test_deposit_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit AproxPerp.Deposited(alice, 500 * 1e6);
        vm.prank(alice);
        perp.deposit(500 * 1e6);
    }

    function test_deposit_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(AproxPerp.ZeroAmount.selector);
        perp.deposit(0);
    }

    // ── Withdraw ───────────────────────────────────────────────────────────────

    function test_withdraw_reducesBalance() public {
        vm.startPrank(alice);
        perp.deposit(1000 * 1e6);
        perp.withdraw(400 * 1e6);
        vm.stopPrank();
        assertEq(perp.freeBalance(alice), 600 * 1e6);
    }

    function test_withdraw_transfersTokens() public {
        vm.startPrank(alice);
        perp.deposit(1000 * 1e6);
        uint256 before = usdc.balanceOf(alice);
        perp.withdraw(600 * 1e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), before + 600 * 1e6);
    }

    function test_withdraw_emitsEvent() public {
        vm.startPrank(alice);
        perp.deposit(1000 * 1e6);
        vm.expectEmit(true, false, false, true);
        emit AproxPerp.Withdrawn(alice, 1000 * 1e6);
        perp.withdraw(1000 * 1e6);
        vm.stopPrank();
    }

    function test_withdraw_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(AproxPerp.ZeroAmount.selector);
        perp.withdraw(0);
    }

    function test_withdraw_revertsIfInsufficientBalance() public {
        vm.startPrank(alice);
        perp.deposit(100 * 1e6);
        vm.expectRevert(AproxPerp.InsufficientBalance.selector);
        perp.withdraw(101 * 1e6);
        vm.stopPrank();
    }

    // ── openPosition ──────────────────────────────────────────────────────────

    function _depositAlice(uint256 amount) internal {
        vm.prank(alice);
        perp.deposit(amount);
    }

    function test_openPosition_longSucceeds() public {
        _depositAlice(500 * 1e6);
        vm.prank(alice);
        perp.openPosition(true, 2, 100 * 1e6);

        AproxPerp.Position memory pos = perp.getPosition(alice);
        assertTrue(pos.isOpen);
        assertTrue(pos.isLong);
        assertEq(pos.leverage, 2);
        assertEq(pos.collateral, 100 * 1e6);
        assertEq(pos.entryPrice, INITIAL_PRICE);
    }

    function test_openPosition_shortSucceeds() public {
        _depositAlice(500 * 1e6);
        vm.prank(alice);
        perp.openPosition(false, 5, 100 * 1e6);

        AproxPerp.Position memory pos = perp.getPosition(alice);
        assertFalse(pos.isLong);
        assertEq(pos.leverage, 5);
    }

    function test_openPosition_deductsFreeBalance() public {
        _depositAlice(500 * 1e6);
        vm.prank(alice);
        perp.openPosition(true, 2, 100 * 1e6);
        assertEq(perp.freeBalance(alice), 400 * 1e6);
    }

    function test_openPosition_emitsEvent() public {
        _depositAlice(500 * 1e6);
        vm.expectEmit(true, false, false, true);
        emit AproxPerp.PositionOpened(alice, true, 2, 100 * 1e6, INITIAL_PRICE);
        vm.prank(alice);
        perp.openPosition(true, 2, 100 * 1e6);
    }

    function test_openPosition_revertsInvalidLeverage() public {
        _depositAlice(500 * 1e6);
        vm.prank(alice);
        vm.expectRevert(AproxPerp.InvalidLeverage.selector);
        perp.openPosition(true, 3, 100 * 1e6);
    }

    function test_openPosition_revertsZeroCollateral() public {
        _depositAlice(500 * 1e6);
        vm.prank(alice);
        vm.expectRevert(AproxPerp.ZeroAmount.selector);
        perp.openPosition(true, 2, 0);
    }

    function test_openPosition_revertsInsufficientBalance() public {
        _depositAlice(100 * 1e6);
        vm.prank(alice);
        vm.expectRevert(AproxPerp.InsufficientBalance.selector);
        perp.openPosition(true, 2, 200 * 1e6);
    }

    function test_openPosition_revertsPositionAlreadyOpen() public {
        _depositAlice(500 * 1e6);
        vm.startPrank(alice);
        perp.openPosition(true, 2, 100 * 1e6);
        vm.expectRevert(AproxPerp.PositionAlreadyOpen.selector);
        perp.openPosition(true, 2, 100 * 1e6);
        vm.stopPrank();
    }

    function test_openPosition_revertsInsufficientReserve() public {
        // Collateral × leverage > reserve
        // reserve = 10,000 USDC; collateral=3000, leverage=10 → 30,000 required
        uint256 bigDeposit = 5_000 * 1e6;
        usdc.mint(alice, bigDeposit);
        vm.startPrank(alice);
        usdc.approve(address(perp), type(uint256).max);
        perp.deposit(bigDeposit);
        vm.expectRevert();
        perp.openPosition(true, 10, 3_000 * 1e6); // needs 30,000 vs 10,000 reserve
        vm.stopPrank();
    }

    function test_openPosition_revertsOnStaleOracle() public {
        _depositAlice(500 * 1e6);
        // Advance time past MAX_ORACLE_STALENESS (3600s)
        vm.warp(block.timestamp + 3601);
        vm.prank(alice);
        vm.expectRevert();
        perp.openPosition(true, 2, 100 * 1e6);
    }

    // ── closePosition ─────────────────────────────────────────────────────────

    function _openAliceLong(uint8 leverage, uint256 collateral) internal {
        _depositAlice(collateral + 100 * 1e6); // extra buffer
        vm.prank(alice);
        perp.openPosition(true, leverage, collateral);
    }

    function test_closePosition_atBreakeven_returnsCollateral() public {
        uint256 collateral = 100 * 1e6;
        _openAliceLong(2, collateral);
        // Price unchanged — pnl = 0
        vm.prank(alice);
        perp.closePosition();

        // freeBalance should have collateral back plus the 100 USDC buffer deposit
        assertEq(perp.freeBalance(alice), collateral + 100 * 1e6);
    }

    function test_closePosition_profit_creditsFreeBalance() public {
        uint256 collateral = 100 * 1e6;
        _openAliceLong(2, collateral);

        // Price goes up 1%
        int256 newPrice = (INITIAL_PRICE * 101) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        vm.prank(alice);
        perp.closePosition();

        // pnl = collateral * leverage * priceDelta / entryPrice
        //     = 100e6 * 2 * (0.01 * INITIAL_PRICE) / INITIAL_PRICE = 100e6 * 2 * 0.01 = 2e6
        uint256 balance = perp.freeBalance(alice);
        assertGt(balance, 100 * 1e6 + 100 * 1e6); // > collateral + buffer
    }

    function test_closePosition_loss_reducesBalance() public {
        uint256 collateral = 100 * 1e6;
        _openAliceLong(2, collateral);

        // Price drops 1%
        int256 newPrice = (INITIAL_PRICE * 99) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        vm.prank(alice);
        perp.closePosition();

        uint256 balance = perp.freeBalance(alice);
        // balance = buffer + (collateral - 2e6 loss) = 100e6 + 98e6 = 198e6
        assertLt(balance, 200 * 1e6);
        assertGt(balance, 195 * 1e6);
    }

    function test_closePosition_emitsEvent() public {
        _openAliceLong(2, 100 * 1e6);
        vm.expectEmit(true, false, false, false);
        emit AproxPerp.PositionClosed(alice, 0, 0, 0);
        vm.prank(alice);
        perp.closePosition();
    }

    function test_closePosition_clearsPosition() public {
        _openAliceLong(2, 100 * 1e6);
        vm.prank(alice);
        perp.closePosition();
        AproxPerp.Position memory pos = perp.getPosition(alice);
        assertFalse(pos.isOpen);
    }

    function test_closePosition_revertsNoOpenPosition() public {
        vm.prank(alice);
        vm.expectRevert(AproxPerp.NoOpenPosition.selector);
        perp.closePosition();
    }

    function test_closePosition_profitCappedAtReserve() public {
        // Open a 10x long with almost the whole reserve as the required backing
        // Reserve is 10,000 USDC; open 10x with 1,000 USDC collateral (exactly at limit)
        uint256 collateral = 1_000 * 1e6;
        _depositAlice(collateral + 100 * 1e6);
        vm.prank(alice);
        perp.openPosition(true, 10, collateral);

        // Huge price jump — profit > reserve
        // +19% (max allowed by circuit breaker: 20%)
        int256 newPrice = (INITIAL_PRICE * 119) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        uint256 reserveBefore = perp.getReserveBalance();
        vm.prank(alice);
        perp.closePosition();

        // Reserve must have decreased (profit was taken from it)
        assertLt(perp.getReserveBalance(), reserveBefore);
        // Reserve cannot go below 0 (unsigned, so this is guaranteed by Solidity)
        // Alice's payout cannot exceed collateral + reserveBefore
        uint256 aliceGot = perp.freeBalance(alice) - 100 * 1e6; // subtract buffer
        assertLe(aliceGot, collateral + reserveBefore);
    }

    function test_closePosition_short_profit_onPriceDrop() public {
        uint256 collateral = 100 * 1e6;
        _depositAlice(collateral + 100 * 1e6);
        vm.prank(alice);
        perp.openPosition(false, 2, collateral);

        // Price drops 1% — short profits
        int256 newPrice = (INITIAL_PRICE * 99) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        vm.prank(alice);
        perp.closePosition();

        uint256 balance = perp.freeBalance(alice);
        assertGt(balance, 200 * 1e6); // more than collateral + buffer
    }

    // ── liquidate ─────────────────────────────────────────────────────────────

    function test_liquidate_succeedsWhenUnderThreshold() public {
        // 10x long — threshold is 20% of collateral remaining
        // collateral=100, leverage=10 → liq when remaining < 20 USDC
        // Price drop needed: loss = collateral * leverage * |delta| / entry
        // We need loss > 80 USDC → delta/entry > 0.08, so -8% price drop
        uint256 collateral = 100 * 1e6;
        _depositAlice(collateral + 100 * 1e6);
        vm.prank(alice);
        perp.openPosition(true, 10, collateral);

        // Drop price by 9% (within 20% circuit breaker)
        int256 newPrice = (INITIAL_PRICE * 91) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        vm.prank(keeper);
        perp.liquidate(alice);

        AproxPerp.Position memory pos = perp.getPosition(alice);
        assertFalse(pos.isOpen);
    }

    function test_liquidate_revertsWhenPositionHealthy() public {
        _depositAlice(500 * 1e6);
        vm.prank(alice);
        perp.openPosition(true, 2, 100 * 1e6);
        // No price change — position is healthy

        vm.prank(keeper);
        vm.expectRevert(AproxPerp.PositionHealthy.selector);
        perp.liquidate(alice);
    }

    function test_liquidate_revertsNoOpenPosition() public {
        vm.prank(keeper);
        vm.expectRevert(AproxPerp.NoOpenPosition.selector);
        perp.liquidate(alice);
    }

    function test_liquidate_emitsEvent() public {
        uint256 collateral = 100 * 1e6;
        _depositAlice(collateral + 100 * 1e6);
        vm.prank(alice);
        perp.openPosition(true, 10, collateral);

        int256 newPrice = (INITIAL_PRICE * 91) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        vm.expectEmit(true, true, false, false);
        emit AproxPerp.Liquidated(alice, keeper, 0);
        vm.prank(keeper);
        perp.liquidate(alice);
    }

    function test_liquidate_keeperGetsReward() public {
        uint256 collateral = 100 * 1e6;
        _depositAlice(collateral + 100 * 1e6);
        vm.prank(alice);
        perp.openPosition(true, 10, collateral);

        int256 newPrice = (INITIAL_PRICE * 91) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        vm.prank(keeper);
        perp.liquidate(alice);

        // keeper should have a nonzero freeBalance reward
        assertGt(perp.freeBalance(keeper), 0);
    }

    // ── addToReserve ──────────────────────────────────────────────────────────

    function test_addToReserve_onlyOwner() public {
        usdc.mint(alice, 1000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(perp), type(uint256).max);
        vm.expectRevert(AproxPerp.NotOwner.selector);
        perp.addToReserve(1000 * 1e6);
        vm.stopPrank();
    }

    function test_addToReserve_increasesReserve() public {
        uint256 reserveBefore = perp.getReserveBalance();
        uint256 addAmount = 500 * 1e6;
        usdc.mint(owner, addAmount);
        usdc.approve(address(perp), type(uint256).max);
        perp.addToReserve(addAmount);
        assertEq(perp.getReserveBalance(), reserveBefore + addAmount);
    }

    function test_addToReserve_revertsZero() public {
        vm.expectRevert(AproxPerp.ZeroAmount.selector);
        perp.addToReserve(0);
    }

    function test_addToReserve_emitsEvent() public {
        uint256 addAmount = 500 * 1e6;
        usdc.mint(owner, addAmount);
        usdc.approve(address(perp), type(uint256).max);
        vm.expectEmit(false, false, false, true);
        emit AproxPerp.ReserveAdded(addAmount, RESERVE + addAmount);
        perp.addToReserve(addAmount);
    }

    // ── constructor guards ─────────────────────────────────────────────────────

    function test_constructor_revertsZeroUsdc() public {
        vm.expectRevert(AproxPerp.ZeroAddress.selector);
        new AproxPerp(address(0), address(priceFeed), 0, owner);
    }

    function test_constructor_revertsZeroPriceFeed() public {
        vm.expectRevert(AproxPerp.ZeroAddress.selector);
        new AproxPerp(address(usdc), address(0), 0, owner);
    }

    function test_constructor_revertsZeroOwner() public {
        vm.expectRevert(AproxPerp.ZeroAddress.selector);
        new AproxPerp(address(usdc), address(priceFeed), 0, address(0));
    }

    // ── view helpers ──────────────────────────────────────────────────────────

    function test_getFreeBalance_returnsValue() public {
        _depositAlice(1000 * 1e6);
        assertEq(perp.getFreeBalance(alice), 1000 * 1e6);
    }

    function test_getReserveBalance_returnsReserve() public view {
        assertEq(perp.getReserveBalance(), RESERVE);
    }

    function test_getPosition_returnsEmptyForNoPosition() public view {
        AproxPerp.Position memory pos = perp.getPosition(alice);
        assertFalse(pos.isOpen);
    }

    // ── reserve accounting on close ───────────────────────────────────────────

    function test_closePosition_loss_increasesReserve() public {
        _openAliceLong(2, 100 * 1e6);

        // 5% drop → loss = 10 USDC
        int256 newPrice = (INITIAL_PRICE * 95) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        uint256 reserveBefore = perp.getReserveBalance();
        vm.prank(alice);
        perp.closePosition();

        assertGt(perp.getReserveBalance(), reserveBefore);
    }

    function test_closePosition_profit_decreasesReserve() public {
        _openAliceLong(2, 100 * 1e6);

        // 5% gain → profit = 10 USDC
        int256 newPrice = (INITIAL_PRICE * 105) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        uint256 reserveBefore = perp.getReserveBalance();
        vm.prank(alice);
        perp.closePosition();

        assertLt(perp.getReserveBalance(), reserveBefore);
    }

    // ── PnL math sanity ───────────────────────────────────────────────────────

    function test_pnl_long_1pct_2x() public {
        // 1% price up, 2x long, 100 USDC collateral → pnl = 100 * 2 * 0.01 = 2 USDC
        _openAliceLong(2, 100 * 1e6);

        int256 newPrice = (INITIAL_PRICE * 101) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        uint256 balanceBefore = perp.freeBalance(alice);
        vm.prank(alice);
        perp.closePosition();

        // alice had 100e6 buffer + 100e6 collateral back + ~2e6 profit
        uint256 gained = perp.freeBalance(alice) - balanceBefore;
        // gained ≈ collateral + profit = 100e6 + 2e6
        assertApproxEqAbs(gained, 102 * 1e6, 0.1 * 1e6); // within $0.10
    }

    function test_pnl_short_1pct_5x() public {
        // 1% price down, 5x short, 100 USDC collateral → pnl = 100 * 5 * 0.01 = 5 USDC
        uint256 collateral = 100 * 1e6;
        _depositAlice(collateral + 100 * 1e6);
        vm.prank(alice);
        perp.openPosition(false, 5, collateral);

        int256 newPrice = (INITIAL_PRICE * 99) / 100;
        vm.prank(operator);
        priceFeed.updatePrice(newPrice);

        uint256 balanceBefore = perp.freeBalance(alice);
        vm.prank(alice);
        perp.closePosition();

        uint256 gained = perp.freeBalance(alice) - balanceBefore;
        assertApproxEqAbs(gained, 105 * 1e6, 0.1 * 1e6);
    }

    // ── VALID_LEVERAGES ───────────────────────────────────────────────────────

    function test_validLeverages_2_5_10() public {
        _depositAlice(ALICE_BALANCE);
        // 2x
        vm.prank(alice);
        perp.openPosition(true, 2, 100 * 1e6);
        vm.prank(alice);
        perp.closePosition();
        // 5x
        vm.prank(alice);
        perp.openPosition(true, 5, 100 * 1e6);
        vm.prank(alice);
        perp.closePosition();
        // 10x
        vm.prank(alice);
        perp.openPosition(true, 10, 100 * 1e6);
        vm.prank(alice);
        perp.closePosition();
    }

    function test_invalidLeverage_1_reverts() public {
        _depositAlice(500 * 1e6);
        vm.prank(alice);
        vm.expectRevert(AproxPerp.InvalidLeverage.selector);
        perp.openPosition(true, 1, 100 * 1e6);
    }

    function test_invalidLeverage_7_reverts() public {
        _depositAlice(500 * 1e6);
        vm.prank(alice);
        vm.expectRevert(AproxPerp.InvalidLeverage.selector);
        perp.openPosition(true, 7, 100 * 1e6);
    }

    function test_invalidLeverage_50_reverts() public {
        _depositAlice(500 * 1e6);
        vm.prank(alice);
        vm.expectRevert(AproxPerp.InvalidLeverage.selector);
        perp.openPosition(true, 50, 100 * 1e6);
    }
}
