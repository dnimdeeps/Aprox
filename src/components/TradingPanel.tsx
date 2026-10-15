/**
 * TradingPanel — V2 Peer-to-Peer order book UI
 *
 * Multiple open orders per wallet are supported — the contract has no limit.
 * All active/pending orders are shown as cards; the open-new-order form is
 * always visible below them.
 *
 * Order lifecycle:
 *   PENDING  — collateral locked, waiting for counterpart
 *   ACTIVE   — matched, PnL accruing live
 *   CLOSED   — settled
 *   CANCELLED — pending remainder refunded
 *
 * All transactions are gasless (ERC-4337 via Gas Station paymaster).
 */

import { useState, useEffect, useCallback, useRef } from 'react'
import { TrendingUp, TrendingDown, Clock, Zap, X, Loader2, CheckCircle2, AlertTriangle } from 'lucide-react'
import type { UseModularWalletReturn } from '@/hooks/useModularWallet'
import { useAproxContract, OrderStatus } from '@/hooks/useAproxContract'
import type { Order, MarketDepth } from '@/hooks/useAproxContract'
import type { UsePriceFeedReturn } from '@/hooks/usePriceFeed'

interface TradingPanelProps {
  wallet: UseModularWalletReturn
  feed: UsePriceFeedReturn
}

type TxState = 'idle' | 'pending' | 'confirmed' | 'error'

function formatUSD(n: number, decimals = 2) {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  }).format(n)
}

function formatAge(openedAt: bigint): string {
  const seconds = Math.max(0, Math.floor((Date.now() - Number(openedAt) * 1000) / 1000))
  if (seconds < 60) return `${seconds}s`
  const mins = Math.floor(seconds / 60)
  const secs = seconds % 60
  return `${mins}m ${secs}s`
}

const LEVERAGES: Array<2 | 5 | 10> = [2, 5, 10]

const STATUS_LABEL: Record<OrderStatus, string> = {
  [OrderStatus.PENDING]: 'Pending',
  [OrderStatus.ACTIVE]: 'Matched',
  [OrderStatus.CLOSED]: 'Closed',
  [OrderStatus.CANCELLED]: 'Cancelled',
}

const STATUS_COLOR: Record<OrderStatus, string> = {
  [OrderStatus.PENDING]: 'text-yellow-400',
  [OrderStatus.ACTIVE]: 'text-[var(--success)]',
  [OrderStatus.CLOSED]: 'text-[var(--subtle)]',
  [OrderStatus.CANCELLED]: 'text-[var(--danger)]',
}

// ── Single order card ────────────────────────────────────────────────────────

interface OrderCardProps {
  id: bigint
  order: Order
  price8: number | null
  onClose: (id: bigint) => void
  onCancel: (id: bigint) => void
  txPending: boolean
}

function OrderCard({ id, order, price8, onClose, onCancel, txPending }: OrderCardProps) {
  const [age, setAge] = useState(() => formatAge(order.openedAt))

  // Age ticker
  useEffect(() => {
    const tick = () => setAge(formatAge(order.openedAt))
    tick()
    const i = setInterval(tick, 1000)
    return () => clearInterval(i)
  }, [order.openedAt])

  // Live PnL
  let livePnl = 0
  if (order.matchedCollateral > 0n && price8 && order.entryPrice > 0n) {
    const entry = Number(order.entryPrice)
    const current = price8
    const collateral = Number(order.matchedCollateral) / 1e6
    const delta = (current - entry) / entry
    livePnl = (order.isLong ? 1 : -1) * delta * collateral * order.leverage
  }

  const pnlPositive = livePnl >= 0
  const matchedUsd = (Number(order.matchedCollateral) / 1e6).toFixed(2)
  const pendingUsd = (Number(order.pendingCollateral) / 1e6).toFixed(2)
  const entryUsd = order.entryPrice > 0n ? (Number(order.entryPrice) / 1e8).toFixed(2) : null

  const liqPrice = entryUsd && order.entryPrice > 0n
    ? (() => {
        const entry = Number(order.entryPrice) / 1e8
        const factor = 0.8 / order.leverage
        return order.isLong ? entry * (1 - factor) : entry * (1 + factor)
      })()
    : null

  const isActive = order.status === OrderStatus.ACTIVE
  const isPending = order.status === OrderStatus.PENDING

  return (
    <div className={`p-4 rounded-xl border ${
      isActive
        ? 'border-[var(--success)]/30 bg-[var(--success)]/5'
        : 'border-yellow-500/30 bg-yellow-500/5'
    }`}>
      {/* Header */}
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          {order.isLong
            ? <TrendingUp size={14} className="text-[var(--success)]" />
            : <TrendingDown size={14} className="text-[var(--danger)]" />}
          <span className="text-sm font-semibold text-[var(--ink)]">
            {order.isLong ? 'Long' : 'Short'} {order.leverage}x
          </span>
          <span className={`text-xs font-medium flex items-center gap-1 ${STATUS_COLOR[order.status]}`}>
            {isActive ? <Zap size={10} /> : <Clock size={10} />}
            {STATUS_LABEL[order.status]}
          </span>
        </div>
        <span className="text-xs text-[var(--subtle)] mono">#{id.toString()}</span>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-2 gap-2 text-xs mb-3">
        <div>
          <p className="text-[var(--subtle)]">Matched</p>
          <p className="mono text-[var(--ink)]">${matchedUsd}</p>
        </div>
        <div>
          <p className="text-[var(--subtle)]">Pending</p>
          <p className="mono text-[var(--ink)]">${pendingUsd}</p>
        </div>
        {entryUsd && (
          <div>
            <p className="text-[var(--subtle)]">Entry</p>
            <p className="mono text-[var(--ink)]">${parseFloat(entryUsd).toLocaleString()}</p>
          </div>
        )}
        {liqPrice && (
          <div>
            <p className="text-[var(--subtle)]">Liq. Price</p>
            <p className="mono text-[var(--danger)]">${liqPrice.toLocaleString(undefined, { maximumFractionDigits: 0 })}</p>
          </div>
        )}
        <div>
          <p className="text-[var(--subtle)]">Age</p>
          <p className="mono text-[var(--ink)]">{age}</p>
        </div>
      </div>

      {/* Live PnL */}
      {order.matchedCollateral > 0n && (
        <div className={`p-2 rounded-lg mb-3 text-center ${
          pnlPositive ? 'bg-[var(--success)]/10' : 'bg-[var(--danger)]/10'
        }`}>
          <p className="text-xs text-[var(--subtle)] mb-0.5">Live PnL</p>
          <p className={`display text-lg font-semibold tabular-nums ${
            pnlPositive ? 'text-[var(--success)]' : 'text-[var(--danger)]'
          }`}>
            {pnlPositive ? '+' : ''}{livePnl.toFixed(4)} USDC
          </p>
        </div>
      )}

      {/* Pending hint */}
      {isPending && order.matchedCollateral === 0n && (
        <div className="flex items-start gap-2 p-2 rounded-lg bg-yellow-500/10 border border-yellow-500/20 mb-3">
          <Clock size={12} className="text-yellow-400 mt-0.5 shrink-0" />
          <p className="text-xs text-yellow-300">
            Waiting for a counterpart {order.isLong ? 'Short' : 'Long'} order to match.
            Your collateral is locked and safe. Cancel to get it back.
          </p>
        </div>
      )}

      {/* Actions */}
      <div className="flex gap-2">
        {order.matchedCollateral > 0n && (
          <button
            onClick={() => onClose(id)}
            disabled={txPending}
            className="flex-1 py-2 rounded-lg bg-[var(--accent)] text-white text-sm font-medium disabled:opacity-40 hover:bg-[var(--accent-hover)] transition-colors"
          >
            Close Position
          </button>
        )}
        {order.pendingCollateral > 0n && (
          <button
            onClick={() => onCancel(id)}
            disabled={txPending}
            className="flex items-center gap-1.5 px-3 py-2 rounded-lg border border-[var(--border)] text-[var(--subtle)] text-sm font-medium disabled:opacity-40 hover:border-[var(--danger)] hover:text-[var(--danger)] transition-colors"
          >
            <X size={13} />
            Cancel Pending
          </button>
        )}
      </div>
    </div>
  )
}

// ── Main panel ───────────────────────────────────────────────────────────────

export function TradingPanel({ wallet, feed }: TradingPanelProps) {
  const contract = useAproxContract(wallet)
  const { address } = wallet
  const { price8 } = feed

  const [freeBalance, setFreeBalance] = useState<string>('0.00')
  const [walletBalance, setWalletBalance] = useState<string>('0.00')
  const [activeOrders, setActiveOrders] = useState<Array<{ id: bigint; order: Order }>>([])
  const [scanning, setScanning] = useState(false)
  const [depth, setDepth] = useState<MarketDepth>({ pendingLong: '0.00', pendingShort: '0.00' })
  // Track which address the most-recent scan was started for, so a stale
  // scan result from a previous wallet doesn't overwrite the current wallet's state.
  const scanAddressRef = useRef<string | null>(null)
  const hasOrdersRef = useRef(false)  // tracks whether orders exist without being a dep

  // Form state
  const [depositAmount, setDepositAmount] = useState('')
  const [withdrawAmount, setWithdrawAmount] = useState('')
  const [sendAmount, setSendAmount] = useState('')
  const [sendAddress, setSendAddress] = useState('')
  const [collateral, setCollateral] = useState('')
  const [leverage, setLeverage] = useState<2 | 5 | 10>(2)
  const [isLong, setIsLong] = useState(true)
  const [activeTab, setActiveTab] = useState<'deposit' | 'trade'>('deposit')

  // Tx state
  const [txState, setTxState] = useState<TxState>('idle')
  const [txLabel, setTxLabel] = useState('')
  const [txHash, setTxHash] = useState<string | null>(null)
  const [txError, setTxError] = useState<string | null>(null)

  // Keep a ref to the current leverage so refresh() doesn't need it as a dep.
  const leverageRef = useRef<2 | 5 | 10>(leverage)
  useEffect(() => { leverageRef.current = leverage }, [leverage])

  // ── Refresh ──────────────────────────────────────────────────────────────

  const refresh = useCallback(async () => {
    if (!address) return
    const thisAddress = address
    scanAddressRef.current = thisAddress
    const isFirstLoad = !hasOrdersRef.current

    // ── Balance (critical — must succeed independently) ───────────────────────
    try {
      const bal = await contract.getFreeBalance(address as `0x${string}`)
      if (scanAddressRef.current !== thisAddress) return
      setFreeBalance(bal)
    } catch (err) {
      console.error('[TradingPanel] getFreeBalance failed:', err instanceof Error ? err.message : err)
    }

    // ── Wallet USDC balance (held directly by smart account, before deposit) ──
    try {
      const wbal = await contract.getWalletUsdcBalance(address as `0x${string}`)
      if (scanAddressRef.current !== thisAddress) return
      setWalletBalance(wbal)
    } catch {
      // Non-critical
    }

    // ── Market depth (non-critical — failure is logged, not blocking) ─────────
    try {
      const d = await contract.getMarketDepth(leverageRef.current)
      if (scanAddressRef.current !== thisAddress) return
      setDepth(d)
    } catch {
      // Non-critical — keep whatever depth was previously displayed
    }

    // ── Active orders scan ────────────────────────────────────────────────────
    try {
      if (isFirstLoad) setScanning(true)
      const orders = await contract.getActiveOrders(address as `0x${string}`)
      if (scanAddressRef.current !== thisAddress) return
      hasOrdersRef.current = orders.length > 0
      setActiveOrders(orders)
    } catch (err) {
      console.error('[TradingPanel] getActiveOrders failed:', err instanceof Error ? err.message : err)
    } finally {
      if (scanAddressRef.current === address) setScanning(false)
    }
  }, [address, contract])

  // On wallet change: reset balance but keep showing previous orders until
  // the new scan arrives — no flash of empty content.
  useEffect(() => {
    setFreeBalance('0.00')
    setScanning(false)
    hasOrdersRef.current = false
  }, [address])

  useEffect(() => {
    if (!address) return
    void refresh()
    // Poll every 5s — tighter interval keeps both wallets in sync after a match
    const id = setInterval(() => void refresh(), 5000)
    return () => clearInterval(id)
  }, [address, refresh])

  // ── Tx helper ────────────────────────────────────────────────────────────

  // Poll getFreeBalance directly (bypassing React state) until it differs from
  // the pre-tx snapshot, or until maxAttempts is exhausted. This handles the
  // Arc Testnet RPC propagation lag where the receipt arrives before eth_call
  // sees the updated storage slot.
  const pollUntilBalanceChanges = useCallback(
    async (prevBalance: string, maxAttempts = 8, intervalMs = 1200) => {
      if (!address) return
      for (let i = 0; i < maxAttempts; i++) {
        await new Promise((r) => setTimeout(r, intervalMs))
        try {
          const fresh = await contract.getFreeBalance(address as `0x${string}`)
          if (fresh !== prevBalance) {
            setFreeBalance(fresh)
            // Do a full refresh now that balance has settled
            await refresh()
            return
          }
        } catch {
          // ignore transient RPC errors, keep retrying
        }
      }
      // Timed out — do one final full refresh anyway
      await refresh()
    },
    [address, contract, refresh],
  )

  const runTx = useCallback(
    async (label: string, fn: () => Promise<`0x${string}`>) => {
      setTxState('pending')
      setTxLabel(label)
      setTxHash(null)
      setTxError(null)
      try {
        const snapBalance = freeBalance
        const hash = await fn()
        setTxHash(hash)
        setTxState('confirmed')
        // Poll until the free balance reflects the new on-chain state, then
        // do a full refresh. This avoids the stale-read problem where the
        // receipt is available but the RPC node hasn't propagated the state yet.
        await pollUntilBalanceChanges(snapBalance)
      } catch (err) {
        const msg = err instanceof Error ? err.message : 'Transaction failed'
        setTxError(msg.length > 120 ? msg.slice(0, 120) + '…' : msg)
        setTxState('error')
      }
    },
    [refresh, freeBalance, pollUntilBalanceChanges],
  )

  const explorerBase = import.meta.env.VITE_NETWORK === 'mainnet'
    ? 'https://explorer.arc.io'
    : 'https://explorer.testnet.arc.io'

  if (!address) {
    return (
      <div className="flex items-center justify-center h-40 text-[var(--subtle)] text-sm">
        Register a passkey wallet to start trading
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-4">

      {/* Balance + depth */}
      <div className="flex gap-3">
        <div className="flex-1 p-3 rounded-xl bg-[var(--surface-muted)] border border-[var(--border)]">
          <p className="text-xs text-[var(--subtle)] mb-0.5">Free Balance</p>
          <p className="display text-xl font-semibold tabular-nums">${freeBalance}</p>
          <p className="text-xs text-[var(--subtle)] mt-1">Wallet: ${walletBalance}</p>
        </div>
        <div className="flex-1 p-3 rounded-xl bg-[var(--surface-muted)] border border-[var(--border)]">
          <p className="text-xs text-[var(--subtle)] mb-1">Market Depth ({leverage}x)</p>
          <p className="display text-sm tabular-nums">
            <span className="text-[var(--success)]">{depth.pendingLong} L</span>
            <span className="text-[var(--subtle)] mx-1">/</span>
            <span className="text-[var(--danger)]">{depth.pendingShort} S</span>
          </p>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex border border-[var(--border)] rounded-xl overflow-hidden">
        {(['deposit', 'trade'] as const).map((tab) => (
          <button
            key={tab}
            onClick={() => setActiveTab(tab)}
            className={`flex-1 py-2 text-sm font-medium transition-colors capitalize ${
              activeTab === tab
                ? 'bg-[var(--surface-strong)] text-[var(--ink)]'
                : 'text-[var(--subtle)] hover:text-[var(--ink-2)]'
            }`}
          >
            {tab === 'deposit' ? 'Funds' : `Trade${activeOrders.length > 0 ? ` (${activeOrders.length})` : ''}`}
          </button>
        ))}
      </div>

      {/* ── Funds tab ──────────────────────────────────────────────────────── */}
      {activeTab === 'deposit' && (
        <div className="flex flex-col gap-3">
          <div className="p-3 rounded-xl bg-[var(--surface)] border border-[var(--border)]">
            <p className="text-xs text-[var(--subtle)] mb-2">Deposit USDC</p>
            <div className="flex gap-2">
              <input
                type="number"
                min="0"
                step="0.01"
                placeholder="0.00"
                value={depositAmount}
                onChange={(e) => setDepositAmount(e.target.value)}
                className="flex-1 bg-[var(--surface-muted)] border border-[var(--border)] rounded-lg px-3 py-2 text-sm text-[var(--ink)] placeholder:text-[var(--subtle)] mono focus:outline-none focus:border-[var(--accent)]"
              />
              <button
                onClick={() => { void runTx('Deposit', () => contract.deposit(depositAmount)) }}
                disabled={txState === 'pending' || !depositAmount || parseFloat(depositAmount) <= 0}
                className="px-4 py-2 rounded-lg bg-[var(--accent)] text-white text-sm font-medium disabled:opacity-40 hover:bg-[var(--accent-hover)] transition-colors"
              >
                Deposit
              </button>
            </div>
          </div>

          <div className="p-3 rounded-xl bg-[var(--surface)] border border-[var(--border)]">
            <p className="text-xs text-[var(--subtle)] mb-2">Withdraw to wallet</p>
            <p className="text-xs text-[var(--subtle)] mb-2 leading-relaxed">Moves USDC from your Free Balance back to your smart account wallet.</p>
            <div className="flex gap-2">
              <input
                type="number"
                min="0"
                step="0.01"
                placeholder="0.00"
                value={withdrawAmount}
                onChange={(e) => setWithdrawAmount(e.target.value)}
                className="flex-1 bg-[var(--surface-muted)] border border-[var(--border)] rounded-lg px-3 py-2 text-sm text-[var(--ink)] placeholder:text-[var(--subtle)] mono focus:outline-none focus:border-[var(--accent)]"
              />
              <button
                onClick={() => { void runTx('Withdraw', () => contract.withdraw(withdrawAmount)) }}
                disabled={txState === 'pending' || !withdrawAmount || parseFloat(withdrawAmount) <= 0}
                className="px-4 py-2 rounded-lg bg-[var(--surface-strong)] border border-[var(--border)] text-[var(--ink-2)] text-sm font-medium disabled:opacity-40 hover:border-[var(--accent)] transition-colors"
              >
                Withdraw
              </button>
            </div>
          </div>

          <div className="p-3 rounded-xl bg-[var(--surface)] border border-[var(--border)]">
            <p className="text-xs text-[var(--subtle)] mb-2">Send to external wallet</p>
            <p className="text-xs text-[var(--subtle)] mb-2 leading-relaxed">Send USDC from your smart account directly to MetaMask or any other address.</p>
            <input
              type="text"
              placeholder="Destination address (0x...)"
              value={sendAddress}
              onChange={(e) => setSendAddress(e.target.value)}
              className="w-full bg-[var(--surface-muted)] border border-[var(--border)] rounded-lg px-3 py-2 text-sm text-[var(--ink)] placeholder:text-[var(--subtle)] mono focus:outline-none focus:border-[var(--accent)] mb-2"
            />
            <div className="flex gap-2">
              <input
                type="number"
                min="0"
                step="0.01"
                placeholder="0.00"
                value={sendAmount}
                onChange={(e) => setSendAmount(e.target.value)}
                className="flex-1 bg-[var(--surface-muted)] border border-[var(--border)] rounded-lg px-3 py-2 text-sm text-[var(--ink)] placeholder:text-[var(--subtle)] mono focus:outline-none focus:border-[var(--accent)]"
              />
              <button
                onClick={() => {
                  if (!sendAddress.startsWith('0x') || sendAddress.length !== 42) return
                  void runTx('Send', () => contract.sendToAddress(sendAddress as `0x${string}`, sendAmount))
                }}
                disabled={
                  txState === 'pending' ||
                  !sendAmount || parseFloat(sendAmount) <= 0 ||
                  !sendAddress.startsWith('0x') || sendAddress.length !== 42
                }
                className="px-4 py-2 rounded-lg bg-[var(--surface-strong)] border border-[var(--border)] text-[var(--ink-2)] text-sm font-medium disabled:opacity-40 hover:border-[var(--accent)] transition-colors"
              >
                Send
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Trade tab ──────────────────────────────────────────────────────── */}
      {activeTab === 'trade' && (
        <div className="flex flex-col gap-3">

          {/* Scanning indicator — shown only on first load, not on background polls */}
          {scanning && activeOrders.length === 0 && (
            <div className="flex items-center gap-2 px-3 py-3 rounded-xl bg-[var(--surface-muted)] border border-[var(--border)] text-sm text-[var(--subtle)]">
              <Loader2 size={13} className="animate-spin shrink-0" />
              Scanning orders…
            </div>
          )}

          {/* Active / pending order cards — ALL of them */}
          {activeOrders.map(({ id, order }) => (
            <OrderCard
              key={id.toString()}
              id={id}
              order={order}
              price8={price8}
              onClose={(oid) => void runTx(`Close #${oid}`, () => contract.closeOrder(oid))}
              onCancel={(oid) => void runTx(`Cancel #${oid}`, () => contract.cancelOrder(oid))}
              txPending={txState === 'pending'}
            />
          ))}

          {/* Divider when there are existing orders */}
          {activeOrders.length > 0 && (
            <div className="flex items-center gap-2">
              <div className="flex-1 h-px bg-[var(--border)]" />
              <span className="text-xs text-[var(--subtle)]">Open another position</span>
              <div className="flex-1 h-px bg-[var(--border)]" />
            </div>
          )}

          {/* Open order form — always visible */}
          <div className="flex flex-col gap-3">
            {/* Direction */}
            <div className="flex gap-2">
              <button
                onClick={() => setIsLong(true)}
                className={`flex-1 flex items-center justify-center gap-2 py-2.5 rounded-xl border text-sm font-medium transition-colors ${
                  isLong
                    ? 'border-[var(--success)] bg-[var(--success)]/10 text-[var(--success)]'
                    : 'border-[var(--border)] text-[var(--subtle)] hover:border-[var(--success)]/50'
                }`}
              >
                <TrendingUp size={14} /> Long
              </button>
              <button
                onClick={() => setIsLong(false)}
                className={`flex-1 flex items-center justify-center gap-2 py-2.5 rounded-xl border text-sm font-medium transition-colors ${
                  !isLong
                    ? 'border-[var(--danger)] bg-[var(--danger)]/10 text-[var(--danger)]'
                    : 'border-[var(--border)] text-[var(--subtle)] hover:border-[var(--danger)]/50'
                }`}
              >
                <TrendingDown size={14} /> Short
              </button>
            </div>

            {/* Leverage */}
            <div>
              <p className="text-xs text-[var(--subtle)] mb-2">Leverage</p>
              <div className="flex gap-2">
                {LEVERAGES.map((lev) => (
                  <button
                    key={lev}
                    onClick={() => setLeverage(lev)}
                    className={`flex-1 py-2 rounded-lg border text-sm font-medium mono transition-colors ${
                      leverage === lev
                        ? 'border-[var(--accent)] bg-[var(--accent)]/10 text-[var(--accent)]'
                        : 'border-[var(--border)] text-[var(--subtle)] hover:border-[var(--accent)]/50'
                    }`}
                  >
                    {lev}x
                  </button>
                ))}
              </div>
            </div>

            {/* Collateral */}
            <div>
              <div className="flex justify-between items-center mb-2">
                <p className="text-xs text-[var(--subtle)]">Collateral (USDC)</p>
                <button
                  onClick={() => setCollateral(freeBalance)}
                  className="text-xs text-[var(--accent)] hover:underline"
                >
                  Max ${freeBalance}
                </button>
              </div>
              <input
                type="number"
                min="0"
                step="0.01"
                placeholder="0.00"
                value={collateral}
                onChange={(e) => setCollateral(e.target.value)}
                className="w-full bg-[var(--surface-muted)] border border-[var(--border)] rounded-lg px-3 py-2 text-sm text-[var(--ink)] placeholder:text-[var(--subtle)] mono focus:outline-none focus:border-[var(--accent)]"
              />
              {collateral && parseFloat(collateral) > 0 && (
                <p className="text-xs text-[var(--subtle)] mt-1">
                  Notional: {formatUSD(parseFloat(collateral) * leverage)} ·{' '}
                  <span className="text-yellow-400">
                    Will match against up to {formatUSD(parseFloat(collateral))} of {isLong ? 'Short' : 'Long'} orders
                  </span>
                </p>
              )}
            </div>

            {/* Market depth hint */}
            <div className="p-2 rounded-lg bg-[var(--surface-muted)] border border-[var(--border)] text-xs text-[var(--subtle)]">
              <span className="text-[var(--success)]">{depth.pendingLong} USDC Long</span>
              {' '}pending ·{' '}
              <span className="text-[var(--danger)]">{depth.pendingShort} USDC Short</span>
              {' '}pending at {leverage}x —{' '}
              {isLong
                ? parseFloat(depth.pendingShort) >= parseFloat(collateral || '0')
                  ? 'fills immediately'
                  : 'partially fills, remainder stays pending'
                : parseFloat(depth.pendingLong) >= parseFloat(collateral || '0')
                  ? 'fills immediately'
                  : 'partially fills, remainder stays pending'}
            </div>

            <button
              onClick={() => { void runTx(
                `Open ${isLong ? 'Long' : 'Short'} ${leverage}x`,
                () => contract.openOrder(isLong, leverage, collateral),
              ) }}
              disabled={
                txState === 'pending' ||
                !collateral ||
                parseFloat(collateral) <= 0 ||
                parseFloat(collateral) > parseFloat(freeBalance)
              }
              className={`w-full py-3 rounded-xl text-sm font-semibold transition-colors disabled:opacity-40 ${
                isLong
                  ? 'bg-[var(--success)] hover:bg-[var(--success)]/90 text-white'
                  : 'bg-[var(--danger)] hover:bg-[var(--danger)]/90 text-white'
              }`}
            >
              {txState === 'pending' && txLabel.startsWith('Open')
                ? 'Submitting…'
                : `Open ${isLong ? 'Long' : 'Short'} ${leverage}x`}
            </button>
          </div>
        </div>
      )}

      {/* ── Tx status ──────────────────────────────────────────────────────── */}
      {txState === 'pending' && (
        <div className="flex items-center gap-2 px-3 py-2 rounded-lg bg-[var(--surface-muted)] border border-[var(--border)] text-sm text-[var(--muted)]">
          <Loader2 size={14} className="animate-spin" />
          {txLabel}… (gasless)
        </div>
      )}
      {txState === 'confirmed' && txHash && (
        <div className="flex items-center gap-2 px-3 py-2 rounded-lg bg-[var(--success)]/10 border border-[var(--success)]/30 text-sm text-[var(--success)]">
          <CheckCircle2 size={14} />
          {txLabel} confirmed ·{' '}
          <a
            href={`${explorerBase}/tx/${txHash}`}
            target="_blank"
            rel="noopener noreferrer"
            className="underline truncate max-w-[160px]"
          >
            {txHash.slice(0, 10)}…
          </a>
        </div>
      )}
      {txState === 'error' && txError && (
        <div className="flex items-start gap-2 px-3 py-2 rounded-lg bg-[var(--danger)]/10 border border-[var(--danger)]/30 text-sm text-[var(--danger)]">
          <AlertTriangle size={14} className="mt-0.5 shrink-0" />
          {txError}
        </div>
      )}
    </div>
  )
}
