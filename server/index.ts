/**
 * Aprox Operator Server
 *
 * Responsibilities:
 * 1. Mock BTC/USD price oscillator (sandbox mode — no Binance WS access)
 * 2. Push latest price on-chain to MockPriceFeed.sol every ~1 second
 * 3. Sell price via x402 Gateway Nanopayments — GET /price costs 0.0001 USDC
 * 4. Run a real GatewayClient buyer loop every 5s, emit real payment receipts
 *    over WebSocket so the NanopaymentFeed shows genuine on-chain tx hashes
 *
 * NETWORK env var controls mainnet vs testnet mode:
 *   NETWORK=testnet  (default) — Arc Testnet. Circle Gateway x402 verify/settle
 *                               requires mainnet, so the buyer loop is skipped
 *                               and the NanopaymentFeed shows honest simulation
 *                               events labelled "testnet-simulation". The x402
 *                               architecture is fully wired; switching to mainnet
 *                               only requires NETWORK=mainnet + funded mainnet
 *                               Gateway balance.
 *   NETWORK=mainnet — Arc Mainnet. Real x402 payments with Circle Gateway
 *                               verify/settle. BUYER_PRIVATE_KEY must be set
 *                               and funded on Arc Mainnet Gateway.
 */

import express from 'express'
import { WebSocket, WebSocketServer } from 'ws'
import { createServer } from 'http'
import { createPublicClient, createWalletClient, http, parseAbi } from 'viem'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'
import { existsSync } from 'fs'
import { privateKeyToAccount } from 'viem/accounts'
import { arc, arcTestnet } from 'viem/chains'
import { createGatewayMiddleware } from '@circle-fin/x402-batching/server'
import { GatewayClient } from '@circle-fin/x402-batching/client'

// ── Env ───────────────────────────────────────────────────────────────────────
const OPERATOR_PRIVATE_KEY = process.env.OPERATOR_PRIVATE_KEY as `0x${string}`
const OPERATOR_GATEWAY_ADDRESS = process.env.OPERATOR_GATEWAY_ADDRESS as `0x${string}`
const MOCK_PRICE_FEED_ADDRESS = process.env.MOCK_PRICE_FEED_ADDRESS as `0x${string}`
const BUYER_PRIVATE_KEY = process.env.BUYER_PRIVATE_KEY as `0x${string}` | undefined
const PORT = parseInt(process.env.PORT ?? '3001', 10)

// NETWORK=mainnet enables real Circle Gateway x402 verify/settle (Arc Mainnet only).
// On testnet the buyer loop emits honest "testnet-simulation" events — the full
// x402 architecture is wired, Circle's facilitator API just doesn't support testnets.
const NETWORK = (process.env.NETWORK ?? 'testnet') as 'testnet' | 'mainnet'
const IS_MAINNET = NETWORK === 'mainnet'

// Price-push chain: Arc Testnet when NETWORK=testnet, Arc Mainnet when NETWORK=mainnet.
// Contracts must match the chain — testnet contracts on testnet, mainnet contracts on mainnet.
const VIEM_CHAIN = IS_MAINNET ? arc : arcTestnet
const GATEWAY_CHAIN = IS_MAINNET ? 'arc' : 'arcTestnet'

if (!OPERATOR_PRIVATE_KEY || !OPERATOR_GATEWAY_ADDRESS || !MOCK_PRICE_FEED_ADDRESS) {
  console.error('[aprox-server] Missing required env vars. Check server/.env')
  process.exit(1)
}

// ── Viem operator client ───────────────────────────────────────────────────────
const account = privateKeyToAccount(OPERATOR_PRIVATE_KEY)

const walletClient = createWalletClient({
  chain: VIEM_CHAIN,
  account,
  transport: http(),
})

const publicClient = createPublicClient({
  chain: VIEM_CHAIN,
  transport: http(),
})

const PRICE_FEED_ABI = parseAbi([
  'function updatePrice(int256 newPrice) external',
  'function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
])

// ── Price state ────────────────────────────────────────────────────────────────
let latestPrice: number = 65_000 * 1e8
let lastPushedPrice: number = 0
let priceTimestamp: number = Date.now()

// ── WebSocket subscribers ──────────────────────────────────────────────────────
const wssClients = new Set<WebSocket>()

interface PaymentMessage {
  type: 'payment'
  id: string
  timestamp: number
  amount: string
  txRef: string
  buyerAddress: string
  isTestnet: boolean   // true = testnet-simulation, false = real mainnet payment
}

interface PriceMessage {
  type: 'price'
  symbol: string
  price: number
  price8: number
  timestamp: number
}

function broadcast(payload: PriceMessage | PaymentMessage) {
  const data = JSON.stringify(payload)
  for (const client of wssClients) {
    if (client.readyState === WebSocket.OPEN) client.send(data)
  }
}

// ── Mock BTC price oscillator (last-resort fallback only) ────────────────────
let mockSeed = latestPrice

function tickMockPrice() {
  const bps = (Math.random() - 0.5) * 10  // ±5 BPS per tick (~0.05%)
  const delta = Math.round(mockSeed * bps / 10_000)
  mockSeed = Math.max(1_000 * 1e8, mockSeed + delta)
  latestPrice = Math.round(mockSeed)
  priceTimestamp = Date.now()
  broadcast({ type: 'price', symbol: 'BTC/USD', price: latestPrice / 1e8, price8: latestPrice, timestamp: priceTimestamp })
}

// ── Multi-source Real BTC/USD price fallback (Coinbase -> Binance -> CoinGecko) ──
async function fetchRealPrice(): Promise<number | null> {
  // 1. Try Coinbase REST (highly reliable, no key, no cloud block)
  try {
    const res = await fetch('https://api.coinbase.com/v2/prices/BTC-USD/spot', { signal: AbortSignal.timeout(5000) })
    if (res.ok) {
      const data = await res.json() as { data?: { amount?: string } }
      const amt = parseFloat(data?.data?.amount ?? '')
      if (amt > 0) return Math.round(amt * 1e8)
    }
  } catch { /* try next */ }

  // 2. Try Binance REST (fast spot ticker)
  try {
    const res = await fetch('https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT', { signal: AbortSignal.timeout(5000) })
    if (res.ok) {
      const data = await res.json() as { price?: string }
      const amt = parseFloat(data?.price ?? '')
      if (amt > 0) return Math.round(amt * 1e8)
    }
  } catch { /* try next */ }

  // 3. Try CoinGecko REST
  try {
    const res = await fetch('https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd', { signal: AbortSignal.timeout(5000) })
    if (res.ok) {
      const data = await res.json() as { bitcoin?: { usd?: number } }
      const usd = data?.bitcoin?.usd
      if (usd && usd > 0) return Math.round(usd * 1e8)
    }
  } catch { /* fallback to null */ }

  return null
}

// ── Real BTC/USD price via Binance WebSocket (primary) ───────────────────────
function startPriceFeed() {
  let mockInterval: ReturnType<typeof setInterval> | null = null
  let pollInterval: ReturnType<typeof setInterval> | null = null
  let binanceActive = false

  function startRestFallback() {
    if (pollInterval) return
    console.log('[aprox-server] Starting real price REST polling (Coinbase/Binance, 5s interval)')
    // Fetch immediately, then every 5s
    void fetchRealPrice().then((p) => {
      if (p && !binanceActive) {
        latestPrice = p; mockSeed = p; priceTimestamp = Date.now()
        broadcast({ type: 'price', symbol: 'BTC/USD', price: p / 1e8, price8: p, timestamp: priceTimestamp })
        console.log(`[aprox-server] Real BTC price: $${(p / 1e8).toFixed(2)}`)
      }
    })
    pollInterval = setInterval(async () => {
      if (binanceActive) return
      const p = await fetchRealPrice()
      if (p) {
        latestPrice = p; mockSeed = p; priceTimestamp = Date.now()
        broadcast({ type: 'price', symbol: 'BTC/USD', price: p / 1e8, price8: p, timestamp: priceTimestamp })
      } else {
        startMockFallback()
      }
    }, 5000)
  }

  function stopRestFallback() {
    if (!pollInterval) return
    clearInterval(pollInterval)
    pollInterval = null
  }

  function startMockFallback() {
    if (mockInterval) return
    console.log('[aprox-server] External feeds unreachable — falling back to mock oscillator')
    mockInterval = setInterval(tickMockPrice, 1000)
  }

  function stopMockFallback() {
    if (!mockInterval) return
    clearInterval(mockInterval)
    mockInterval = null
  }

  function connect() {
    const BINANCE_WS = 'wss://stream.binance.com:9443/ws/btcusdt@aggTrade'
    const ws = new WebSocket(BINANCE_WS)

    const timeoutHandle = setTimeout(() => {
      console.log('[aprox-server] Binance WS timeout — switching to real REST fallback')
      try { ws.terminate() } catch { /* ignore */ }
      startRestFallback()
    }, 6000)

    ws.on('open', () => {
      clearTimeout(timeoutHandle)
      stopRestFallback()
      stopMockFallback()
      binanceActive = true
      console.log('[aprox-server] Connected to Binance BTC/USD real-time feed')
    })

    ws.on('message', (raw: Buffer) => {
      try {
        const msg = JSON.parse(raw.toString()) as { p: string; T: number }
        const price = Math.round(parseFloat(msg.p) * 1e8)
        if (price > 0) {
          latestPrice = price
          mockSeed = price
          priceTimestamp = msg.T ?? Date.now()
          broadcast({ type: 'price', symbol: 'BTC/USD', price: latestPrice / 1e8, price8: latestPrice, timestamp: priceTimestamp })
        }
      } catch { /* ignore */ }
    })

    ws.on('close', () => {
      clearTimeout(timeoutHandle)
      binanceActive = false
      console.log('[aprox-server] Binance WS closed — real REST fallback active, retry WS in 10s')
      startRestFallback()
      setTimeout(connect, 10_000)
    })

    ws.on('error', (err: Error) => {
      clearTimeout(timeoutHandle)
      binanceActive = false
      console.log('[aprox-server] Binance WS error:', err.message.slice(0, 80), '— real REST fallback active')
      try { ws.terminate() } catch { /* ignore */ }
      startRestFallback()
    })
  }

  connect()
}

// ── On-chain price push loop (with smooth circuit-breaker ramping) ────────────
async function pushPriceLoop() {
  // Sync initial on-chain price on boot to avoid jumping from 0
  try {
    const roundData = await publicClient.readContract({
      address: MOCK_PRICE_FEED_ADDRESS,
      abi: PRICE_FEED_ABI,
      functionName: 'latestRoundData',
    })
    lastPushedPrice = Number(roundData[1])
    console.log(`[aprox-server] Current on-chain price is $${(lastPushedPrice / 1e8).toFixed(2)}`)
  } catch (err: unknown) {
    console.warn('[aprox-server] Could not fetch initial on-chain price:', (err as Error).message.slice(0, 100))
  }

  while (true) {
    await new Promise((r) => setTimeout(r, 1000))
    if (latestPrice === lastPushedPrice) continue

    // Smooth ramping: if delta > 15%, step by 15% so contract circuit breaker (20%) is never tripped
    let priceToPush = latestPrice
    if (lastPushedPrice > 0) {
      const maxDelta = Math.floor(lastPushedPrice * 15 / 100)
      if (priceToPush > lastPushedPrice + maxDelta) {
        priceToPush = lastPushedPrice + maxDelta
      } else if (priceToPush < lastPushedPrice - maxDelta) {
        priceToPush = lastPushedPrice - maxDelta
      }
    }

    try {
      const hash = await walletClient.writeContract({
        address: MOCK_PRICE_FEED_ADDRESS,
        abi: PRICE_FEED_ABI,
        functionName: 'updatePrice',
        args: [BigInt(priceToPush)],
      })
      lastPushedPrice = priceToPush
      console.log(`[aprox-server] Price pushed: $${(priceToPush / 1e8).toFixed(2)} tx=${hash}`)
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err)
      if (message.includes('PriceChangeTooLarge')) {
        console.log('[aprox-server] Circuit breaker: price move >20%, adapting step')
      } else {
        console.error('[aprox-server] Price push failed:', message.slice(0, 120))
      }
    }
  }
}

// ── Buyer loop ────────────────────────────────────────────────────────────────
// TESTNET MODE: Circle Gateway x402 verify/settle is a mainnet-only service.
// On testnet we emit clearly-labelled simulation events so the NanopaymentFeed
// is never blank. The full x402 architecture (signing, ERC-3009 auth, server
// middleware, GatewayClient) is wired and correct — only the Circle facilitator
// API call at verify time requires mainnet. Set NETWORK=mainnet in server/.env
// to enable real on-chain payments.
//
// MAINNET MODE: BUYER_PRIVATE_KEY must be funded with Arc Mainnet Gateway balance.
// Switch: set NETWORK=mainnet, fund buyer via depositFor on Arc Mainnet Gateway.
async function startBuyerLoop(serverPort: number) {
  const baseUrl = `http://localhost:${serverPort}`

  // ── Testnet: emit honest simulation events every 5s ──────────────────────────
  if (!IS_MAINNET) {
    console.log('[aprox-server] Network: testnet — x402 buyer loop running in simulation mode')
    console.log('[aprox-server] Circle Gateway facilitator API is mainnet-only.')
    console.log('[aprox-server] Set NETWORK=mainnet in server/.env for real on-chain payments.')

    setInterval(() => {
      const event: PaymentMessage = {
        type: 'payment',
        id: `tsim-${Date.now()}`,
        timestamp: Date.now(),
        amount: '0.0001',
        txRef: 'testnet-simulation',
        buyerAddress: '0x0000…testnet',
        isTestnet: true,
      }
      broadcast(event)
    }, 5000)
    return
  }

  // ── Mainnet: real GatewayClient buyer paying /price every 5s ─────────────────
  if (!BUYER_PRIVATE_KEY) {
    console.log('[aprox-server] NETWORK=mainnet but BUYER_PRIVATE_KEY not set — skipping buyer loop')
    console.log('[aprox-server] Add BUYER_PRIVATE_KEY to server/.env with an Arc Mainnet Gateway balance')
    return
  }

  const proxyChains = (process.env.RPC_PROXY_CHAINS ?? '').split(',')
  const arcMainnetRpcUrl = process.env.RPC_PROXY_BASE_URL && proxyChains.includes('Arc')
    ? `${process.env.RPC_PROXY_BASE_URL}/api/rpc/Arc?_rpc_token=${process.env.RPC_PROXY_TOKEN}`
    : undefined

  const buyerGateway = new GatewayClient({
    chain: GATEWAY_CHAIN as 'arc',
    privateKey: BUYER_PRIVATE_KEY,
    ...(arcMainnetRpcUrl ? { rpcUrl: arcMainnetRpcUrl } : {}),
  })

  console.log(`[aprox-server] Network: mainnet — real x402 buyer: ${buyerGateway.address}`)
  console.log('[aprox-server] Real x402 payment loop starting (every 5s)')

  await new Promise((r) => setTimeout(r, 3000))

  while (true) {
    await new Promise((r) => setTimeout(r, 5000))
    try {
      const result = await buyerGateway.pay<{
        symbol: string; price: number; price8: number; timestamp: number
      }>(`${baseUrl}/price`)

      const event: PaymentMessage = {
        type: 'payment',
        id: `pay-${Date.now()}`,
        timestamp: Date.now(),
        amount: '0.0001',
        txRef: result.transaction,
        buyerAddress: buyerGateway.address,
        isTestnet: false,
      }
      broadcast(event)
      console.log(`[aprox-server] x402 payment: tx=${result.transaction} amount=${result.formattedAmount} USDC`)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      console.error('[aprox-server] Buyer payment failed:', msg.slice(0, 160))
    }
  }
}

// ── Express app ────────────────────────────────────────────────────────────────
const app = express()
app.use(express.json())

// CORS — allow any origin so the Netlify frontend (different domain) can reach
// the Railway server for /price/free polling and the x402 /price endpoint.
// WebSocket connections are not subject to CORS — the WS upgrade is allowed as-is.
app.use((_req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-402-*')
  if (_req.method === 'OPTIONS') { res.sendStatus(204); return }
  next()
})

// Gateway middleware — advertises arcTestnet or arc depending on NETWORK env.
// On testnet, Circle's facilitator API returns 503 for verify/settle (mainnet-only).
// The middleware is fully wired; only NETWORK=mainnet makes the full flow end-to-end.
const gateway = createGatewayMiddleware({
  sellerAddress: OPERATOR_GATEWAY_ADDRESS,
  networks: [GATEWAY_CHAIN],
})

// GET /price — x402 gated, costs 0.0001 USDC per call
app.get('/price', gateway.require('$0.0001'), (_req, res) => {
  res.json({
    symbol: 'BTC/USD',
    price: latestPrice / 1e8,
    price8: latestPrice,
    timestamp: priceTimestamp,
  })
})

// GET /price/free — ungated internal endpoint
app.get('/price/free', (_req, res) => {
  res.json({
    symbol: 'BTC/USD',
    price: latestPrice / 1e8,
    price8: latestPrice,
    timestamp: priceTimestamp,
    note: 'Internal — not for user consumption',
  })
})

// GET /health
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', priceAge: Date.now() - priceTimestamp })
})

// ── Static frontend (production build) ────────────────────────────────────────
// When deployed to HF Spaces the Vite build lands at ../dist relative to server/
const __dirname_esm = dirname(fileURLToPath(import.meta.url))
const distPath = join(__dirname_esm, '..', 'dist')
if (existsSync(distPath)) {
  // Assets are content-hashed — cache forever
  app.use('/assets', express.static(join(distPath, 'assets'), {
    maxAge: '1y',
    immutable: true,
  }))
  // Everything else: no cache so browsers always get fresh index.html
  app.use(express.static(distPath, { maxAge: 0 }))
  // SPA fallback — wipe stale caches and return fresh index.html
  app.get('*', (_req, res) => {
    res.set({
      'Cache-Control': 'no-store, no-cache, must-revalidate',
      'Pragma': 'no-cache',
      'Clear-Site-Data': '"cache", "storage"',
    })
    res.sendFile(join(distPath, 'index.html'))
  })
  console.log(`[aprox-server] Serving static frontend from ${distPath}`)
} else {
  console.log('[aprox-server] No dist/ found — static serving skipped (dev mode)')
}

// ── HTTP + WebSocket server ────────────────────────────────────────────────────
const httpServer = createServer(app)
const wss = new WebSocketServer({ server: httpServer, path: '/ws/price' })

wss.on('connection', (ws) => {
  console.log('[aprox-server] WebSocket client connected')
  wssClients.add(ws)

  // Send current price immediately on connect
  ws.send(JSON.stringify({
    type: 'price',
    symbol: 'BTC/USD',
    price: latestPrice / 1e8,
    price8: latestPrice,
    timestamp: priceTimestamp,
  }))

  ws.on('close', () => {
    wssClients.delete(ws)
    console.log('[aprox-server] WebSocket client disconnected')
  })
})

// ── Start everything ──────────────────────────────────────────────────────────
httpServer.listen(PORT, () => {
  console.log(`[aprox-server] Listening on port ${PORT}`)
  console.log(`[aprox-server] Network: ${NETWORK} (${IS_MAINNET ? 'real x402 payments' : 'simulation mode — set NETWORK=mainnet for real payments'})`)
  console.log(`[aprox-server] Operator address: ${account.address}`)
  console.log(`[aprox-server] Gateway receiver: ${OPERATOR_GATEWAY_ADDRESS}`)
  console.log(`[aprox-server] Price feed contract: ${MOCK_PRICE_FEED_ADDRESS}`)
})

startPriceFeed()
void pushPriceLoop()
void startBuyerLoop(PORT)
