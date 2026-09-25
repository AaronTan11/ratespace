import type { Address, Hash, Hex, PublicClient, WalletClient } from "viem";

import { aquaAbi } from "./abis";

export interface RawBalance {
  balance: bigint;
  tokensCount: number;
}

/** Aqua.rawBalances(maker, app, strategyHash, token). `app` is the router for our orders. */
export async function rawBalances(
  client: PublicClient,
  aqua: Address,
  maker: Address,
  app: Address,
  strategyHash: Hex,
  token: Address,
): Promise<RawBalance> {
  const [balance, tokensCount] = await client.readContract({
    address: aqua,
    abi: aquaAbi,
    functionName: "rawBalances",
    args: [maker, app, strategyHash, token],
  });
  return { balance, tokensCount };
}

/** Aqua.ship(app, strategy, tokens, amounts). `strategy` must be orderBuilder.encodeOrder(order). */
export async function ship(
  client: PublicClient,
  wallet: WalletClient,
  maker: Address,
  aqua: Address,
  app: Address,
  strategy: Hex,
  tokens: Address[],
  amounts: bigint[],
): Promise<Hash> {
  const hash = await wallet.writeContract({
    account: maker,
    chain: wallet.chain ?? null,
    address: aqua,
    abi: aquaAbi,
    functionName: "ship",
    args: [app, strategy, tokens, amounts],
  });
  const r = await client.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`ship reverted (tx ${hash})`);
  return hash;
}

/** Aqua.dock(app, strategyHash, tokens): closes the strategy for all listed tokens. */
export async function dock(
  client: PublicClient,
  wallet: WalletClient,
  maker: Address,
  aqua: Address,
  app: Address,
  strategyHash: Hex,
  tokens: Address[],
): Promise<Hash> {
  const hash = await wallet.writeContract({
    account: maker,
    chain: wallet.chain ?? null,
    address: aqua,
    abi: aquaAbi,
    functionName: "dock",
    args: [app, strategyHash, tokens],
  });
  const r = await client.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`dock reverted (tx ${hash})`);
  return hash;
}
