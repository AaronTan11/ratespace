// Assembles deployments/31337.abi.json from `forge inspect <Contract> abi --json`.
// Run from packages/contracts: `bun run scripts/build-demo-abi.ts`. No dependencies.

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

const V1 = "lib/swap-vm-v1/src";
const abis = {
  AquaSwapVMRouter: pick(inspect(`${V1}/routers/AquaSwapVMRouter.sol:AquaSwapVMRouter`), ["quote", "swap", "hash"]),
  Aqua: pick(inspect("lib/swap-vm-v1/node_modules/@1inch/aqua/src/Aqua.sol:Aqua"), ["ship", "dock", "rawBalances", "safeBalances"]),
  IRateSpaceOrderBuilder: inspect("src/demo/IRateSpaceOrderBuilder.sol:IRateSpaceOrderBuilder"),
  DemoWETH: inspect("src/demo/mocks/DemoWETH.sol:DemoWETH"),
  DemoYieldToken: inspect("src/demo/mocks/DemoYieldToken.sol:DemoYieldToken"),
  DemoRateFeed: inspect("src/demo/mocks/DemoRateFeed.sol:DemoRateFeed"),
  ERC20: pick(inspect("lib/swap-vm/node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20"), ["approve", "balanceOf", "allowance"]),
  // MovingPegExtruction reverts (rate out of band, zero rate) bubble up through the router; errors only
  MovingPegExtruction: pick(inspect("src/extruction/MovingPegExtruction.sol:MovingPegExtruction"), []),
};

await Bun.write("deployments/31337.abi.json", JSON.stringify(abis, null, 2) + "\n");
console.log(`wrote deployments/31337.abi.json (${Object.keys(abis).join(", ")})`);
