import { expect, test } from "@playwright/test";
import { createWalletClient, http, parseEther, parseEventLogs, type Address } from "viem";

import { orderBuilderAbi, routerAbi } from "../src/lib/chain/abis";
import { anvil, bal, connect, dep, expectClean, guard, pc, uiSwap } from "./helpers";
import { E2E_RPC, TAKER, installWallet } from "./injected-wallet";

const AMOUNT = parseEther("0.1");

test.describe("trade as the taker (anvil account 1)", () => {
  for (const dir of ["exit", "enter"] as const) {
    test(`/trade UI swap, ${dir === "exit" ? "Exit: wstETH → WETH" : "Enter: WETH → wstETH"}, 0.1, quote == received`, async ({ browser }) => {
      const context = await browser.newContext();
      await installWallet(context, TAKER);
      const page = await context.newPage();
      const w = await guard(context, page);
      await page.goto("/trade");
      await connect(page, TAKER);
      const tokenIn = (dir === "exit" ? dep.DemoWstETH : dep.DemoWETH) as Address;
      const tokenOut = (dir === "exit" ? dep.DemoWETH : dep.DemoWstETH) as Address;
      const r = await uiSwap(page, {
        key: "wstETH",
        dir,
        amount: "0.1",
        taker: TAKER,
        tokenIn,
        tokenOut,
        shotPrefix: dir === "exit" ? "06-trade-exit" : "07-trade-enter",
      });
      console.log(
        `[e2e] ${dir}: quote=${r.quote} tx=${r.tx} status=${r.status} block=${r.blockNumber} ` +
          `in ${r.inBefore}->${r.inAfter} (delta ${r.inBefore - r.inAfter}) out ${r.outBefore}->${r.outAfter} ` +
          `(delta ${r.outAfter - r.outBefore}) orderHash=${r.orderHash} quoteVsFeed="${r.quoteVsFeed}"`,
      );
      expect(r.status).toBe("success");
      expect(r.inBefore - r.inAfter).toBe(AMOUNT);
      expect(r.outAfter - r.outBefore).toBe(r.quote);
      expect(r.orderHash.toLowerCase()).toBe(dep.orders[0]!.strategyHash.toLowerCase());
      expectClean(w);
      await context.close();
    });
  }

  // The /trade UI lists only the no-fee order per yield token (marketsOf), so the fee order (the 4th
  // order in the deployments file, wstETH + 0.05%) cannot be picked in the UI. It is checked here
  // directly with viem against the same router, taker and amount.
  test("fee order (wstETH, 0.05%) via viem, not the UI: quote == received, fee quote < no-fee quote", async () => {
    const fee = dep.orders.find((o) => o.hasFee)!;
    const noFee = dep.orders[0]!;
    const router = dep.AquaSwapVMRouter;
    const takerData = await pc.readContract({
      address: dep.RateSpaceOrderBuilder,
      abi: orderBuilderAbi,
      functionName: "buildTakerData",
      args: [TAKER, true, true],
    });
    const tuple = (o: typeof fee) => ({ maker: o.maker, traits: BigInt(o.traits), data: o.data });
    const args = (o: typeof fee) => [tuple(o), dep.DemoWstETH, dep.DemoWETH, AMOUNT, takerData] as const;
    const [, feeOut, feeHash] = await pc.readContract({ address: router, abi: routerAbi, functionName: "quote", args: args(fee), account: TAKER });
    const [, noFeeOut] = await pc.readContract({ address: router, abi: routerAbi, functionName: "quote", args: args(noFee), account: TAKER });
    expect(feeHash.toLowerCase()).toBe(fee.strategyHash.toLowerCase());
    expect(feeOut < noFeeOut).toBe(true);

    const wallet = createWalletClient({ account: TAKER, chain: anvil, transport: http(E2E_RPC) });
    const [inBefore, outBefore] = await Promise.all([bal(dep.DemoWstETH, TAKER), bal(dep.DemoWETH, TAKER)]);
    const tx = await wallet.writeContract({ address: router, abi: routerAbi, functionName: "swap", args: args(fee) });
    const receipt = await pc.waitForTransactionReceipt({ hash: tx });
    const [inAfter, outAfter] = await Promise.all([bal(dep.DemoWstETH, TAKER), bal(dep.DemoWETH, TAKER)]);
    const ev = parseEventLogs({ abi: routerAbi, eventName: "Swapped", logs: receipt.logs })[0];
    console.log(
      `[e2e] fee order: feeQuote=${feeOut} noFeeQuote=${noFeeOut} tx=${tx} status=${receipt.status} ` +
        `wstETH delta ${inBefore - inAfter} WETH delta ${outAfter - outBefore} event amountOut=${ev?.args.amountOut} hash=${feeHash}`,
    );
    expect(receipt.status).toBe("success");
    expect(inBefore - inAfter).toBe(AMOUNT);
    expect(outAfter - outBefore).toBe(feeOut);
  });
});
