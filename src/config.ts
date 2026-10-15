/**
 * Chain registration for tracing — Arc Mainnet.
 * No wagmi config needed: all wallet ops go through Circle Modular Wallets (ERC-4337).
 */

import { arc } from 'viem/chains'
import { registerChain } from './tracing'

registerChain(arc.id, arc.rpcUrls.default.http[0])
