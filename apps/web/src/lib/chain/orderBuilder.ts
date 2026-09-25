import type { Address, Hex, PublicClient } from "viem";

import { orderBuilderAbi } from "./abis";

// Typed wrappers over the on-chain IRateSpaceOrderBuilder. The app NEVER encodes order or
// taker bytes itself; every byte string comes from one of these eth_calls.

export type OrderTuple = { maker: Address; traits: bigint; data: Hex };

export function buildTakerData(
  client: PublicClient,
  builder: Address,
  taker: Address,
  isExactIn: boolean,
  pushMode = true,
): Promise<Hex> {
  return client.readContract({
    address: builder,
    abi: orderBuilderAbi,
    functionName: "buildTakerData",
    args: [taker, isExactIn, pushMode],
  });
}

export function buildMovingPegArgs(
  client: PublicClient,
  builder: Address,
  a: {
    x0: bigint;
    y0: bigint;
    linearWidth: bigint;
    refRateLt: bigint;
    refRateGt: bigint;
    providerLt: Address;
    providerGt: Address;
    maxDeviationBps: number;
  },
): Promise<Hex> {
  return client.readContract({
    address: builder,
    abi: orderBuilderAbi,
    functionName: "buildMovingPegArgs",
    args: [a.x0, a.y0, a.linearWidth, a.refRateLt, a.refRateGt, a.providerLt, a.providerGt, a.maxDeviationBps],
  });
}

export function buildProgram(
  client: PublicClient,
  builder: Address,
  extructionTarget: Address,
  mpsArgs: Hex,
  feeBps1e9: number,
  salt: bigint,
): Promise<Hex> {
  return client.readContract({
    address: builder,
    abi: orderBuilderAbi,
    functionName: "buildProgram",
    args: [extructionTarget, mpsArgs, feeBps1e9, salt],
  });
}

export function buildOrder(
  client: PublicClient,
  builder: Address,
  maker: Address,
  program: Hex,
): Promise<OrderTuple> {
  return client.readContract({
    address: builder,
    abi: orderBuilderAbi,
    functionName: "buildOrder",
    args: [maker, program],
  });
}

export function encodeOrder(client: PublicClient, builder: Address, order: OrderTuple): Promise<Hex> {
  return client.readContract({
    address: builder,
    abi: orderBuilderAbi,
    functionName: "encodeOrder",
    args: [order],
  });
}

export function orderHash(client: PublicClient, builder: Address, order: OrderTuple): Promise<Hex> {
  return client.readContract({
    address: builder,
    abi: orderBuilderAbi,
    functionName: "orderHash",
    args: [order],
  });
}

export function anchorFor(
  client: PublicClient,
  builder: Address,
  balance: bigint,
  rate: bigint,
): Promise<bigint> {
  return client.readContract({
    address: builder,
    abi: orderBuilderAbi,
    functionName: "anchorFor",
    args: [balance, rate],
  });
}
