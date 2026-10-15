# Aprox — Roadmap & Known Limitations

This document covers what was found in the security review of the current contracts, what it means for the hackathon demo, and what would need to be built to turn this into a production protocol.

---

## Current Status

Aprox is a functional hackathon demo. The contracts work correctly for normal usage — deposit, open a position, close, withdraw. The issues documented below are real but mostly require adversarial or edge-case conditions to trigger. For a reviewed demo with careful usage they are acceptable. They are **not** acceptable for a public permissionless protocol with significant TVL.

---

## Security Review Findings

### Critical

**1. Uncapped PnL payout can exceed pair escrow**

With leverage, a profitable close can be credited more USDC than the two locked collateral pools contain. For example at 10x leverage, a 10% price move makes `pnl = locked * 10 * 0.10 = locked`, so `closerPayout = locked + locked = 2*locked` — that's fine, the loser gets zero. But if price moves 11%, `closerPayout = 2.1 * locked`, which is more than the entire pair's escrow. The excess comes from other users' funds.

This only happens at extreme price moves with high leverage, and the 20% circuit breaker in `MockPriceFeed` limits single-update swings. For the demo it is unlikely to trigger. For production it must be fixed.

**Fix for production:** cap per-pair payout to `2 * lockedCollateral`. The math becomes: `closerPayout = min(locked + pnl, 2*locked)`, loser gets the remainder.

---

### High

**2. Unbounded pair loops can permanently lock a position**

`closeOrder` and `liquidate` loop over all matched pairs for an order. A sufficiently fragmented order (many small partial fills) could exceed the block gas limit, making the position impossible to close or liquidate. In adversarial hands, an attacker could split their own order into many tiny pieces to avoid liquidation.

**Fix for production:** enforce a minimum order size (e.g. 1 USDC), cap maximum pairs per order, or add a batched settlement API that processes N pairs per call.

**3. MockPriceFeed operator can manipulate price**

The 20% per-update cap is bypassable with multiple sequential transactions. An operator with a compromised key could force liquidations or favorable settlements. This is documented and expected for a hackathon, but it is a real centralization risk.

**Fix for production:** replace `MockPriceFeed` with Chainlink or Pyth when available on Arc Mainnet. Add multi-sig control over the oracle operator key.

**4. FIFO matching is not actually FIFO**

The contract documents FIFO (first-in, first-out) queue matching, but queue removal uses swap-and-pop, which reorders entries. Traders who submitted orders first may not be matched first.

**Fix for production:** use a proper head-pointer queue (head index + append-only array, or a linked list) to preserve true time priority.

**5. Oracle round completeness not validated**

`latestRoundData()` is called but only `answer > 0` and staleness are checked. Full Chainlink round validation should also check `answeredInRound >= roundId`.

**Fix for production:** add standard Chainlink round validation on every price read.

**6. Oracle failure bricks all trading**

The price feed address is immutable. If the oracle contract becomes unavailable, `openOrder`, `closeOrder`, and `liquidate` all revert permanently and positions cannot be closed.

**Fix for production:** add a governed oracle replacement path and an emergency settlement mode that allows positions to close at a last-known price if the oracle is stale beyond a second threshold.

**7. Admin changes emit no events**

`setFeeRecipient` and `transferOwnership` do not emit events, making them invisible to off-chain monitoring.

**Fix for production:** emit events for all privileged state changes.

---

### Low / Informational

**8. Fee-on-transfer token assumption**

`deposit` credits the requested `amount` without measuring what was actually received. USDC is not fee-on-transfer, so this is not a real risk here, but the code would be wrong if the token changed.

**9. No fee mechanism**

`feeRecipient` is stored but never used. There is no protocol revenue. This is fine for a demo.

---

## What This Means for the Hackathon

For the hackathon demo the app is safe to use with the amounts involved. The critical PnL cap issue requires both 10x leverage AND a >10% price move in one direction without triggering the 20% oracle circuit breaker first. The dust-splitting attack requires deliberately adversarial behavior. Normal users going through the demo flow will not hit any of these.

The oracle manipulation risk is real but the operator key is controlled by the project — it is not permissionless.

---

## Production Roadmap

These are the things that must be done before Aprox could handle significant real user funds:

### Smart Contract

- [ ] Cap per-pair payout to `2 * lockedCollateral` to eliminate the PnL drain
- [ ] Enforce minimum order size (1 USDC minimum collateral)
- [ ] Replace swap-pop queue removal with a true FIFO head-pointer queue
- [ ] Add Chainlink/Pyth oracle integration (replace MockPriceFeed)
- [ ] Add full oracle round validation on every price read
- [ ] Add governed oracle replacement path for oracle failure recovery
- [ ] Add emergency settlement mode for extended oracle outage
- [ ] Emit events on `setFeeRecipient` and `transferOwnership`
- [ ] Add a fee mechanism (e.g. 0.1% on close, sent to `feeRecipient`)
- [ ] Independent professional audit before mainnet with real TVL

### Protocol

- [ ] Multi-sig operator key for oracle price updates
- [ ] Multiple positions per address (current limit: one active order per address)
- [ ] Order book UI showing real pending depth per leverage level
- [ ] Partial close (reduce position size without fully closing)
- [ ] Keeper network or automated liquidation bot (currently fully permissionless but no one runs it)

### Infrastructure

- [ ] Always-on operator server (current Railway deployment sleeps on free tier)
- [ ] Stable custom domain for passkey binding (prevents passkey breakage on domain changes)
- [ ] Monitoring and alerting on oracle staleness and operator wallet balance

### Future Integrations

- [ ] Circle Gateway x402 nanopayments on the price feed endpoint — downstream consumers (bots, aggregators, data services) could pay per-call in USDC via HTTP 402, adding protocol revenue without changes to the core contract
- [ ] Chainlink price feed when available on Arc Mainnet
- [ ] CCTP cross-chain deposits so users can deposit USDC from any chain directly into the trading balance
