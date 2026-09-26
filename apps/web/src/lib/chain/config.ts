import { ENV } from "@/env";
import { createPublicClient, http } from "viem";

import { selectChain } from "./chains";

// Public values from apps/web/.env.schema (statically replaced by the varlock vite plugin).
// VITE_CHAIN_ID: 31337 (local anvil demo, default) or 11155111 (Sepolia).
// VITE_RPC_URL: optional; defaults per chain (see chains.ts DEFAULT_RPC_URL).
const selected = selectChain(ENV.VITE_CHAIN_ID, ENV.VITE_RPC_URL);

export const RPC_URL: string = selected.rpcUrl;
export const CHAIN_ID: number = selected.chainId;
export const IS_LOCAL_DEMO: boolean = selected.isLocalDemo;
export const chain = selected.chain;

export const publicClient = createPublicClient({ chain, transport: http(RPC_URL) });

/** Refetch interval for every live chain read (brief: every 4 s). */
export const REFRESH_MS = 4000;
