# Aprox — Hugging Face Docker Space
#
# Build:  vite build (frontend → dist/)
# Serve:  bun run server/index.ts (Express serves dist/ + API + WebSocket)
# Port:   7860 (HF Spaces default)
#
# Required HF Space secrets (set in Space Settings → Repository secrets):
#   OPERATOR_PRIVATE_KEY    — operator wallet private key (0x...)
#   OPERATOR_GATEWAY_ADDRESS — Gateway wallet receiving x402 payments
#   MOCK_PRICE_FEED_ADDRESS  — deployed MockPriceFeed contract address
#   VITE_CLIENT_KEY          — Circle Client Key (TEST_CLIENT_KEY:... or LIVE_CLIENT_KEY:...)
#   VITE_APROX_PERP_ADDRESS  — deployed AproxPerpV2 contract address
#   VITE_MOCK_PRICE_FEED_ADDRESS — same as MOCK_PRICE_FEED_ADDRESS
#   VITE_CLIENT_URL          — https://modular-sdk.circle.com/v1/rpc/w3s/buidl
#   NETWORK                  — testnet or mainnet
#
# Optional (mainnet x402 real payments):
#   BUYER_PRIVATE_KEY        — buyer wallet private key for x402 buyer loop
#   BUYER_ADDRESS            — buyer wallet address

FROM oven/bun:latest

WORKDIR /app

# ── Copy and install root deps ─────────────────────────────────────────────
COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile

# ── Copy and install server deps ──────────────────────────────────────────
COPY server/package.json server/bun.lock* ./server/
RUN cd server && bun install --frozen-lockfile

# ── Copy source ────────────────────────────────────────────────────────────
COPY . .

# ── Build frontend ─────────────────────────────────────────────────────────
# VITE_ vars are baked into the bundle at build time.
# They are passed as build args and written to .env before the build.
ARG VITE_CLIENT_KEY=""
ARG VITE_CLIENT_URL="https://modular-sdk.circle.com/v1/rpc/w3s/buidl"
ARG VITE_APROX_PERP_ADDRESS=""
ARG VITE_MOCK_PRICE_FEED_ADDRESS=""

RUN printf "VITE_CLIENT_KEY=%s\nVITE_CLIENT_URL=%s\nVITE_APROX_PERP_ADDRESS=%s\nVITE_MOCK_PRICE_FEED_ADDRESS=%s\n" \
    "$VITE_CLIENT_KEY" "$VITE_CLIENT_URL" "$VITE_APROX_PERP_ADDRESS" "$VITE_MOCK_PRICE_FEED_ADDRESS" \
    > .env

RUN bun run vite build

# ── Runtime env defaults ───────────────────────────────────────────────────
ENV PORT=7860
ENV NETWORK=testnet

# HF Spaces runs as a non-root user — no port < 1024
EXPOSE 7860

# ── Start ─────────────────────────────────────────────────────────────────
CMD ["bun", "run", "server/index.ts"]
