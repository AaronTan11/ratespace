import type { Address, PublicClient } from "viem";

import { erc20Abi } from "./abis";

export function balanceOf(
  client: PublicClient,
  token: Address,
  account: Address,
  blockNumber?: bigint,
): Promise<bigint> {
  return client.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account],
    blockNumber,
  });
}

export function allowance(
  client: PublicClient,
  token: Address,
  owner: Address,
  spender: Address,
): Promise<bigint> {
  return client.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [owner, spender],
  });
}

export function decimals(client: PublicClient, token: Address): Promise<number> {
  return client.readContract({ address: token, abi: erc20Abi, functionName: "decimals" });
}
