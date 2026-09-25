import type { Address, Hash, PublicClient, WalletClient } from "viem";

import { rateFeedAbi } from "./abis";
import { bumpByBps } from "./math";

export function readRate(client: PublicClient, feed: Address, blockNumber?: bigint): Promise<bigint> {
  return client.readContract({ address: feed, abi: rateFeedAbi, functionName: "rate", blockNumber });
}

export class NotMakerError extends Error {
  constructor(connected: Address, maker: Address) {
    super(`Connected wallet ${connected} is not the maker ${maker}; switch to the maker account.`);
    this.name = "NotMakerError";
  }
}

export interface RateStep {
  tx: Hash;
  before: bigint;
  after: bigint;
  blockNumber: bigint;
}

/**
 * "Simulate Lido report": feed.set(rate * (10000 + bps) / 10000) from the connected wallet,
 * which must be the maker account. `before` is read right before sending, `after` at the receipt block.
 */
export async function simulateReport(
  client: PublicClient,
  wallet: WalletClient,
  account: Address,
  maker: Address,
  feed: Address,
  bps: bigint,
): Promise<RateStep> {
  if (account.toLowerCase() !== maker.toLowerCase()) throw new NotMakerError(account, maker);
  const before = await readRate(client, feed);
  const tx = await wallet.writeContract({
    account,
    chain: wallet.chain ?? null,
    address: feed,
    abi: rateFeedAbi,
    functionName: "set",
    args: [bumpByBps(before, bps)],
  });
  const r = await client.waitForTransactionReceipt({ hash: tx });
  if (r.status !== "success") throw new Error(`set reverted (tx ${tx})`);
  const after = await readRate(client, feed, r.blockNumber);
  return { tx, before, after, blockNumber: r.blockNumber };
}
