/**
 * Aprox — Peer-to-Peer BTC/USD Perpetuals on Arc
 * Gasless trading via Circle Modular Wallets (ERC-4337 passkeys + Gas Station)
 */

import { useState } from 'react'
import { useModularWallet } from '@/hooks/useModularWallet'
import { usePriceFeed } from '@/hooks/usePriceFeed'
import { WalletGate } from '@/components/WalletGate'
import { PriceBar } from '@/components/PriceBar'
import { TradingPanel } from '@/components/TradingPanel'
import { ChevronDown, ChevronUp, AlertTriangle, KeyRound, Coins, TrendingUp, LogIn } from 'lucide-react'

// ── How to Use panel ─────────────────────────────────────────────────────────

const STEPS = [
  {
    icon: AlertTriangle,
    color: 'text-yellow-400',
    title: 'Use Chrome, Firefox, or Safari',
    body: 'Brave and browsers with aggressive ad-blockers block the Circle wallet SDK. If the app feels unresponsive or the balance never loads, open it in a clean Chrome/Firefox window or in incognito mode (which disables most extensions).',
  },
  {
    icon: KeyRound,
    color: 'text-[var(--accent)]',
    title: 'Register a passkey wallet',
    body: 'Click "Register" in the top-right, enter any username, and approve the biometric prompt (Face ID, fingerprint, or security key). This creates a gasless ERC-4337 smart account — no seed phrase, no gas fees.',
  },
  {
    icon: Coins,
    color: 'text-[var(--success)]',
    title: 'Deposit USDC',
    body: 'Go to the Funds tab, enter an amount, and click Deposit. The transaction is gasless — Circle Gas Station pays the fee. Your Free Balance updates within a few seconds once the block is confirmed.',
  },
  {
    icon: TrendingUp,
    color: 'text-[var(--accent)]',
    title: 'Open a position',
    body: 'Switch to the Trade tab. Pick Long or Short, choose 2x / 5x / 10x leverage, enter collateral, and submit. Your order goes into a peer-to-peer queue and matches against the opposite side automatically.',
  },
  {
    icon: LogIn,
    color: 'text-[var(--subtle)]',
    title: 'Returning? Log in',
    body: 'Click "Login" and approve the biometric prompt. Your passkey is bound to this domain — if the URL changes your passkey won\'t work, so bookmark the exact address.',
  },
]

function HowToUse() {
  const [open, setOpen] = useState(false)
  return (
    <div className="mx-4 mt-3 rounded-xl border border-[var(--border)] overflow-hidden" style={{ background: 'var(--surface)' }}>
      <button
        onClick={() => setOpen((o) => !o)}
        className="w-full flex items-center justify-between px-4 py-3 text-sm font-medium text-[var(--ink-2)] hover:text-[var(--ink)] transition-colors"
      >
        <span className="display font-semibold">How to use Aprox</span>
        {open ? <ChevronUp size={15} className="text-[var(--subtle)]" /> : <ChevronDown size={15} className="text-[var(--subtle)]" />}
      </button>

      {open && (
        <div className="px-4 pb-4 flex flex-col gap-3 border-t border-[var(--border)]">
          <p className="text-xs text-[var(--subtle)] pt-3">
            Aprox runs on Arc Testnet — all funds are test USDC, nothing is real money.
          </p>
          {STEPS.map(({ icon: Icon, color, title, body }) => (
            <div key={title} className="flex gap-3">
              <div className={`mt-0.5 shrink-0 ${color}`}>
                <Icon size={15} />
              </div>
              <div>
                <p className="text-sm font-semibold text-[var(--ink)] mb-0.5">{title}</p>
                <p className="text-xs text-[var(--subtle)] leading-relaxed">{body}</p>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

// ── App ───────────────────────────────────────────────────────────────────────

export default function App() {
  const wallet = useModularWallet()
  const feed = usePriceFeed()

  return (
    <div
      className="min-h-screen w-full"
      style={{ background: 'var(--bg-gradient)' }}
    >
      {/* Header */}
      <header
        className="sticky top-0 z-20 px-4 py-3 border-b border-[var(--border)] flex items-center justify-between"
        style={{ background: 'rgba(13, 27, 47, 0.92)', backdropFilter: 'blur(12px)' }}
      >
        <div className="flex items-center gap-3">
          <span className="display text-lg font-bold text-[var(--ink)]">Aprox</span>
          <span className={`text-xs px-2 py-0.5 rounded-full border ${
            import.meta.env.VITE_NETWORK === 'mainnet'
              ? 'border-[var(--success)]/40 text-[var(--success)]'
              : 'border-[var(--accent)]/30 text-[var(--accent)]'
          }`}>
            {import.meta.env.VITE_NETWORK === 'mainnet' ? 'Arc Mainnet' : 'Arc Testnet'}
          </span>
        </div>
        <WalletGate wallet={wallet} />
      </header>

      {/* Price bar */}
      <div
        className="mx-4 mt-4 px-4 py-3 rounded-xl border border-[var(--border)]"
        style={{ background: 'var(--surface)' }}
      >
        <PriceBar feed={feed} />
      </div>

      {/* How to use */}
      <HowToUse />

      {/* Trading panel — full width */}
      <main className="p-4 max-w-2xl mx-auto">
        <div
          className="rounded-xl border border-[var(--border)] p-4"
          style={{ background: 'var(--surface)' }}
        >
          <h2 className="display text-base font-semibold text-[var(--ink-2)] mb-4">
            BTC/USD Perpetuals
          </h2>
          <TradingPanel wallet={wallet} feed={feed} />
        </div>
      </main>

      {/* Footer */}
      <footer className="px-4 py-6 text-center text-xs text-[var(--subtle)]">
        Aprox · P2P Perpetuals · {import.meta.env.VITE_NETWORK === 'mainnet' ? 'Arc Mainnet' : 'Arc Testnet'} · Circle Modular Wallets
      </footer>
    </div>
  )
}
