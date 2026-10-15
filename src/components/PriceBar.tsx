/**
 * PriceBar — Live BTC/USD price display
 *
 * Shows current price, 24h change (client-side estimation from first price seen),
 * and WS connection status.
 */

import { useState, useEffect, useRef } from 'react'
import { Activity, Wifi, WifiOff } from 'lucide-react'
import type { UsePriceFeedReturn } from '@/hooks/usePriceFeed'

interface PriceBarProps {
  feed: UsePriceFeedReturn
}

function formatUSD(n: number) {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(n)
}

export function PriceBar({ feed }: PriceBarProps) {
  const { price, isConnected } = feed
  const [priceDelta, setPriceDelta] = useState(0)
  const firstPrice = useRef<number | null>(null)
  const prevPrice = useRef<number | null>(null)
  const [flash, setFlash] = useState<'up' | 'down' | null>(null)

  useEffect(() => {
    if (price === null) return
    if (firstPrice.current === null) firstPrice.current = price

    if (prevPrice.current !== null && prevPrice.current !== price) {
      setFlash(price > prevPrice.current ? 'up' : 'down')
      setTimeout(() => setFlash(null), 400)
    }
    prevPrice.current = price
    setPriceDelta(((price - firstPrice.current) / firstPrice.current) * 100)
  }, [price])

  const isPositive = priceDelta >= 0

  return (
    <div className="flex items-center gap-4">
      {/* Symbol */}
      <div className="flex items-center gap-2">
        <Activity size={16} className="text-[var(--accent)]" />
        <span className="font-semibold text-sm text-[var(--muted)] display">BTC/USD</span>
      </div>

      {/* Price */}
      <div
        className={`display text-2xl font-semibold tabular-nums transition-colors duration-200 ${
          flash === 'up'
            ? 'text-[var(--success)]'
            : flash === 'down'
              ? 'text-[var(--danger)]'
              : 'text-[var(--ink)]'
        }`}
      >
        {price !== null ? formatUSD(price) : '–'}
      </div>

      {/* Delta from session open */}
      {price !== null && (
        <div
          className={`text-sm font-medium tabular-nums ${
            isPositive ? 'text-[var(--success)]' : 'text-[var(--danger)]'
          }`}
        >
          {isPositive ? '+' : ''}
          {priceDelta.toFixed(3)}%
          <span className="text-[var(--subtle)] text-xs ml-1">(session)</span>
        </div>
      )}

      {/* Connection indicator */}
      <div className="flex items-center gap-1.5 ml-auto">
        {isConnected ? (
          <>
            <span className="w-1.5 h-1.5 rounded-full bg-[var(--success)] animate-pulse" />
            <Wifi size={12} className="text-[var(--success)]" />
            <span className="text-xs text-[var(--subtle)]">Live</span>
          </>
        ) : (
          <>
            <WifiOff size={12} className="text-[var(--danger)]" />
            <span className="text-xs text-[var(--danger)]">Connecting…</span>
          </>
        )}
      </div>
    </div>
  )
}
