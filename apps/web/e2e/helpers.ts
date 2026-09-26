import { readFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { expect, type BrowserContext, type Page } from "@playwright/test";
import { createPublicClient, defineChain, http, type Address, type Hex } from "viem";

import { erc20Abi, rateFeedAbi } from "../src/lib/chain/abis";
import { E2E_RPC } from "./injected-wallet";

const here = dirname(fileURLToPath(import.meta.url));
export const DEPLOYMENTS_FILE = resolve(here, "../../../packages/contracts/deployments/test-e2e-31337.json");
export const SHOTS = process.env.E2E_SHOTS_DIR ?? join(here, ".run/shots");
mkdirSync(SHOTS, { recursive: true });

export const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [E2E_RPC] } },
});
export const pc = createPublicClient({ chain: anvil, transport: http(E2E_RPC) });

export interface RawOrder {
  maker: Address;
  traits: string;
  data: Hex;
  strategyHash: Hex;
  tokenYield: Address;
  tokenWeth: Address;
  hasFee: boolean;
  rateFeed: Address;
}
export interface RawDeployments {
  chainId: number;
  Aqua: Address;
  AquaSwapVMRouter: Address;
  RateSpaceOrderBuilder: Address;
  DemoWETH: Address;
  DemoWstETH: Address;
  RateFeedWstETH: Address;
  orders: RawOrder[];
}
export const dep: RawDeployments = JSON.parse(readFileSync(DEPLOYMENTS_FILE, "utf8"));

export const bal = (token: Address, who: Address) =>
  pc.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [who] });
export const feedRate = (feed: Address) => pc.readContract({ address: feed, abi: rateFeedAbi, functionName: "rate" });

/** Parses the raw wei out of a <Num> title: "0.080331005269595626 (80331005269595626 wei)". */
export function weiOfTitle(title: string | null): bigint {
  const m = title?.match(/\((\d+) wei\)/);
  if (!m) throw new Error(`no "(N wei)" in title ${JSON.stringify(title)}`);
  return BigInt(m[1]!);
}

/** Full-page PNG into SHOTS; callers pass ordered names ("03-trade-exit-before"). */
export async function shot(page: Page, name: string) {
  const file = join(SHOTS, `${name}.png`);
  await page.screenshot({ path: file, fullPage: true });
  console.log(`[e2e] screenshot ${file}`);
}

export interface Watch {
  errors: string[];
  rpc8545: string[];
}

/**
 * Per-page guards: record console errors / page errors, fail any request to the owner's anvil on 8545,
 * and serve Google Fonts as empty CSS so no real network is touched.
 */
export async function guard(context: BrowserContext, page: Page): Promise<Watch> {
  const w: Watch = { errors: [], rpc8545: [] };
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) =>
    r.fulfill({ status: 200, contentType: "text/css", body: "" }),
  );
  await context.route(/127\.0\.0\.1:8545|localhost:8545/, (r) => {
    w.rpc8545.push(r.request().url());
    return r.abort();
  });
  page.on("console", (m) => {
    if (m.type() === "error") w.errors.push(m.text());
  });
  page.on("pageerror", (e) => w.errors.push(`pageerror: ${e.message}`));
  return w;
}

/** Click the header "Connect wallet" chip and wait for the short address chip. */
export async function connect(page: Page, account: Address) {
  // The header chip reads "No wallet" during SSR and "Connect wallet" once window.ethereum is seen.
  await page.locator(".rs-header").getByRole("button", { name: /Connect wallet$/ }).click({ timeout: 30_000 });
  await expect(page.locator(`.rs-header [title="${account}"]`)).toBeVisible();
}

export function expectClean(w: Watch) {
  expect(w.rpc8545, "requests to the owner's anvil on 8545").toEqual([]);
  expect(w.errors, "console errors").toEqual([]);
}

export interface UiSwap {
  quote: bigint;
  orderHash: string;
  tx: Hex;
  inBefore: bigint;
  inAfter: bigint;
  outBefore: bigint;
  outAfter: bigint;
  blockNumber: bigint;
  status: string;
  quoteVsFeed: string;
}

/**
 * On /trade (wallet connected): pick market + direction, type the amount, read "You receive" (raw wei from
 * its title), click Swap, wait for the success toast, then read the receipt and balances via viem on 8547.
 */
export async function uiSwap(
  page: Page,
  o: { key: string; dir: "exit" | "enter"; amount: string; taker: Address; tokenIn: Address; tokenOut: Address; shotPrefix?: string },
): Promise<UiSwap> {
  await page.getByRole("group", { name: "Market" }).getByRole("button", { name: o.key, exact: true }).click();
  const dirLabel = o.dir === "exit" ? `Exit: ${o.key} → WETH` : `Enter: WETH → ${o.key}`;
  await page.getByRole("button", { name: dirLabel }).click();
  await expect(page.getByRole("button", { name: dirLabel })).toHaveAttribute("aria-pressed", "true");
  await page.locator("#amount").fill(o.amount);

  const receive = page.locator(".rs-quote .receive .rs-num");
  await expect(receive).toBeVisible();
  // Balance chip loaded => the swap button's approve-state is known.
  await expect(page.getByRole("button", { name: /^(Swap|Approve and swap)$/ })).toBeEnabled();
  const quote = weiOfTitle(await receive.getAttribute("title"));
  const orderHash = (await page.locator("dt:text-is('Order hash') + dd .rs-hex").getAttribute("title")) ?? "";
  const quoteVsFeed = (await page.locator("dt:text-is('Quote vs feed') + dd").innerText()).trim();
  if (o.shotPrefix) await shot(page, `${o.shotPrefix}-1-before`);

  const [inBefore, outBefore] = await Promise.all([bal(o.tokenIn, o.taker), bal(o.tokenOut, o.taker)]);
  await page.getByRole("button", { name: /^(Swap|Approve and swap)$/ }).click();
  const toast = page.locator("[data-sonner-toast]").filter({ hasText: "Swapped" });
  await expect(toast).toBeVisible({ timeout: 30_000 });
  const desc = await toast.innerText();
  const m = desc.match(/tx (0x[0-9a-f]{64})/);
  if (!m) throw new Error(`no tx hash in toast: ${desc}`);
  const tx = m[1] as Hex;
  const receipt = await pc.getTransactionReceipt({ hash: tx });
  const [inAfter, outAfter] = await Promise.all([
    pc.readContract({ address: o.tokenIn, abi: erc20Abi, functionName: "balanceOf", args: [o.taker], blockNumber: receipt.blockNumber }),
    pc.readContract({ address: o.tokenOut, abi: erc20Abi, functionName: "balanceOf", args: [o.taker], blockNumber: receipt.blockNumber }),
  ]);
  if (o.shotPrefix) await shot(page, `${o.shotPrefix}-2-after`);
  return { quote, orderHash, tx, inBefore, inAfter, outBefore, outAfter, blockNumber: receipt.blockNumber, status: receipt.status, quoteVsFeed };
}
