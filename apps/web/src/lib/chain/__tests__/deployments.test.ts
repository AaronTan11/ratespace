import { describe, expect, it } from "vite-plus/test";

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
    const l = loadDeployments({});
    expect(l.deployed).toBe(false);
    expect(l.source).toBe("deployments.example.json");
    expect(l.error).toBeUndefined();
  });

  it("valid real file -> deployed; picks the three no-fee orders by token", () => {
    const l = loadDeployments({ "x/31337.json": { default: fixture() } });
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
    const l = loadDeployments({ "x/31337.json": { default: bad } });
    expect(l.deployed).toBe(false);
    expect(l.error).toMatch(/does not match/);
  });

  it("rejects a non-decimal traits string", () => {
    const f = fixture();
    f.orders[0]!.traits = "0x10";
    expect(() => parseDeployments(f)).toThrow();
  });
});
