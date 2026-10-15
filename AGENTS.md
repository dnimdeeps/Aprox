# Aprox — Project Memory

## What it is

Peer-to-peer BTC/USD leveraged perpetuals on Arc. Longs and Shorts match against each other — no reserve, no protocol capital. Circle Modular Wallets + Gas Station for gasless passkey trading.

## Deployed Contracts

### Arc Mainnet (active)
- MockPriceFeed: `0x86Af80cDAC58cfb7707B0d3c253eBF39168A2445`
- AproxPerpV2: `0x8692b92b7cB46e1e86EC428A62EB803E4c1d2e48`
- USDC: `0x3600000000000000000000000000000000000000`
- Operator/Owner: `0xEcfB692d593a349878ef50Df7Bbe3C69bceCeA62`

### Arc Testnet (legacy)
- MockPriceFeed: `0xBbd5ac2614A8bF88308B2Ee880D671766bC524F8`
- AproxPerpV2: `0x8450963e3fc84433d1EFffdBf33691246fD41a4e`

## Environment Variables

### Frontend (`.env`)
- `VITE_CLIENT_KEY` — Circle Client Key
- `VITE_CLIENT_URL` — `https://modular-sdk.circle.com`
- `VITE_APROX_PERP_ADDRESS` — AproxPerpV2 address
- `VITE_MOCK_PRICE_FEED_ADDRESS` — MockPriceFeed address
- `VITE_NETWORK` — `testnet` (default) or `mainnet`

### Operator Server (`server/.env`)
- `OPERATOR_PRIVATE_KEY` — oracle operator wallet key
- `MOCK_PRICE_FEED_ADDRESS` — MockPriceFeed address
- `APROX_PERP_ADDRESS` — AproxPerpV2 address
- `PORT` — `3001`
- `NETWORK` — `testnet` or `mainnet`

## Passkey Domain

Circle Console Client Key and Passkey Domain must match the deployed app's hostname exactly. Current sandbox hostname: `iohzkmin59sfn62004n4l.preview.studio.arc.io`

## Key Files

- `contracts/AproxPerpV2.sol` — core perpetuals contract
- `contracts/MockPriceFeed.sol` — BTC/USD price feed
- `server/index.ts` — operator server
- `src/hooks/useModularWallet.ts` — passkey wallet hook
- `src/hooks/useAproxContract.ts` — contract interactions
- `src/components/TradingPanel.tsx` — trading UI
