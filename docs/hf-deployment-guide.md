# Aprox — Hugging Face Deployment Guide

## Overview

The app deploys as a **Docker Space** on Hugging Face. One process handles everything:
- Serves the built React frontend (static files from `dist/`)
- Runs the operator server (price feed, x402 gateway, WebSocket)
- Pushes live BTC/USD prices on-chain every second

Port: **7860** (HF Spaces default).

---

## Step 1 — Connect Hugging Face in Arc Studio

1. Open the **Integrations** menu in the Arc Studio workbench header (top right)
2. Click **Connect Hugging Face**
3. Complete OAuth — it redirects to HF and back

---

## Step 2 — Set Secrets in HF Space

Before deploying, you need to pre-configure the secrets. After the Space is created (Step 3), go to:

**HF Space → Settings → Variables and Secrets → New Secret**

Add each of these as a **Secret** (not a Variable — secrets are encrypted):

| Secret name | Value | Notes |
|---|---|---|
| `VITE_CLIENT_KEY` | `TEST_CLIENT_KEY:813e...` | Your Circle Client Key |
| `VITE_CLIENT_URL` | `https://modular-sdk.circle.com/v1/rpc/w3s/buidl` | Circle Modular SDK URL |
| `VITE_APROX_PERP_ADDRESS` | `0x8450963e3fc84433d1EFffdBf33691246fD41a4e` | Deployed contract |
| `VITE_MOCK_PRICE_FEED_ADDRESS` | `0xBbd5ac2614A8bF88308B2Ee880D671766bC524F8` | Price feed contract |
| `OPERATOR_PRIVATE_KEY` | `0x5f73...` | Operator wallet private key |
| `OPERATOR_GATEWAY_ADDRESS` | `0xEcfB...` | Gateway payment receiver |
| `MOCK_PRICE_FEED_ADDRESS` | `0xBbd5...` | Same as VITE_ version |
| `APROX_PERP_ADDRESS` | `0x8450...` | Same as VITE_ version |
| `NETWORK` | `testnet` | Use `mainnet` for Arc Mainnet |
| `BUYER_ADDRESS` | `0x82B2...` | Buyer wallet (x402 demo) |
| `BUYER_PRIVATE_KEY` | `0xb67e...` | Buyer wallet private key |

> **IMPORTANT — Circle Console domain update required:**
> After the Space is live, copy the HF Space URL (e.g. `your-name-aprox.hf.space`).
> Go to Circle Console → Client Keys → edit your key → set **Allowed Domain** to that domain.
> Also update **Wallets → Modular Wallets → Passkey Domain** to the same domain.
> Without this, register/login will return "Invalid credentials".

---

## Step 3 — Deploy

In Arc Studio chat, say: **"deploy this"**

Arc Studio will:
1. Build the frontend (`vite build`) → outputs to `dist/`
2. Upload the full project (including `Dockerfile`, `server/`, `dist/`) to HF
3. HF builds the Docker image and starts the container
4. Returns the live URL when ready (typically 3-8 minutes)

---

## Step 4 — Update Circle Console

Once deployed, your Space URL looks like:
```
https://YOUR-USERNAME-aprox.hf.space
```

Go to [console.circle.com](https://console.circle.com) → Testnet:

1. **Keys → Client Keys** → edit your key
   - **Allowed Domain**: `YOUR-USERNAME-aprox.hf.space`

2. **Wallets → Modular Wallets → Configurator → Passkeys**
   - **Passkey Domain Name**: `YOUR-USERNAME-aprox.hf.space`

3. Save both. Changes take effect immediately.

---

## Step 5 — Verify WebSocket

After deploying, verify the Binance WebSocket connects by checking the Space logs:

**HF Space → Logs** — look for:
```
[aprox-server] Connected to Binance BTC/USD real-time feed
```

If you see:
```
[aprox-server] Binance WS error: ... — using mock fallback
```
HF has outbound internet access so Binance WS should connect. If it doesn't, check that the Space is not in a restricted network tier.

---

## Step 6 — Test the Deployment

1. Open the Space URL
2. Register a new passkey wallet (your HF Space domain passkey is separate from Arc Studio)
3. Use the "Get test USDC" sidebar button in Arc Studio to fund a wallet, then deposit into the app
4. Open a Long and a Short from two different wallets
5. Verify the price shows live BTC/USD (around $81,000 at time of writing)

---

## Updating the Deployment

After code changes, rebuild and redeploy:

In Arc Studio chat: **"deploy this"**

HF Docker Spaces rebuild from the latest pushed code automatically.

---

## Architecture Diagram

```
Browser (any domain)
  └── Circle Modular Wallet (passkey, ERC-4337)
        ├── Gas Station paymaster — gasless tx
        └── AproxPerpV2.sol (Arc Testnet)
              ├── deposit / openOrder / closeOrder / cancelOrder
              └── MockPriceFeed.sol ← updated every 1s by operator server

HF Docker Container (port 7860)
  ├── Express server
  │     ├── GET /price (x402 gated, 0.0001 USDC)
  │     ├── GET /price/free (internal, Vite proxy)
  │     └── Static dist/ (React frontend)
  ├── WebSocket /ws/price → streams BTC/USD ticks
  ├── Binance WS → real BTC/USD price (mock fallback if unavailable)
  └── pushPriceLoop → MockPriceFeed.updatePrice() on Arc Testnet every 1s
```

---

## Mainnet Checklist (when ready)

- [ ] Change `NETWORK=mainnet` in HF secrets
- [ ] Deploy new contracts to Arc Mainnet (same Foundry scripts)
- [ ] Update `VITE_APROX_PERP_ADDRESS`, `VITE_MOCK_PRICE_FEED_ADDRESS`, `MOCK_PRICE_FEED_ADDRESS`
- [ ] Fund operator wallet on Arc Mainnet with USDC for gas
- [ ] Fund buyer wallet on Arc Mainnet Gateway for real x402 payments
- [ ] Update Circle Console to Arc Mainnet (toggle in top right)
- [ ] Update Client Key Allowed Domain to HF Space URL on mainnet Console
