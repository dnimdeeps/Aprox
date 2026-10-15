/**
 * usePriceFeed — WebSocket price feed from operator server
 *
 * Connects to /ws/price (proxied to operator server on port 3001).
 * The server broadcasts two message types over the same socket:
 *   { type: 'price', ... }    — BTC/USD price tick every ~1s
 *   { type: 'payment', ... }  — real x402 Gateway payment receipt every ~5s
 *
 * Payment events come from the server's GatewayClient buyer loop.
 * When BUYER_PRIVATE_KEY is set on the server, these are real on-chain receipts
 * with a verifiable tx hash on Arc Testnet explorer. Without it, they are
 * labelled simulations so the UI is never blank.
 */

import { useState, useEffect, useRef } from 'react'

export interface PriceUpdate {
  type: 'price'
  symbol: string
  price: number    // USD float, e.g. 65000.42
  price8: number   // 8-decimal int, e.g. 6500042000000
  timestamp: number
}

export interface NanopaymentEvent {
  id: string
  timestamp: number
  amount: string       // e.g. "0.0001"
  txRef: string        // tx hash, "testnet-simulation", or "simulation"
  buyerAddress: string
  isReal: boolean      // true only for mainnet real payments
  isTestnet: boolean   // true = testnet simulation, false = mainnet real payment
}

interface PaymentMessage {
  type: 'payment'
  id: string
  timestamp: number
  amount: string
  txRef: string
  buyerAddress: string
  isTestnet: boolean
}

export interface UsePriceFeedReturn {
  price: number | null
  price8: number | null
  lastUpdated: number | null
  isConnected: boolean
  paymentCount: number
  totalPaid: number       // in USDC float
  nanopayments: NanopaymentEvent[]
}

// When VITE_SERVER_URL is set (split deployment: frontend on Netlify, server on Railway)
// use it as the base for WS and polling. Otherwise fall back to the Vite proxy paths.
const SERVER_URL = import.meta.env.VITE_SERVER_URL as string | undefined
const WS_URL = SERVER_URL
  ? `${SERVER_URL.replace(/^http/, 'ws')}/ws/price`
  : '/ws/price'
const POLL_URL = SERVER_URL ? `${SERVER_URL}/price/free` : '/api/price/free'
const PRICE_PER_CALL = 0.0001

export function usePriceFeed(): UsePriceFeedReturn {
  const [price, setPrice] = useState<number | null>(null)
  const [price8, setPrice8] = useState<number | null>(null)
  const [lastUpdated, setLastUpdated] = useState<number | null>(null)
  const [isConnected, setIsConnected] = useState(false)
  const [paymentCount, setPaymentCount] = useState(0)
  const [totalPaid, setTotalPaid] = useState(0)
  const [nanopayments, setNanopayments] = useState<NanopaymentEvent[]>([])

  const wsRef = useRef<WebSocket | null>(null)
  const reconnectRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const fallbackTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const mountedRef = useRef(true)
  const wsConnectedRef = useRef(false)
  const connectRef = useRef<(() => void) | null>(null)

  // HTTP polling fallback — used when WS is unavailable (e.g. sandbox preview proxy)
  const startPolling = () => {
    if (pollRef.current) return
    pollRef.current = setInterval(async () => {
      if (!mountedRef.current || wsConnectedRef.current) return
      try {
        const res = await fetch(POLL_URL)
        if (!res.ok) return
        const data = await res.json() as { price: number; price8: number; timestamp: number }
        setPrice(data.price)
        setPrice8(data.price8)
        setLastUpdated(data.timestamp)
        setIsConnected(true)
      } catch {
        // ignore
      }
    }, 1000)
  }

  const stopPolling = () => {
    if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null }
  }

  connectRef.current = () => {
    if (!mountedRef.current) return
    if (wsRef.current?.readyState === WebSocket.OPEN) return

    // If WS_URL is already absolute (split deployment), use it directly
    const wsUrl = WS_URL.startsWith('ws') ? WS_URL : `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}${WS_URL}`
    const ws = new WebSocket(wsUrl)
    wsRef.current = ws

    // If WS doesn't connect within 4s, start HTTP polling
    fallbackTimerRef.current = setTimeout(() => {
      if (!wsConnectedRef.current && mountedRef.current) startPolling()
    }, 4000)

    ws.onopen = () => {
      if (!mountedRef.current) return
      wsConnectedRef.current = true
      stopPolling()
      if (fallbackTimerRef.current) { clearTimeout(fallbackTimerRef.current); fallbackTimerRef.current = null }
      setIsConnected(true)
    }

    ws.onmessage = (evt) => {
      if (!mountedRef.current) return
      try {
        const msg = JSON.parse(evt.data as string) as PriceUpdate | PaymentMessage

        if (msg.type === 'price') {
          setPrice(msg.price)
          setPrice8(msg.price8)
          setLastUpdated(msg.timestamp)
          return
        }

        if (msg.type === 'payment') {
          const isTestnet = msg.isTestnet ?? (msg.txRef === 'testnet-simulation' || msg.txRef === 'simulation')
          const isReal = !isTestnet && msg.txRef.startsWith('0x')
          const event: NanopaymentEvent = {
            id: msg.id,
            timestamp: msg.timestamp,
            amount: msg.amount,
            txRef: msg.txRef,
            buyerAddress: msg.buyerAddress,
            isReal,
            isTestnet,
          }
          if (isReal) {
            setPaymentCount((c) => c + 1)
            setTotalPaid((t) => Math.round((t + PRICE_PER_CALL) * 100_000) / 100_000)
          }
          setNanopayments((prev) => [event, ...prev].slice(0, 20))
        }
      } catch {
        // ignore parse errors
      }
    }

    ws.onclose = () => {
      if (!mountedRef.current) return
      wsConnectedRef.current = false
      wsRef.current = null
      // On WS close, fall back to polling immediately then retry WS
      startPolling()
      reconnectRef.current = setTimeout(() => connectRef.current?.(), 5000)
    }

    ws.onerror = () => { ws.close() }
  }

  useEffect(() => {
    mountedRef.current = true
    connectRef.current?.()
    return () => {
      mountedRef.current = false
      if (reconnectRef.current) clearTimeout(reconnectRef.current)
      if (fallbackTimerRef.current) clearTimeout(fallbackTimerRef.current)
      stopPolling()
      if (wsRef.current) {
        wsRef.current.onclose = null
        wsRef.current.close()
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return { price, price8, lastUpdated, isConnected, paymentCount, totalPaid, nanopayments }
}
