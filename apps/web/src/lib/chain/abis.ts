// Hand-written ABIs, transcribed from the Solidity sources until the demo lane's
// packages/contracts/deployments/31337.abi.json lands:
//   - IRateSpaceOrderBuilder: scratchpad/mvp/ORDER_BUILDER_INTERFACE.sol (7 functions)
//   - ISwapVM (router) + SwapVM.Swapped: 1inch swap-vm v1.0.2 src/interfaces/ISwapVM.sol, src/SwapVM.sol
//   - IAqua: @1inch/aqua 0.1.0 src/interfaces/IAqua.sol
//   - DemoRateFeed: rate()/set(uint256)/RateSet(uint256,uint256) per the demo lane brief
// MakerTraits is a user-defined `uint256` type, so it is `uint256` on the wire.

const orderTuple = {
  type: "tuple",
  name: "order",
  components: [
    { name: "maker", type: "address" },
    { name: "traits", type: "uint256" },
    { name: "data", type: "bytes" },
  ],
} as const;

export const orderBuilderAbi = [
  {
    type: "function",
    name: "buildMovingPegArgs",
    stateMutability: "pure",
    inputs: [
      { name: "x0", type: "uint256" },
      { name: "y0", type: "uint256" },
      { name: "linearWidth", type: "uint256" },
      { name: "refRateLt", type: "uint256" },
      { name: "refRateGt", type: "uint256" },
      { name: "providerLt", type: "address" },
      { name: "providerGt", type: "address" },
      { name: "maxDeviationBps", type: "uint16" },
    ],
    outputs: [{ name: "", type: "bytes" }],
  },
  {
    type: "function",
    name: "buildProgram",
    stateMutability: "pure",
    inputs: [
      { name: "extructionTarget", type: "address" },
      { name: "mpsArgs", type: "bytes" },
      { name: "feeBps1e9", type: "uint32" },
      { name: "salt", type: "uint64" },
    ],
    outputs: [{ name: "", type: "bytes" }],
  },
  {
    type: "function",
    name: "buildOrder",
    stateMutability: "pure",
    inputs: [
      { name: "maker", type: "address" },
      { name: "program", type: "bytes" },
    ],
    outputs: [{ ...orderTuple, name: "" }],
  },
  {
    type: "function",
    name: "buildTakerData",
    stateMutability: "pure",
    inputs: [
      { name: "taker", type: "address" },
      { name: "isExactIn", type: "bool" },
      { name: "pushMode", type: "bool" },
    ],
    outputs: [{ name: "", type: "bytes" }],
  },
  {
    type: "function",
    name: "encodeOrder",
    stateMutability: "pure",
    inputs: [orderTuple],
    outputs: [{ name: "", type: "bytes" }],
  },
  {
    type: "function",
    name: "orderHash",
    stateMutability: "pure",
    inputs: [orderTuple],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    type: "function",
    name: "anchorFor",
    stateMutability: "pure",
    inputs: [
      { name: "balance", type: "uint256" },
      { name: "rate", type: "uint256" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

const swapArgs = [
  orderTuple,
  { name: "tokenIn", type: "address" },
  { name: "tokenOut", type: "address" },
  { name: "amount", type: "uint256" },
  { name: "takerTraitsAndData", type: "bytes" },
] as const;

const swapOutputs = [
  { name: "amountIn", type: "uint256" },
  { name: "amountOut", type: "uint256" },
  { name: "orderHash", type: "bytes32" },
] as const;

export const routerAbi = [
  {
    type: "function",
    name: "hash",
    stateMutability: "view",
    inputs: [orderTuple],
    outputs: [{ name: "", type: "bytes32" }],
  },
  { type: "function", name: "quote", stateMutability: "view", inputs: swapArgs, outputs: swapOutputs },
  {
    type: "function",
    name: "swap",
    stateMutability: "nonpayable",
    inputs: swapArgs,
    outputs: swapOutputs,
  },
  {
    type: "event",
    name: "Swapped",
    anonymous: false,
    inputs: [
      { name: "orderHash", type: "bytes32", indexed: false },
      { name: "maker", type: "address", indexed: false },
      { name: "taker", type: "address", indexed: false },
      { name: "tokenIn", type: "address", indexed: false },
      { name: "tokenOut", type: "address", indexed: false },
      { name: "amountIn", type: "uint256", indexed: false },
      { name: "amountOut", type: "uint256", indexed: false },
    ],
  },
] as const;

export const aquaAbi = [
  {
    type: "function",
    name: "rawBalances",
    stateMutability: "view",
    inputs: [
      { name: "maker", type: "address" },
      { name: "app", type: "address" },
      { name: "strategyHash", type: "bytes32" },
      { name: "token", type: "address" },
    ],
    outputs: [
      { name: "balance", type: "uint248" },
      { name: "tokensCount", type: "uint8" },
    ],
  },
  {
    type: "function",
    name: "safeBalances",
    stateMutability: "view",
    inputs: [
      { name: "maker", type: "address" },
      { name: "app", type: "address" },
      { name: "strategyHash", type: "bytes32" },
      { name: "token0", type: "address" },
      { name: "token1", type: "address" },
    ],
    outputs: [
      { name: "balance0", type: "uint256" },
      { name: "balance1", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "ship",
    stateMutability: "nonpayable",
    inputs: [
      { name: "app", type: "address" },
      { name: "strategy", type: "bytes" },
      { name: "tokens", type: "address[]" },
      { name: "amounts", type: "uint256[]" },
    ],
    outputs: [{ name: "strategyHash", type: "bytes32" }],
  },
  {
    type: "function",
    name: "dock",
    stateMutability: "nonpayable",
    inputs: [
      { name: "app", type: "address" },
      { name: "strategyHash", type: "bytes32" },
      { name: "tokens", type: "address[]" },
    ],
    outputs: [],
  },
] as const;

export const rateFeedAbi = [
  {
    type: "function",
    name: "rate",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "set",
    stateMutability: "nonpayable",
    inputs: [{ name: "newRate", type: "uint256" }],
    outputs: [],
  },
  {
    type: "event",
    name: "RateSet",
    anonymous: false,
    inputs: [
      { name: "old", type: "uint256", indexed: false },
      { name: "new", type: "uint256", indexed: false },
    ],
  },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
] as const;
