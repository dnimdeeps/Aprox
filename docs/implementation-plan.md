# Aprox — Design Notes

## Core mechanic

Longs and Shorts of the same leverage are matched FIFO. Both sides lock USDC. When one closes, the contract reads the BTC/USD oracle price, computes PnL, and settles from the counterpart's locked collateral. No reserve, no protocol capital.

Partial fills are supported — if only 6 USDC of counterpart exists for a 10 USDC order, 6 fills immediately and 4 stays pending. The pending portion can be cancelled at any time for an instant refund.

Order states: `PENDING` → `ACTIVE` → `CLOSED` / `CANCELLED`

## Price feed

The operator server connects to Binance WebSocket for real BTC/USD prices, with REST fallback to Coinbase then CoinGecko. It pushes the price on-chain every second via `MockPriceFeed.sol` (Chainlink-compatible interface, 20% per-update circuit breaker). The frontend receives prices over WebSocket from the same server.

## What to operate

- Operator wallet with USDC for gas (price push every second)
- Circle Client Key + Gas Station policy for the app's domain
