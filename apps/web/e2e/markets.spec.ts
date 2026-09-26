import { expect, test } from "@playwright/test";
import { formatUnits } from "viem";

import { rawBalances } from "../src/lib/chain/aqua";
import { bal, dep, expectClean, guard, pc, shot } from "./helpers";
import { MAKER, TAKER, installWallet } from "./injected-wallet";

// First spec (file order) on the fresh deploy from e2e/run.sh: nothing has traded yet.
test("markets page: one 10 WETH wallet backs three markets (30 WETH of quotes)", async ({ browser }) => {
  const context = await browser.newContext();
  await installWallet(context, TAKER);
  const page = await context.newPage();
  const w = await guard(context, page);
  await page.goto("/");
  const statement = page.locator(".rs-statement");
  await expect(statement).toContainText("in the wallet backs");
  await expect(page.locator(".rs-table tbody tr")).toHaveCount(3);

  const walletWeth = await bal(dep.DemoWETH, MAKER);
  const virtual = await Promise.all(
    dep.orders
      .filter((o) => !o.hasFee)
      .map((o) => rawBalances(pc, dep.Aqua, o.maker, dep.AquaSwapVMRouter, o.strategyHash, o.tokenWeth)),
  );
  const total = virtual.reduce((s, v) => s + v.balance, 0n);
  const text = (await statement.innerText()).replace(/\s+/g, " ");
  console.log(`[e2e] markets: statement "${text}" · maker wallet WETH ${walletWeth} · virtual WETH ${virtual.map((v) => v.balance).join(", ")} · total ${total}`);
  expect(walletWeth).toBe(10n * 10n ** 18n);
  expect(total).toBe(30n * 10n ** 18n);
  expect(text).toContain(`${Number(formatUnits(walletWeth, 18)).toFixed(6)}WETH in the wallet backs ${Number(formatUnits(total, 18)).toFixed(6)}WETH of quotes`);
  await shot(page, "01-markets");
  expectClean(w);
  await context.close();
});
