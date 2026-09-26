import type { Address, Hex } from "viem";
import { z } from "zod";

import { CHAIN_ID } from "./config";
import example from "./deployments.example.json";

// Shapes read from packages/contracts/deployments/<chainId>.json (flat keys, normalised below):
//
// 31337 (demo lane, script/DeployDemo.s.sol): Aqua, AquaSwapVMRouter, MovingPegExtruction,
//   RateSpaceOrderBuilder, DemoWETH, DemoWstETH, DemoRETH, DemoWeETH, RateFeedWstETH, RateFeedRETH,
//   RateFeedWeETH, orders[] (DemoRateFeed feeds: rate() and set()).
// 11155111 (sepolia-deploy lane): Aqua, AquaSwapVMRouter, RateSpaceAquaRouter, MovingPegExtruction,
//   RateSpaceOrderBuilder, WETH, WstETH, RateProviderWstETH, orders[] where rateFeed = RateProviderWstETH
//   (WstETHRateProvider: rate() only) and each order may carry `router` = the router it was shipped to.
//   No rETH/weETH on Sepolia.
//
// Only wstETH is a required market; rETH/weETH (and their feeds) are optional. Unknown keys are ignored.
// An order without `router` uses AquaSwapVMRouter (addresses.router).

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
  router: address.optional(),
});

const deploymentsSchema = z.object({
  chainId: z.number().int(),
  addresses: z.object({
    aqua: address,
    router: address,
    orderBuilder: address,
    weth: address,
    wstETH: address,
    feedWstETH: address,
    extruction: address.optional(),
    ourRouter: address.optional(),
    rETH: address.optional(),
    weETH: address.optional(),
    feedRETH: address.optional(),
    feedWeETH: address.optional(),
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
  /** Router the order was shipped to; absent means addresses.router (AquaSwapVMRouter). */
  router?: Address;
}

export interface Deployments {
  chainId: number;
  addresses: Record<"aqua" | "router" | "orderBuilder" | "weth" | "wstETH" | "feedWstETH", Address> &
    Partial<Record<"extruction" | "ourRouter" | "rETH" | "weETH" | "feedRETH" | "feedWeETH", Address>>;
  orders: DeployedOrder[];
}

// The demo lane's DeployDemo.s.sol writes flat contract keys and orders without a name.
// Normalise that shape into the one the app was written against; leave the nested shape untouched.
const FLAT_TO_ADDRESS: Record<string, keyof Deployments["addresses"]> = {
  Aqua: "aqua",
  AquaSwapVMRouter: "router",
  MovingPegExtruction: "extruction",
  RateSpaceOrderBuilder: "orderBuilder",
  DemoWETH: "weth",
  DemoWstETH: "wstETH",
  DemoRETH: "rETH",
  DemoWeETH: "weETH",
  RateFeedWstETH: "feedWstETH",
  RateFeedRETH: "feedRETH",
  RateFeedWeETH: "feedWeETH",
  // Sepolia (real Lido wstETH market)
  WETH: "weth",
  WstETH: "wstETH",
  RateProviderWstETH: "feedWstETH",
  RateSpaceAquaRouter: "ourRouter",
};

function normaliseDeployments(raw: unknown): unknown {
  if (typeof raw !== "object" || raw === null) return raw;
  const r = raw as Record<string, unknown>;
  if (typeof r.addresses === "object" && r.addresses !== null) return raw;
  const addresses: Record<string, unknown> = {};
  for (const [flat, key] of Object.entries(FLAT_TO_ADDRESS)) {
    if (typeof r[flat] === "string") addresses[key] = r[flat];
  }
  const yieldName = (token: unknown): string => {
    for (const key of YIELD_KEYS) {
      const a = addresses[key];
      if (typeof a === "string" && typeof token === "string" && a.toLowerCase() === token.toLowerCase()) return key;
    }
    return "order";
  };
  const orders = Array.isArray(r.orders)
    ? r.orders.map((o: unknown, i: number) => {
        if (typeof o !== "object" || o === null) return o;
        const order = o as Record<string, unknown>;
        if (typeof order.name === "string") return order;
        const base = yieldName(order.tokenYield);
        return { ...order, name: `${base}${order.hasFee ? "-fee" : ""}-${i + 1}` };
      })
    : r.orders;
  return { chainId: r.chainId, addresses, orders };
}

/** Validates an unknown JSON value against the demo-lane deployments shape. Throws on mismatch. */
export function parseDeployments(raw: unknown): Deployments {
  return deploymentsSchema.parse(normaliseDeployments(raw)) as Deployments;
}

/** The on-chain ISwapVM.Order tuple for an order from the deployments file. */
export function toOrderTuple(order: DeployedOrder) {
  return { maker: order.maker, traits: BigInt(order.traits), data: order.data } as const;
}

export type DeploymentsSource = `deployments/${number}.json` | "deployments.example.json";

export interface LoadedDeployments {
  deployed: boolean;
  source: DeploymentsSource;
  deployments: Deployments;
  error?: string;
}

// Every packages/contracts/deployments/<chainId>.json (ABI dumps excluded). import.meta.glob resolves
// to {} when none exists yet, so the app still builds before a deploy has run.
const realFiles = import.meta.glob<{ default: unknown }>(
  ["../../../../../packages/contracts/deployments/*.json", "!../../../../../packages/contracts/deployments/*.abi.json"],
  { eager: true },
);

function rawChainId(raw: unknown): unknown {
  return typeof raw === "object" && raw !== null ? (raw as Record<string, unknown>).chainId : undefined;
}

/** Picks the deployments file whose `chainId` equals `chainId`; falls back to the example file. */
export function loadDeployments(
  files: Record<string, { default: unknown }> = realFiles,
  chainId: number = CHAIN_ID,
): LoadedDeployments {
  const mod = Object.values(files).find((f) => Number(rawChainId(f.default)) === chainId);
  const source: DeploymentsSource = `deployments/${chainId}.json`;
  if (mod) {
    try {
      return { deployed: true, source, deployments: parseDeployments(mod.default) };
    } catch (e) {
      return {
        deployed: false,
        source: "deployments.example.json",
        deployments: parseDeployments(example),
        error: `packages/contracts/${source} does not match the expected shape: ${String(e)}`,
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
  /** The yield token's rate source: DemoRateFeed on anvil, WstETHRateProvider on Sepolia. */
  feed: Address;
  /** Router this market's order lives on (quote / swap / hash / approve target, Aqua app). */
  router: Address;
  order: DeployedOrder;
}

/**
 * One no-fee (shared-backing) order per yield token, matched by the token address.
 * Only markets whose token address AND order exist are returned.
 */
export function marketsOf(d: Deployments): Market[] {
  const out: Market[] = [];
  for (const key of YIELD_KEYS) {
    const token = d.addresses[key];
    if (!token) continue;
    const order = d.orders.find(
      (o) => !o.hasFee && o.tokenYield.toLowerCase() === token.toLowerCase(),
    );
    if (!order) continue;
    out.push({
      key,
      token,
      feed: d.addresses[FEED_KEY[key]] ?? order.rateFeed,
      router: order.router ?? d.addresses.router,
      order,
    });
  }
  return out;
}
