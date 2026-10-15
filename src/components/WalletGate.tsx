/**
 * WalletGate — Passkey register / login
 *
 * Connected state shows a compact card:
 *   ● username          [copy] [logout]
 *   0xAB12…ef34
 *   Circle MSCA · Arc Testnet · Gasless
 *
 * Auth state shows both Register (new) and Login (returning) side by side.
 */

import { useState } from 'react'
import { Fingerprint, LogOut, CheckCircle2, Loader2, Copy, Check, Shield, Zap } from 'lucide-react'
import type { UseModularWalletReturn } from '@/hooks/useModularWallet'

interface WalletGateProps {
  wallet: UseModularWalletReturn
}

const USERNAME_RE = /^[a-zA-Z0-9_@.:+-]{5,50}$/

function validateUsername(u: string): string | null {
  if (!u) return null
  if (u.length < 5) return 'At least 5 characters'
  if (u.length > 50) return 'Max 50 characters'
  if (!USERNAME_RE.test(u)) return 'Only letters, numbers and _@.:+-'
  return null
}

export function WalletGate({ wallet }: WalletGateProps) {
  const { address, username, status, error, register, login, logout } = wallet
  const [inputUsername, setInputUsername] = useState('')
  const [validationError, setValidationError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [showFull, setShowFull] = useState(false)

  const isLoading = status === 'registering' || status === 'logging-in'

  const handleRegister = () => {
    const err = validateUsername(inputUsername)
    if (err) { setValidationError(err); return }
    if (inputUsername.length < 5) { setValidationError('At least 5 characters'); return }
    setValidationError(null)
    void register(inputUsername)
  }

  const handleLogin = () => {
    setValidationError(null)
    void login()
  }

  const handleCopy = () => {
    if (!address) return
    void navigator.clipboard.writeText(address)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  // ── Connected state ──────────────────────────────────────────────────────────
  if (address) {
    const shortAddr = `${address.slice(0, 6)}…${address.slice(-4)}`

    return (
      <div className="flex items-center gap-2">
        {/* Wallet info card */}
        <div
          className="flex items-center gap-2.5 px-3 py-2 rounded-xl border border-[var(--border)] bg-[var(--surface-strong)]"
        >
          {/* Status dot */}
          <CheckCircle2 size={13} className="text-[var(--success)] shrink-0" />

          <div className="flex flex-col min-w-0">
            {/* Username */}
            {username && (
              <span className="text-xs font-semibold text-[var(--ink)] leading-tight truncate max-w-[140px]">
                {username}
              </span>
            )}

            {/* Address — click to toggle full */}
            <button
              onClick={() => setShowFull(f => !f)}
              className="text-left text-[10px] font-medium text-[var(--subtle)] hover:text-[var(--ink-2)] transition-colors tabular-nums mono leading-tight"
              title="Click to toggle full address"
            >
              {showFull ? address : shortAddr}
            </button>

            {/* Wallet metadata */}
            <div className="flex items-center gap-2 mt-0.5">
              <span className="flex items-center gap-0.5 text-[9px] text-[var(--subtle)]">
                <Shield size={8} className="shrink-0" />
                Circle MSCA
              </span>
              <span className="text-[9px] text-[var(--subtle)]">·</span>
              <span className="flex items-center gap-0.5 text-[9px] text-[var(--accent)]">
                <Zap size={8} className="shrink-0" />
                Gasless
              </span>
              <span className="text-[9px] text-[var(--subtle)]">·</span>
              <span className="text-[9px] text-[var(--subtle)]">ERC-4337</span>
            </div>
          </div>
        </div>

        {/* Copy */}
        <button
          onClick={handleCopy}
          className="p-1.5 rounded-xl bg-[var(--surface)] border border-[var(--border)] hover:bg-[var(--surface-strong)] transition-colors text-[var(--subtle)] hover:text-[var(--ink-2)]"
          title="Copy full address"
        >
          {copied ? <Check size={13} className="text-[var(--success)]" /> : <Copy size={13} />}
        </button>

        {/* Logout */}
        <button
          onClick={logout}
          className="p-1.5 rounded-xl bg-[var(--surface)] border border-[var(--border)] hover:bg-[var(--surface-strong)] transition-colors text-[var(--subtle)] hover:text-[var(--ink-2)]"
          title="Logout"
        >
          <LogOut size={13} />
        </button>
      </div>
    )
  }

  // ── Auth state ───────────────────────────────────────────────────────────────
  return (
    <div className="flex flex-col items-end gap-2">
      <div className="flex items-center gap-2">
        {/* Username input for new users */}
        <input
          type="text"
          placeholder="username (new)"
          value={inputUsername}
          onChange={e => { setInputUsername(e.target.value); setValidationError(null) }}
          onKeyDown={e => { if (e.key === 'Enter') handleRegister() }}
          className={`px-3 py-1.5 rounded-xl bg-[var(--surface-muted)] border text-sm text-[var(--ink)] placeholder:text-[var(--subtle)] outline-none transition-colors w-36 ${validationError ? 'border-[var(--danger)]' : 'border-[var(--border)] focus:border-[var(--accent)]'}`}
          disabled={isLoading}
        />

        {/* Register */}
        <button
          onClick={handleRegister}
          disabled={isLoading}
          className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-[var(--accent)] text-[#0d1b2f] text-sm font-semibold hover:bg-[var(--accent-hover)] transition-colors disabled:opacity-50 disabled:cursor-not-allowed whitespace-nowrap"
          title="Create a new passkey wallet"
        >
          {isLoading && status === 'registering'
            ? <Loader2 size={13} className="animate-spin" />
            : <Fingerprint size={13} />}
          Register
        </button>

        <span className="text-[var(--subtle)] text-xs">or</span>

        {/* Login */}
        <button
          onClick={handleLogin}
          disabled={isLoading}
          className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-[var(--surface-strong)] border border-[var(--border)] text-[var(--ink-2)] text-sm font-medium hover:border-[var(--accent)] transition-colors disabled:opacity-50 disabled:cursor-not-allowed whitespace-nowrap"
          title="Sign in with your saved passkey (iCloud / Google / Windows)"
        >
          {isLoading && status === 'logging-in'
            ? <Loader2 size={13} className="animate-spin" />
            : <Fingerprint size={13} />}
          Login
        </button>
      </div>

      {validationError && (
        <p className="text-xs text-[var(--danger)]">{validationError}</p>
      )}
      {!validationError && error && (
        <p className="text-xs text-[var(--danger)] max-w-xs text-right">{error}</p>
      )}
    </div>
  )
}
