# Aprox

Peer-to-peer BTC/USD leveraged perpetuals on Arc Mainnet.

Trade directly against other users — no liquidity pool, no protocol reserve. Collateral is locked in a smart contract and settled at real BTC/USD price. Every action is gasless: no wallet extension, no gas token, just a passkey (fingerprint or Face ID).

**Live app (mainet):** https://classy-frangipane-e74823.netlify.app
**Live app (testnet):** https://resilient-tanuki-ce4499.netlify.app/

---

## How it works

When you open a Long or Short position, your USDC collateral is locked in the contract. The contract matches you FIFO against an existing counterpart on the opposite side. If a match exists, both positions are active and PnL accrues in real time against the live BTC/USD price. If no counterpart exists, your order waits in a queue until one arrives.

When you close, the contract reads the current BTC/USD oracle price, computes PnL, and settles the difference between both locked collateral pools. Neither side can lose more than their deposited collateral.

Leverage options: 2x, 5x, 10x.

---

## How to try it (Arc Mainnet, real USDC)

**Browser requirement:** use Chrome, Firefox, or Safari. Brave and browsers with ad blockers enabled will block the passkey wallet SDK requests and nothing will work. If you see `ERR_BLOCKED_BY_CLIENT` errors in the console, switch to a clean browser profile or incognito.

### Step 1 — Register a passkey wallet

Open the app and click **Register**. Your browser will prompt you to save a passkey (fingerprint, Face ID, or security key). This creates a smart contract wallet on Arc Mainnet. No seed phrase, no extension needed.

Your wallet address appears in the header. Copy it — you will need it to send USDC to yourself.

### Step 2 — Fund your wallet

Send Arc Mainnet USDC to your smart account address from MetaMask or any other wallet. The USDC contract on Arc Mainnet is:

```
0x3600000000000000000000000000000000000000
```

Wait a few seconds and you will see your wallet balance update under **Free Balance**.

### Step 3 — Deposit into the trading contract

In the **Funds** tab, enter an amount and click **Deposit**. Your passkey will prompt once to sign the transaction. After confirmation (usually under 2 seconds), your Free Balance updates and you can open positions.

### Step 4 — Open a position

Switch to the **Trade** tab. Choose Long or Short, set your leverage and collateral amount, and click **Open**. If a counterpart exists in the queue, your position matches immediately. Otherwise it waits pending until matched.

### Step 5 — Close your position

Your active orders appear at the bottom of the Trade tab. Click **Close** on any order to settle PnL at the current BTC/USD price. Profits are added to your Free Balance, losses are deducted.

### Step 6 — Withdraw funds

Two options in the **Funds** tab:

- **Withdraw to wallet** — moves USDC from your Free Balance back to your smart account address.
- **Send to external wallet** — paste any destination address (your MetaMask, another wallet) and send USDC directly from your smart account. This is how you get funds back to MetaMask.

All actions are gasless — Circle Gas Station covers transaction fees.

---

## Deployed contracts (Arc Mainnet)

| Contract | Address |
|---|---|
| AproxPerpV2 | [0x8692b92b7cB46e1e86EC428A62EB803E4c1d2e48](https://explorer.arc.io/address/0x8692b92b7cB46e1e86EC428A62EB803E4c1d2e48) |
| MockPriceFeed | [0x86Af80cDAC58cfb7707B0d3c253eBF39168A2445](https://explorer.arc.io/address/0x86Af80cDAC58cfb7707B0d3c253eBF39168A2445) |

Chain ID: 5042 — Arc Mainnet  
USDC: `0x3600000000000000000000000000000000000000`

---

## Price feed

BTC/USD price is sourced from Binance WebSocket (real-time tick data) and pushed on-chain every second by an operator server. Fallbacks: Coinbase REST → Binance REST → CoinGecko REST. A 20% per-update circuit breaker prevents oracle manipulation. The operator server runs on Railway.

---

## Circle products used

- **Circle Modular Wallets (ERC-4337)** — passkey-authenticated smart accounts. Users register once with biometrics; every subsequent action is a gasless user operation.
- **Circle Gas Station** — sponsors all transaction fees so users only ever hold USDC.
- **Arc Mainnet** — USDC is the native gas token. The entire app runs on one asset.

---

## Run locally

```bash
# Install dependencies
bun install

# Copy env template and fill in your values
cp .env.example .env

# Start the frontend
bun run dev

# Start the operator server (separate terminal)
cd server
bun install
cp env-example.txt .env
bun run dev
```

Required env vars (frontend):

```
VITE_NETWORK=mainnet
VITE_APROX_PERP_ADDRESS=0x8692b92b7cB46e1e86EC428A62EB803E4c1d2e48
VITE_MOCK_PRICE_FEED_ADDRESS=0x86Af80cDAC58cfb7707B0d3c253eBF39168A2445
VITE_CLIENT_KEY=LIVE_CLIENT_KEY:...   # from Circle Console
VITE_CLIENT_URL=https://modular-sdk.circle.com/v1/rpc/w3s/buidl
VITE_SERVER_URL=https://your-railway-url.up.railway.app
```

Required env vars (server):

```
NETWORK=mainnet
MOCK_PRICE_FEED_ADDRESS=0x86Af80cDAC58cfb7707B0d3c253eBF39168A2445
APROX_PERP_ADDRESS=0x8692b92b7cB46e1e86EC428A62EB803E4c1d2e48
OPERATOR_PRIVATE_KEY=0x...
PORT=3001
```

---

## Future work

- Decentralized oracle (Chainlink or Pyth) to remove operator price trust
- Independent security audit of AproxPerpV2.sol
- Bounded/batched position settlement to remove the unbounded-loop gas risk
- Multiple trading pairs beyond BTC/USD
- Circle Gateway nanopayments for premium price feed access
