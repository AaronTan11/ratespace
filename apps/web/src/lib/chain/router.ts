import { parseEventLogs, type Address, type Hash, type Hex, type PublicClient, type WalletClient } from "viem";

import { erc20Abi, routerAbi } from "./abis";
import type { OrderTuple } from "./orderBuilder";
import { allowance, balanceOf } from "./tokens";

export interface Quote {
  amountIn: bigint;
  amountOut: bigint;
  orderHash: Hex;
}

/** router.quote(...) via eth_call. `takerData` must come from orderBuilder.buildTakerData. */
export async function quote(
  client: PublicClient,
  router: Address,
  order: OrderTuple,
  tokenIn: Address,
  tokenOut: Address,
  amount: bigint,
  takerData: Hex,
  account?: Address,
): Promise<Quote> {
  const [amountIn, amountOut, orderHash] = await client.readContract({
    address: router,
    abi: routerAbi,
    functionName: "quote",
    args: [order, tokenIn, tokenOut, amount, takerData],
    account,
  });
  return { amountIn, amountOut, orderHash };
}

export function routerHash(client: PublicClient, router: Address, order: OrderTuple): Promise<Hex> {
  return client.readContract({ address: router, abi: routerAbi, functionName: "hash", args: [order] });
}

export interface SwapResult {
  approveTx?: Hash;
  swapTx: Hash;
  amountIn: bigint;
  amountOut: bigint;
  /** Where amountIn/amountOut came from. */
  source: "Swapped event" | "balances before/after";
  eventError?: string;
}

/**
 * EOA taker swap (pushMode = true): approve(router, amount) on tokenIn if the allowance is short,
 * then router.swap(...). Amounts are read from the receipt's Swapped event; if decoding fails,
 * they fall back to the taker's balance deltas and `source` says so.
 */
export async function swap(
  client: PublicClient,
  wallet: WalletClient,
  taker: Address,
  router: Address,
  order: OrderTuple,
  tokenIn: Address,
  tokenOut: Address,
  amount: bigint,
  takerData: Hex,
): Promise<SwapResult> {
  const chain = wallet.chain ?? null;
  let approveTx: Hash | undefined;
  const current = await allowance(client, tokenIn, taker, router);
  if (current < amount) {
    approveTx = await wallet.writeContract({
      account: taker,
      chain,
      address: tokenIn,
      abi: erc20Abi,
      functionName: "approve",
      args: [router, amount],
    });
    const r = await client.waitForTransactionReceipt({ hash: approveTx });
    if (r.status !== "success") throw new Error(`approve reverted (tx ${approveTx})`);
  }

  const [inBefore, outBefore] = await Promise.all([
    balanceOf(client, tokenIn, taker),
    balanceOf(client, tokenOut, taker),
  ]);

  const swapTx = await wallet.writeContract({
    account: taker,
    chain,
    address: router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, tokenIn, tokenOut, amount, takerData],
  });
  const receipt = await client.waitForTransactionReceipt({ hash: swapTx });
  if (receipt.status !== "success") throw new Error(`swap reverted (tx ${swapTx})`);

  let eventError: string | undefined;
  try {
    const events = parseEventLogs({
      abi: routerAbi,
      eventName: "Swapped",
      logs: receipt.logs.filter((l) => l.address.toLowerCase() === router.toLowerCase()),
    });
    const ev = events[0];
    if (!ev) throw new Error("no Swapped event from the router in the receipt");
    return { approveTx, swapTx, amountIn: ev.args.amountIn, amountOut: ev.args.amountOut, source: "Swapped event" };
  } catch (e) {
    eventError = e instanceof Error ? e.message : String(e);
  }

  const [inAfter, outAfter] = await Promise.all([
    balanceOf(client, tokenIn, taker, receipt.blockNumber),
    balanceOf(client, tokenOut, taker, receipt.blockNumber),
  ]);
  return {
    approveTx,
    swapTx,
    amountIn: inBefore - inAfter,
    amountOut: outAfter - outBefore,
    source: "balances before/after",
    eventError,
  };
}
