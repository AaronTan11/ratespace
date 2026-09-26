import { describe, expect, it } from "vite-plus/test";

import anvilFile from "../../../../../../packages/contracts/deployments/31337.json";
import { ANVIL_CHAIN_ID, SEPOLIA_CHAIN_ID, selectChain, txUrl } from "../chains";
import example from "../deployments.example.json";
import { loadDeployments, marketsOf, parseDeployments, toOrderTuple } from "../deployments";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}`;

function fixture() {
  const order = (i: number, tokenYield: string, hasFee: boolean, rateFeed: string) => ({
    name: `order-${i}`,
    maker: A(0xaa),
    traits: "115792089237316195423570985008687907853269984665640564039457584007913129639935",
    data: "0x1234",
    program: "0xabcd",
    strategyHash: H(i),
    tokenYield,
    tokenWeth: A(5),
    hasFee,
    rateFeed,
  });
  return {
    chainId: 31337,
    addresses: {
      aqua: A(1),
      router: A(2),
      extruction: A(3),
      orderBuilder: A(4),
      weth: A(5),
      wstETH: A(6),
      rETH: A(7),
      weETH: A(8),
      feedWstETH: A(9),
      feedRETH: A(10),
      feedWeETH: A(11),
    },
    orders: [
      order(1, A(6), false, A(9)),
      order(2, A(7), false, A(10)),
      order(3, A(8), false, A(11)),
      order(4, A(6), true, A(9)),
    ],
  };
}

describe("deployments loader shape", () => {
  it("the example file has the demo-lane shape", () => {
    const d = parseDeployments(example);
    expect(d.chainId).toBe(31337);
    expect(Object.keys(d.addresses).sort()).toEqual(
      ["aqua", "extruction", "feedRETH", "feedWeETH", "feedWstETH", "orderBuilder", "rETH", "router", "weETH", "weth", "wstETH"],
    );
    expect(Object.keys(d.orders[0]!).sort()).toEqual(
      ["data", "hasFee", "maker", "name", "program", "rateFeed", "strategyHash", "tokenWeth", "tokenYield", "traits"],
    );
  });

  it("no real file -> example, not deployed", () => {
    const l = loadDeployments({}, 31337);
    expect(l.deployed).toBe(false);
    expect(l.source).toBe("deployments.example.json");
    expect(l.error).toBeUndefined();
  });

  it("valid real file -> deployed; picks the three no-fee orders by token", () => {
    const l = loadDeployments({ "x/31337.json": { default: fixture() } }, 31337);
    expect(l.deployed).toBe(true);
    expect(l.source).toBe("deployments/31337.json");
    const m = marketsOf(l.deployments);
    expect(m.map((x) => x.key)).toEqual(["wstETH", "rETH", "weETH"]);
    expect(m.map((x) => x.order.name)).toEqual(["order-1", "order-2", "order-3"]);
    expect(m[0]!.feed).toBe(A(9));
  });

  it("traits decimal string -> exact bigint (no precision loss)", () => {
    const d = parseDeployments(fixture());
    expect(toOrderTuple(d.orders[0]!).traits).toBe(2n ** 256n - 1n);
  });

  it("malformed real file -> falls back to example with an error", () => {
    const bad = fixture() as Record<string, unknown>;
    delete bad.addresses;
    const l = loadDeployments({ "x/31337.json": { default: bad } }, 31337);
    expect(l.deployed).toBe(false);
    expect(l.error).toMatch(/does not match/);
  });

  it("rejects a non-decimal traits string", () => {
    const f = fixture();
    f.orders[0]!.traits = "0x10";
    expect(() => parseDeployments(f)).toThrow();
  });
});

// Frozen 11155111.json shape (sepolia-deploy lane): flat keys, WETH/WstETH/RateProviderWstETH,
// RateSpaceAquaRouter, no rETH/weETH, orders with rateFeed = RateProviderWstETH and a `router`.
function sepoliaFixture() {
  const order = (i: number, hasFee: boolean, router?: string) => ({
    maker: A(0xbb),
    traits: "1",
    data: "0x12",
    program: "0x12",
    strategyHash: H(0x100 + i),
    tokenYield: A(0x26),
    tokenWeth: A(0x25),
    hasFee,
    rateFeed: A(0x27),
    ...(router ? { router } : {}),
  });
  return {
    chainId: 11155111,
    maker: A(0xbb),
    Aqua: A(0x21),
    AquaSwapVMRouter: A(0x22),
    RateSpaceAquaRouter: A(0x2a),
    MovingPegExtruction: A(0x23),
    RateSpaceOrderBuilder: A(0x24),
    WETH: A(0x25),
    WstETH: A(0x26),
    RateProviderWstETH: A(0x27),
    somethingNew: "ignored",
    orders: [order(1, true, A(0x22)), order(2, false, A(0x2a))],
  };
}

describe("optional markets and per-order router", () => {
  it("Sepolia flat shape -> only the wstETH market, on the order's router, fed by the rate provider", () => {
    const d = parseDeployments(sepoliaFixture());
    expect(d.chainId).toBe(11155111);
    expect(d.addresses).toMatchObject({
      aqua: A(0x21),
      router: A(0x22),
      ourRouter: A(0x2a),
      extruction: A(0x23),
      orderBuilder: A(0x24),
      weth: A(0x25),
      wstETH: A(0x26),
      feedWstETH: A(0x27),
    });
    expect(d.addresses.rETH).toBeUndefined();
    expect(d.addresses.weETH).toBeUndefined();
    expect(d.orders.map((o) => o.name)).toEqual(["wstETH-fee-1", "wstETH-2"]);
    const m = marketsOf(d);
    expect(m.map((x) => x.key)).toEqual(["wstETH"]);
    expect(m[0]!.order.name).toBe("wstETH-2");
    expect(m[0]!.router).toBe(A(0x2a));
    expect(m[0]!.feed).toBe(A(0x27));
  });

  it("order without `router` -> AquaSwapVMRouter (addresses.router)", () => {
    const f = sepoliaFixture();
    delete (f.orders[1] as { router?: string }).router;
    const m = marketsOf(parseDeployments(f));
    expect(m[0]!.router).toBe(A(0x22));
  });

  it("anvil nested shape: every market uses addresses.router when orders carry no router", () => {
    const m = marketsOf(parseDeployments(fixture()));
    expect(m.map((x) => x.router)).toEqual([A(2), A(2), A(2)]);
  });

  it("token without an order, or order without a token -> no market", () => {
    const f = fixture();
    f.orders = f.orders.filter((o) => o.tokenYield !== A(7)); // rETH token, no rETH order
    const g = f as unknown as { addresses: Record<string, string | undefined> };
    delete g.addresses.weETH; // weETH order, no weETH token
    delete g.addresses.feedWeETH;
    expect(marketsOf(parseDeployments(f)).map((x) => x.key)).toEqual(["wstETH"]);
  });

  it("wstETH (token and feed) stays required", () => {
    const f = sepoliaFixture() as Record<string, unknown>;
    delete f.WstETH;
    expect(() => parseDeployments(f)).toThrow();
    const g = sepoliaFixture() as Record<string, unknown>;
    delete g.RateProviderWstETH;
    expect(() => parseDeployments(g)).toThrow();
  });

  it("rejects a malformed per-order router", () => {
    const f = sepoliaFixture();
    (f.orders[1] as { router?: string }).router = "0x1234";
    expect(() => parseDeployments(f)).toThrow();
  });

  it("the committed 31337.json still yields wstETH, rETH, weETH on AquaSwapVMRouter", () => {
    const d = parseDeployments(anvilFile);
    const m = marketsOf(d);
    expect(m.map((x) => x.key)).toEqual(["wstETH", "rETH", "weETH"]);
    for (const x of m) expect(x.router).toBe(anvilFile.AquaSwapVMRouter);
  });
});

describe("chain selection", () => {
  const files = {
    "x/31337.json": { default: fixture() },
    "x/11155111.json": { default: sepoliaFixture() },
    "x/31337.abi.json": { default: { AquaSwapVMRouter: [] } },
  };

  it("picks the file whose chainId matches", () => {
    const s = loadDeployments(files, SEPOLIA_CHAIN_ID);
    expect(s.deployed).toBe(true);
    expect(s.source).toBe("deployments/11155111.json");
    expect(s.deployments.chainId).toBe(11155111);
    const a = loadDeployments(files, ANVIL_CHAIN_ID);
    expect(a.source).toBe("deployments/31337.json");
    expect(a.deployments.chainId).toBe(31337);
  });

  it("matches on the chainId field, not the file name", () => {
    const l = loadDeployments({ "x/whatever.json": { default: sepoliaFixture() } }, SEPOLIA_CHAIN_ID);
    expect(l.deployed).toBe(true);
    expect(loadDeployments({ "x/11155111.json": { default: fixture() } }, SEPOLIA_CHAIN_ID).deployed).toBe(false);
  });

  it("no file for the chain -> example, not deployed, no error", () => {
    const l = loadDeployments({ "x/31337.json": { default: fixture() } }, SEPOLIA_CHAIN_ID);
    expect(l.deployed).toBe(false);
    expect(l.source).toBe("deployments.example.json");
    expect(l.error).toBeUndefined();
  });

  it("selectChain: anvil default", () => {
    const c = selectChain(undefined, undefined);
    expect(c.chainId).toBe(31337);
    expect(c.rpcUrl).toBe("http://127.0.0.1:8545");
    expect(c.chain.name).toBe("Anvil");
    expect(c.isLocalDemo).toBe(true);
    expect(c.chain.blockExplorers).toBeUndefined();
    expect(txUrl(c.chain, "0xab")).toBeUndefined();
  });

  it("selectChain: Sepolia with the public default RPC and etherscan", () => {
    const c = selectChain(11155111, "");
    expect(c.chainId).toBe(11155111);
    expect(c.rpcUrl).toBe("https://ethereum-sepolia-rpc.publicnode.com");
    expect(c.chain.name).toBe("Sepolia");
    expect(c.chain.nativeCurrency).toEqual({ name: "Sepolia Ether", symbol: "ETH", decimals: 18 });
    expect(c.isLocalDemo).toBe(false);
    expect(txUrl(c.chain, "0xab")).toBe("https://sepolia.etherscan.io/tx/0xab");
  });

  it("selectChain: VITE_RPC_URL overrides the default; string chain id accepted", () => {
    const c = selectChain("11155111", "http://127.0.0.1:8546");
    expect(c.chainId).toBe(11155111);
    expect(c.rpcUrl).toBe("http://127.0.0.1:8546");
    expect(c.chain.rpcUrls.default.http).toEqual(["http://127.0.0.1:8546"]);
  });

  it("selectChain: unsupported chain id throws", () => {
    expect(() => selectChain(1, undefined)).toThrow(/not supported/);
  });
});
