import { defineChain, type Chain } from "viem";

// Pure chain selection (no env access) so it can be unit-tested; config.ts feeds it the env.

export const ANVIL_CHAIN_ID = 31337;
export const SEPOLIA_CHAIN_ID = 11155111;
export const SUPPORTED_CHAIN_IDS = [ANVIL_CHAIN_ID, SEPOLIA_CHAIN_ID] as const;

/** Used when VITE_RPC_URL is unset. Public, keyless endpoints only — never commit a keyed URL. */
export const DEFAULT_RPC_URL: Record<number, string> = {
  [ANVIL_CHAIN_ID]: "http://127.0.0.1:8545",
  [SEPOLIA_CHAIN_ID]: "https://ethereum-sepolia-rpc.publicnode.com",
};

const NAME: Record<number, string> = {
  [ANVIL_CHAIN_ID]: "Anvil",
  [SEPOLIA_CHAIN_ID]: "Sepolia",
};

const NATIVE_NAME: Record<number, string> = {
  [ANVIL_CHAIN_ID]: "Ether",
  [SEPOLIA_CHAIN_ID]: "Sepolia Ether",
};

const EXPLORER: Record<number, { name: string; url: string } | undefined> = {
  [ANVIL_CHAIN_ID]: undefined,
  [SEPOLIA_CHAIN_ID]: { name: "Etherscan", url: "https://sepolia.etherscan.io" },
};

export interface ChainConfig {
  chainId: number;
  rpcUrl: string;
  chain: Chain;
  /** True only on the local demo chain, where rate feeds are DemoRateFeed with set(). */
  isLocalDemo: boolean;
}

/** Builds the viem chain for a supported chain id. Throws on any other id. */
export function selectChain(chainIdRaw: unknown, rpcUrlRaw: unknown): ChainConfig {
  const chainId = Number(chainIdRaw ?? ANVIL_CHAIN_ID);
  if (!(SUPPORTED_CHAIN_IDS as readonly number[]).includes(chainId)) {
    throw new Error(`VITE_CHAIN_ID=${String(chainIdRaw)} is not supported; use ${SUPPORTED_CHAIN_IDS.join(" or ")}.`);
  }
  const rpcUrl =
    typeof rpcUrlRaw === "string" && rpcUrlRaw.trim() !== "" ? rpcUrlRaw.trim() : DEFAULT_RPC_URL[chainId]!;
  const explorer = EXPLORER[chainId];
  const chain = defineChain({
    id: chainId,
    name: NAME[chainId]!,
    nativeCurrency: { name: NATIVE_NAME[chainId]!, symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
    ...(explorer ? { blockExplorers: { default: explorer } } : {}),
    ...(chainId === SEPOLIA_CHAIN_ID ? { testnet: true } : {}),
  });
  return { chainId, rpcUrl, chain, isLocalDemo: chainId === ANVIL_CHAIN_ID };
}

/** Explorer link for a tx hash, or undefined when the chain has no explorer (anvil). */
export function txUrl(chain: Chain, hash: string): string | undefined {
  const base = chain.blockExplorers?.default.url;
  return base ? `${base}/tx/${hash}` : undefined;
}
