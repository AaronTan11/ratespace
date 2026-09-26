import { expect, test } from "@playwright/test";
import { parseEther, type Address } from "viem";

import { bumpByBps } from "../src/lib/chain/math";
import { connect, dep, expectClean, feedRate, guard, shot, uiSwap, weiOfTitle } from "./helpers";
import { MAKER, TAKER, installWallet } from "./injected-wallet";

// DeployDemo.s.sol RATE_WSTETH; e2e/run.sh deploys fresh and only markets.spec (read-only) runs before this one.
const DEPLOYED_WSTETH_RATE = 1244787728742679575n;

test("rate step +1 bp as the maker (anvil account 0): same order hash, new quote, quote == received", async ({ browser }) => {
  const wstOrder = dep.orders[0]!;

  // Taker's /trade view before the step: quote for 0.1 wstETH → WETH and the order hash.
  const takerCtx = await browser.newContext();
  await installWallet(takerCtx, TAKER);
  const taker = await takerCtx.newPage();
  const wt = await guard(takerCtx, taker);
  await taker.goto("/trade");
  await connect(taker, TAKER);
  await taker.locator("#amount").fill("0.1");
  const receive = taker.locator(".rs-quote .receive .rs-num");
  await expect(receive).toBeVisible();
  const quoteBefore = weiOfTitle(await receive.getAttribute("title"));
  const hashBefore = await taker.locator("dt:text-is('Order hash') + dd .rs-hex").getAttribute("title");
  await shot(taker, "02-trade-quote-before-step");

  // Maker's /rate: step wstETH +1 bp.
  const makerCtx = await browser.newContext();
  await installWallet(makerCtx, MAKER);
  const maker = await makerCtx.newPage();
  const wm = await guard(makerCtx, maker);
  await maker.goto("/rate");
  await connect(maker, MAKER);
  const row = maker.locator("tbody").filter({ hasText: "wstETH" }).first();
  await expect(row.getByText("matches", { exact: true })).toBeVisible();
  const onChainBefore = await feedRate(dep.RateFeedWstETH as Address);
  expect(onChainBefore).toBe(DEPLOYED_WSTETH_RATE);
  const uiRateBefore = weiOfTitle(await row.locator("td").nth(2).locator(".rs-num").getAttribute("title"));
  expect(uiRateBefore).toBe(onChainBefore);
  await shot(maker, "03-rate-before");

  await row.getByRole("button", { name: "Simulate report +1 bp" }).click();
  await expect(maker.locator("[data-sonner-toast]").filter({ hasText: "wstETH feed stepped" })).toBeVisible({ timeout: 30_000 });
  const onChainAfter = await feedRate(dep.RateFeedWstETH as Address);
  expect(onChainAfter).toBe(bumpByBps(onChainBefore, 1n));
  const step = row.locator(".rs-step");
  await expect(step.getByText("unchanged", { exact: true })).toBeVisible();
  await expect(row.locator("td").nth(2).locator(".rs-num")).toHaveAttribute("title", new RegExp(`\\(${onChainAfter} wei\\)`));
  await expect(row.getByText("matches", { exact: true })).toBeVisible();
  const routerHashNow = await row.locator(".rs-chip.good").filter({ hasText: "matches" }).getAttribute("title");
  const stepText = (await step.innerText()).replace(/\s+/g, " ");
  await shot(maker, "04-rate-after");
  console.log(`[e2e] rate: before=${onChainBefore} after=${onChainAfter} chip="${routerHashNow}" strategyHash=${wstOrder.strategyHash}`);
  console.log(`[e2e] rate step row: "${stepText}"`);
  expect(routerHashNow).toContain(wstOrder.strategyHash);
  expectClean(wm);
  await makerCtx.close();

  // Taker again: the quote moved, the order hash did not; then swap and check quote == received.
  await taker.reload();
  await connect(taker, TAKER);
  const r = await uiSwap(taker, {
    key: "wstETH",
    dir: "exit",
    amount: "0.1",
    taker: TAKER,
    tokenIn: dep.DemoWstETH,
    tokenOut: dep.DemoWETH,
    shotPrefix: "05-trade-after-step",
  });
  console.log(
    `[e2e] after step: quoteBefore=${quoteBefore} quoteAfter=${r.quote} hashBefore=${hashBefore} hashAfter=${r.orderHash} ` +
      `tx=${r.tx} status=${r.status} wstETH ${r.inBefore}->${r.inAfter} (delta ${r.inBefore - r.inAfter}) WETH ${r.outBefore}->${r.outAfter} (delta ${r.outAfter - r.outBefore}) quoteVsFeed="${r.quoteVsFeed}"`,
  );
  expect(r.quote).not.toBe(quoteBefore);
  expect(r.quote > quoteBefore).toBe(true); // higher rate => more WETH per wstETH
  expect(r.orderHash).toBe(hashBefore);
  expect(r.orderHash.toLowerCase()).toBe(wstOrder.strategyHash.toLowerCase());
  expect(r.status).toBe("success");
  expect(r.inBefore - r.inAfter).toBe(parseEther("0.1"));
  expect(r.outAfter - r.outBefore).toBe(r.quote);
  expectClean(wt);
  await takerCtx.close();
});
