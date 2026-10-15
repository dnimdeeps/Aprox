/**
 * useModularWallet — Circle Modular Wallets (ERC-4337) hook
 *
 * Wraps passkey register/login and gasless sendUserOperation.
 * Gas Station paymaster sponsors all gas — user never pays gas.
 */

import { useState, useCallback, useRef } from 'react'
import { arc, arcTestnet } from 'viem/chains'
import { createPublicClient, http } from 'viem'
import { createBundlerClient } from 'viem/account-abstraction'
import {
  WebAuthnMode,
  OwnerIdentifierType,
  toCircleSmartAccount,
  toModularTransport,
  toPasskeyTransport,
  toWebAuthnCredential,
  modularWalletActions,
  type WebAuthnCredential,
} from '@circle-fin/modular-wallets-core'
import { parsePublicKey } from 'webauthn-p256'
import { toWebAuthnAccount } from 'viem/account-abstraction'
import type { SmartAccount } from 'viem/account-abstraction'

const CLIENT_KEY = import.meta.env.VITE_CLIENT_KEY as string | undefined
const CLIENT_URL = import.meta.env.VITE_CLIENT_URL as string | undefined

// VITE_NETWORK=mainnet switches to Arc Mainnet; anything else (or unset) uses testnet.
const IS_MAINNET = import.meta.env.VITE_NETWORK === 'mainnet'
export const ACTIVE_CHAIN = IS_MAINNET ? arc : arcTestnet
const CHAIN_SLUG = IS_MAINNET ? 'arc' : 'arcTestnet'
const RPC_URL = IS_MAINNET ? 'https://rpc.mainnet.arc.io' : 'https://rpc.testnet.arc.io'

const CREDENTIAL_STORAGE_KEY = 'aprox_passkey_credential'
const USERNAME_STORAGE_KEY = 'aprox_passkey_username'

// Public client for contract reads (balance, order state).
export const publicClient = createPublicClient({
  chain: ACTIVE_CHAIN,
  transport: http(RPC_URL),
})

export type WalletStatus = 'idle' | 'registering' | 'logging-in' | 'ready' | 'error'

export interface UseModularWalletReturn {
  account: SmartAccount | null
  address: string | null
  username: string | null
  status: WalletStatus
  error: string | null
  register: (username: string) => Promise<void>
  login: () => Promise<void>
  logout: () => void
  sendOp: (calls: Array<{ to: `0x${string}`; data: `0x${string}`; value?: bigint }>) => Promise<`0x${string}`>
}

export function useModularWallet(): UseModularWalletReturn {
  const [account, setAccount] = useState<SmartAccount | null>(null)
  const [address, setAddress] = useState<string | null>(null)
  const [username, setUsername] = useState<string | null>(null)
  const [status, setStatus] = useState<WalletStatus>('idle')
  const [error, setError] = useState<string | null>(null)
  // Store the bundler client alongside the account — it is account-specific
  const bundlerClientRef = useRef<ReturnType<typeof createBundlerClient> | null>(null)

  const buildAccount = useCallback(async (credential: WebAuthnCredential) => {
    if (!CLIENT_KEY || !CLIENT_URL) throw new Error('VITE_CLIENT_KEY or VITE_CLIENT_URL is missing')

    const modularTransport = toModularTransport(`${CLIENT_URL}/${CHAIN_SLUG}`, CLIENT_KEY)

    // toCircleSmartAccount MUST use a client with modularTransport — it calls
    // circle_getUserOperationGasPrice internally for gas estimation. Using the
    // plain http publicClient causes that call to fail ("method not supported"),
    // which breaks eth_estimateUserOperationGas for every new wallet.
    const modularPublicClient = createPublicClient({
      chain: ACTIVE_CHAIN,
      transport: modularTransport,
    })

    const owner = toWebAuthnAccount({ credential })
    const smartAccount = await toCircleSmartAccount({
      client: modularPublicClient,
      owner,
    })

    const bundlerClient = createBundlerClient({
      account: smartAccount,
      chain: ACTIVE_CHAIN,
      transport: modularTransport,
    })

    bundlerClientRef.current = bundlerClient
    setAccount(smartAccount)
    setAddress(smartAccount.address)
    return { smartAccount, bundlerClient }
  }, [])

  const register = useCallback(
    async (username: string) => {
      setStatus('registering')
      setError(null)
      try {
        if (!CLIENT_KEY || !CLIENT_URL) throw new Error('VITE_CLIENT_KEY is missing — check .env')
        const passkeyTransport = toPasskeyTransport(CLIENT_URL, CLIENT_KEY)
        const credential: WebAuthnCredential = await toWebAuthnCredential({
          transport: passkeyTransport,
          mode: WebAuthnMode.Register,
          username,
        })
        sessionStorage.setItem(CREDENTIAL_STORAGE_KEY, JSON.stringify(credential))
        sessionStorage.setItem(USERNAME_STORAGE_KEY, username)
        setUsername(username)
        const { smartAccount, bundlerClient } = await buildAccount(credential)

        // Register the smart account address with Circle's backend so the
        // bundler can process user operations for it. Without this, subsequent
        // sendUserOperation calls fail with "Cannot find target wallet in the
        // system" for any account that hasn't previously been used.
        try {
          const pubKey = parsePublicKey(credential.publicKey as `0x${string}`)
          const modularClient = bundlerClient.extend(modularWalletActions)
          await modularClient.createAddressMapping({
            walletAddress: smartAccount.address,
            owners: [{
              type: OwnerIdentifierType.WebAuthn,
              identifier: {
                publicKeyX: pubKey.x.toString(),
                publicKeyY: pubKey.y.toString(),
              },
            }],
          })
        } catch (mappingErr) {
          // If the mapping already exists Circle returns an error — safe to ignore.
          const msg = mappingErr instanceof Error ? mappingErr.message : ''
          if (!msg.includes('already') && !msg.includes('exists') && !msg.includes('duplicate')) {
            console.warn('[useModularWallet] createAddressMapping failed (non-fatal):', msg)
          }
        }

        setStatus('ready')
      } catch (err) {
        const msg = err instanceof Error ? err.message : 'Registration failed'
        setError(msg)
        setStatus('error')
        throw err
      }
    },
    [buildAccount],
  )

  const login = useCallback(async () => {
    setStatus('logging-in')
    setError(null)
    try {
      if (!CLIENT_KEY || !CLIENT_URL) throw new Error('VITE_CLIENT_KEY is missing — check .env')

      // Always prompt the biometric — never restore from sessionStorage.
      // Restoring would reuse the previous wallet's credential in the same tab,
      // making every login resolve to wallet 1's address regardless of who is
      // actually authenticating. Each login must produce a fresh credential.
      const passkeyTransport = toPasskeyTransport(CLIENT_URL, CLIENT_KEY)
      const credential = await toWebAuthnCredential({
        transport: passkeyTransport,
        mode: WebAuthnMode.Login,
      })

      // Overwrite any previously stored credential and username
      sessionStorage.setItem(CREDENTIAL_STORAGE_KEY, JSON.stringify(credential))

      await buildAccount(credential)
      setStatus('ready')
    } catch (err: unknown) {
      sessionStorage.removeItem(CREDENTIAL_STORAGE_KEY)
      const msg = err instanceof Error ? err.message : 'Login failed'
      setError(msg)
      setStatus('error')
      throw err
    }
  }, [buildAccount])

  const logout = useCallback(() => {
    sessionStorage.removeItem(CREDENTIAL_STORAGE_KEY)
    sessionStorage.removeItem(USERNAME_STORAGE_KEY)
    bundlerClientRef.current = null
    setAccount(null)
    setAddress(null)
    setUsername(null)
    setStatus('idle')
    setError(null)
  }, [])

  const sendOp = useCallback(
    async (calls: Array<{ to: `0x${string}`; data: `0x${string}`; value?: bigint }>): Promise<`0x${string}`> => {
      const bundlerClient = bundlerClientRef.current
      if (!bundlerClient) throw new Error('Wallet not connected — register or login first')

      const userOpHash = await bundlerClient.sendUserOperation({
        calls,
        paymaster: true,
      })

      const { receipt } = await bundlerClient.waitForUserOperationReceipt({ hash: userOpHash })
      return receipt.transactionHash
    },
    [],
  )

  return { account, address, username, status, error, register, login, logout, sendOp }
}
