import { ENV } from "@/env";
import { createPublicClient, defineChain, http } from "viem";

// Public values from apps/web/.env.schema (statically replaced by the varlock vite plugin).
export const RPC_URL: string = String(ENV.VITE_RPC_URL);
export const CHAIN_ID: number = Number(ENV.VITE_CHAIN_ID);

export const anvil = defineChain({
  id: CHAIN_ID,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

export const publicClient = createPublicClient({ chain: anvil, transport: http(RPC_URL) });

/** Refetch interval for every live chain read (brief: every 4 s). */
export const REFRESH_MS = 4000;
