# Circle Modular Wallets — Debug & Setup Skill

Covers every failure mode encountered running `@circle-fin/modular-wallets-core`
with ERC-4337 passkey wallets and Circle Gas Station on Arc Testnet.

---

## Quick symptom → cause table

| Symptom | Cause |
|---|---|
| `Invalid credentials` on register/login | Client Key domain not set in Circle Console |
| `Invalid credentials` on deposit/sendUserOperation | Passkey domain not set in Circle Console (different field) |
| `Failed to fetch` on any Circle SDK call | CORS: browser origin not in Circle's allowlist |
| `429 Too Many Requests` on `rpc.testnet.arc.io` | Polling storm from unstable React hook refs |
| `Access-Control-Allow-Origin` missing | Same as "Failed to fetch" — domain not whitelisted |
| New key still returns 401 | Passkey domain field not saved (separate from key domain) |

---

## Circle Console setup (must do every new session/domain)

Circle's backend enforces the **exact origin hostname** on every request.
Arc Studio assigns a new hostname to each sandbox session, so you must update
Circle Console whenever the preview URL changes.

### 1. Client Key domain

`console.circle.com` → Testnet → **Keys → Client Keys**

- Edit your key (or create a new one)
- **Allowed Domain**: paste the exact preview hostname, e.g.
  `imxes4sbqy93gek2bzcyt.preview.studio.arc.io`
- No `https://`, no trailing slash, hostname only

### 2. Passkey domain (separate field — controls bundler access too)

`console.circle.com` → Testnet → **Wallets → Modular Wallets → Configurator → Passkey**

- **Passkey Domain Name**: same hostname as above
- Hit Save and wait ~10 seconds before testing

> Both fields must match the current preview hostname. Setting only the Client
> Key domain allows passkey register/login but blocks all bundler calls
> (`sendUserOperation`, `eth_estimateUserOperationGas`, `pm_getPaymasterData`).
> Setting only the Passkey domain blocks register/login. Both are required.

### 3. Gas Station policy

For Arc Testnet a preconfigured policy is already active — you do not need to
create one. For mainnet you must create a policy under
**Wallets → Gas Station**.

---

## Code fixes

### Fix 1 — `publicClient` must use plain RPC, not modular transport

The module-level `publicClient` used for contract reads (balance, order state)
must use a plain `http()` transport. Using `toModularTransport` here causes:
- CORS errors on every page load (browser → `modular-sdk.circle.com` for reads)
- Rate-limit exhaustion on Circle's bundler endpoint

```ts
// WRONG — causes CORS noise and wastes bundler quota on reads
export const publicClient = createPublicClient({
  chain: arcTestnet,
  transport: toModularTransport(`${CLIENT_URL}/arcTestnet`, CLIENT_KEY),
})

// CORRECT — reads go to the plain RPC; only sendUserOperation uses the bundler
export const publicClient = createPublicClient({
  chain: arcTestnet,
  transport: http('https://rpc.testnet.arc.io'),
})
```

Only the **bundler client** (for `sendUserOperation`) needs `toModularTransport`:

```ts
const bundlerClient = createBundlerClient({
  account: smartAccount,
  chain: arcTestnet,
  transport: toModularTransport(`${CLIENT_URL}/arcTestnet`, CLIENT_KEY),
})
```

### Fix 2 — Stable hook return to prevent RPC polling storms

If a hook like `useAproxContract(wallet)` returns a plain object literal, its
reference changes on every render. Any `useCallback` or `useEffect` that lists
it as a dependency re-fires on every render, creating a tight polling loop that
hits 429 rate limits on `rpc.testnet.arc.io` within seconds.

```ts
// WRONG — new object reference on every render → polling storm
return {
  deposit, withdraw, openOrder, getFreeBalance, ...
}

// CORRECT — stable reference, deps only change when functions change
return useMemo(() => ({
  deposit, withdraw, openOrder, getFreeBalance, ...
}), [deposit, withdraw, openOrder, getFreeBalance, ...])
```

### Fix 3 — `VITE_CLIENT_URL` must be the full Circle URL

```env
# CORRECT
VITE_CLIENT_URL=https://modular-sdk.circle.com/v1/rpc/w3s/buidl

# WRONG — relative paths fail SDK URL validation
VITE_CLIENT_URL=/circle-rpc
```

The SDK's `validateClientUrl` requires a full `http://` or `https://` URL.
Relative paths throw `InvalidProviderError` before any network call.

---

## Transport URL reference

| Transport | URL pattern | Used for |
|---|---|---|
| `toPasskeyTransport` | `${CLIENT_URL}` (base, no chain suffix) | register, login |
| `toModularTransport` | `${CLIENT_URL}/arcTestnet` | sendUserOperation, gas estimation |

Both transports POST to the same base host (`modular-sdk.circle.com`) but
different paths. Both require the **same** client key and both are gated by the
**same** Circle Console domain checks.

---

## Debugging checklist

When Circle SDK calls fail:

1. Open browser DevTools → Network tab → filter by `modular-sdk`
   - `401` or `Invalid credentials` → Circle Console domain not set
   - `CORS / no Access-Control-Allow-Origin` → same cause
   - `Failed to fetch` → CORS preflight blocked

2. Test the key directly from the sandbox terminal:
   ```bash
   curl -s https://modular-sdk.circle.com/v1/rpc/w3s/buidl \
     -X POST -H "Content-Type: application/json" \
     -H "Authorization: Bearer $VITE_CLIENT_KEY" \
     -d '{"jsonrpc":"2.0","method":"rp_getRegistrationOptions","params":["test"],"id":1}'
   ```
   - `Invalid credentials` → key is wrong or Passkey domain not saved
   - Any JSON with `result` → key works, problem is elsewhere (CORS, wrong URL)

3. Check `traces.jsonl` for `rpc` kind events — method names reveal which
   layer is failing (`rp_getRegistrationOptions` = passkey layer,
   `eth_sendUserOperation` = bundler layer).

4. Check `console.jsonl` for the actual error text — viem wraps all errors as
   `UnknownRpcError`; the real message is in `Details:`.

---

## Arc Studio session hostname

Every Arc Studio sandbox session gets a unique hostname:
`<random>.preview.studio.arc.io`

This breaks WebAuthn (passkeys are origin-bound) and Circle's domain allowlist
every time the session changes. The only permanent fix is deploying to a stable
custom domain and setting that as the Allowed Domain in Circle Console.

During development: update both Circle Console fields at the start of each
new Arc Studio session.
