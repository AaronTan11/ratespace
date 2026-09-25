import { describe, expect, it } from "vite-plus/test";

import { bumpByBps, deltaBpsScaled, formatDeltaBps, formatFixed, formatScaled } from "../math";

const WSTETH = 1244787728742679575n; // demo-lane seed rate for the wstETH feed

describe("bps delta (bigint)", () => {
  it("a +1 bp feed bump reads back as ~+1.0000 bps", () => {
    const after = bumpByBps(WSTETH, 1n);
    // hand check: 1244787728742679575 * 10001 / 10000 = 1244912207515553842 (truncated)
    expect(after).toBe(1244912207515553842n);
    const s = deltaBpsScaled(WSTETH, after);
    // (124478772874267 * 1e8) / 1244787728742679575 = 9999 (truncation of 0.99999999...)
    expect(s).toBe(9999n);
    expect(formatDeltaBps(WSTETH, after)).toBe("+0.9999");
  });

  it("exact values", () => {
    expect(deltaBpsScaled(10000n, 10001n)).toBe(10000n);
    expect(formatDeltaBps(10000n, 10001n)).toBe("+1.0000");
    expect(formatDeltaBps(10000n, 10000n)).toBe("0.0000");
    expect(formatDeltaBps(10000n, 9999n)).toBe("-1.0000");
    expect(formatDeltaBps(3n, 4n)).toBe("+3333.3333");
  });

  it("rejects a zero base", () => {
    expect(() => deltaBpsScaled(0n, 1n)).toThrow();
  });
});

describe("fixed-point formatting (no floats)", () => {
  it("truncates to 6 dp", () => {
    expect(formatFixed(WSTETH, 18, 6)).toBe("1.244787");
    expect(formatFixed(1n, 18, 6)).toBe("0.000000");
    expect(formatFixed(10n ** 18n, 18, 18)).toBe("1.000000000000000000");
  });
  it("pads and signs", () => {
    expect(formatScaled(-5n, 4)).toBe("-0.0005");
    expect(formatScaled(12345n, 0)).toBe("12345");
  });
});
