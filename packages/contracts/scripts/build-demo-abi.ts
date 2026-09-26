// Assembles deployments/<chainId>.abi.json from `forge inspect <Contract> abi --json`.
// Run from packages/contracts: `bun run scripts/build-demo-abi.ts` (31337, local demo) or
// `bun run scripts/build-demo-abi.ts 11155111` (Sepolia: no demo mocks; adds RateSpaceAquaRouter and
// WstETHRateProvider). No dependencies.

type AbiItem = { type: string; name?: string };

function inspect(id: string): AbiItem[] {
  const p = Bun.spawnSync(["forge", "inspect", id, "abi", "--json"], { stderr: "pipe" });
  if (p.exitCode !== 0) throw new Error(`forge inspect ${id} failed: ${p.stderr.toString()}`);
  return JSON.parse(p.stdout.toString());
}

/// Keep only the named functions; keep every event and error (the app decodes reverts and logs with them)
function pick(abi: AbiItem[], fns: string[]): AbiItem[] {
  const out = abi.filter((i) => (i.type === "function" ? fns.includes(i.name ?? "") : i.type === "event" || i.type === "error"));
  for (const f of fns) {
    if (!out.some((i) => i.type === "function" && i.name === f)) throw new Error(`function ${f} missing from ABI`);
  }
  return out;
}

const chainId = process.argv[2] ?? "31337";
if (chainId !== "31337" && chainId !== "11155111") throw new Error(`unsupported chainId ${chainId}`);

const V1 = "lib/swap-vm-v1/src";
const common = {
  AquaSwapVMRouter: pick(inspect(`${V1}/routers/AquaSwapVMRouter.sol:AquaSwapVMRouter`), ["quote", "swap", "hash"]),
  Aqua: pick(inspect("lib/swap-vm-v1/node_modules/@1inch/aqua/src/Aqua.sol:Aqua"), ["ship", "dock", "rawBalances", "safeBalances"]),
  IRateSpaceOrderBuilder: inspect("src/demo/IRateSpaceOrderBuilder.sol:IRateSpaceOrderBuilder"),
};
const tail = {
  ERC20: pick(inspect("lib/swap-vm/node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20"), ["approve", "balanceOf", "allowance"]),
  // MovingPegExtruction reverts (rate out of band, zero rate) bubble up through the router; errors only
  MovingPegExtruction: pick(inspect("src/extruction/MovingPegExtruction.sol:MovingPegExtruction"), []),
};
const abis =
  chainId === "31337"
    ? {
        ...common,
        DemoWETH: inspect("src/demo/mocks/DemoWETH.sol:DemoWETH"),
        DemoYieldToken: inspect("src/demo/mocks/DemoYieldToken.sol:DemoYieldToken"),
        DemoRateFeed: inspect("src/demo/mocks/DemoRateFeed.sol:DemoRateFeed"),
        ...tail,
      }
    : {
        ...common,
        ...tail,
        // Fallback router (swap-vm 3b3da7d ABI: quote/swap take no tokenIn/tokenOut; direction is in taker traits)
        RateSpaceAquaRouter: pick(inspect("src/routers/RateSpaceAquaRouter.sol:RateSpaceAquaRouter"), ["quote", "swap", "hash"]),
        WstETHRateProvider: pick(inspect("src/rate-providers/WstETHRateProvider.sol:WstETHRateProvider"), ["rate", "WSTETH"]),
      };

await Bun.write(`deployments/${chainId}.abi.json`, JSON.stringify(abis, null, 2) + "\n");
console.log(`wrote deployments/${chainId}.abi.json (${Object.keys(abis).join(", ")})`);
