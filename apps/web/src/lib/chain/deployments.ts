import type { Address, Hex } from "viem";
import { z } from "zod";

import example from "./deployments.example.json";

// Shape written by the demo lane (packages/contracts/script/DeployDemo.s.sol).
// If the real file differs when it lands, adapt THIS loader only.

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/, "expected a 20-byte hex address");
const hex = z.string().regex(/^0x([0-9a-fA-F]{2})*$/, "expected even-length hex");
const bytes32 = z.string().regex(/^0x[0-9a-fA-F]{64}$/, "expected a 32-byte hex value");
const decimalUint = z.string().regex(/^[0-9]+$/, "expected a decimal uint256 string");

const orderSchema = z.object({
  name: z.string(),
  maker: address,
  traits: decimalUint,
  data: hex,
  program: hex,
  strategyHash: bytes32,
  tokenYield: address,
  tokenWeth: address,
  hasFee: z.boolean(),
  rateFeed: address,
});

const deploymentsSchema = z.object({
  chainId: z.number().int(),
  addresses: z.object({
    aqua: address,
    router: address,
    extruction: address,
    orderBuilder: address,
    weth: address,
    wstETH: address,
    rETH: address,
    weETH: address,
    feedWstETH: address,
    feedRETH: address,
    feedWeETH: address,
  }),
  orders: z.array(orderSchema),
});

export type YieldKey = "wstETH" | "rETH" | "weETH";
export const YIELD_KEYS: readonly YieldKey[] = ["wstETH", "rETH", "weETH"];

export interface DeployedOrder {
  name: string;
  maker: Address;
  traits: string;
  data: Hex;
  program: Hex;
  strategyHash: Hex;
  tokenYield: Address;
  tokenWeth: Address;
  hasFee: boolean;
  rateFeed: Address;
}

export interface Deployments {
  chainId: number;
  addresses: Record<
    | "aqua"
    | "router"
    | "extruction"
    | "orderBuilder"
    | "weth"
    | YieldKey
    | "feedWstETH"
    | "feedRETH"
    | "feedWeETH",
    Address
  >;
  orders: DeployedOrder[];
}

/** Validates an unknown JSON value against the demo-lane deployments shape. Throws on mismatch. */
export function parseDeployments(raw: unknown): Deployments {
  return deploymentsSchema.parse(raw) as Deployments;
}

/** The on-chain ISwapVM.Order tuple for an order from the deployments file. */
export function toOrderTuple(order: DeployedOrder) {
  return { maker: order.maker, traits: BigInt(order.traits), data: order.data } as const;
}

export type DeploymentsSource = "deployments/31337.json" | "deployments.example.json";

export interface LoadedDeployments {
  deployed: boolean;
  source: DeploymentsSource;
  deployments: Deployments;
  error?: string;
}

// import.meta.glob resolves to {} when the file does not exist yet, so the app still builds
// before the demo lane has run script/demo.sh.
const realFile = import.meta.glob<{ default: unknown }>(
  "../../../../../packages/contracts/deployments/31337.json",
  { eager: true },
);

export function loadDeployments(files: Record<string, { default: unknown }> = realFile): LoadedDeployments {
  const mod = Object.values(files)[0];
  if (mod) {
    try {
      return { deployed: true, source: "deployments/31337.json", deployments: parseDeployments(mod.default) };
    } catch (e) {
      return {
        deployed: false,
        source: "deployments.example.json",
        deployments: parseDeployments(example),
        error: `packages/contracts/deployments/31337.json does not match the expected shape: ${String(e)}`,
      };
    }
  }
  return { deployed: false, source: "deployments.example.json", deployments: parseDeployments(example) };
}

export const loaded: LoadedDeployments = loadDeployments();

const FEED_KEY: Record<YieldKey, "feedWstETH" | "feedRETH" | "feedWeETH"> = {
  wstETH: "feedWstETH",
  rETH: "feedRETH",
  weETH: "feedWeETH",
};

export interface Market {
  key: YieldKey;
  token: Address;
  feed: Address;
  order: DeployedOrder;
}

/** One no-fee (shared-backing) order per yield token, matched by the token address. */
export function marketsOf(d: Deployments): Market[] {
  const out: Market[] = [];
  for (const key of YIELD_KEYS) {
    const token = d.addresses[key];
    const order = d.orders.find(
      (o) => !o.hasFee && o.tokenYield.toLowerCase() === token.toLowerCase(),
    );
    if (order) out.push({ key, token, feed: d.addresses[FEED_KEY[key]], order });
  }
  return out;
}
