import { describe, expect, it } from "vite-plus/test";

import { deltaSign, fmt6, fullTitle, shortHex } from "../format";

describe("format", () => {
  it("fmt6 truncates to 6 dp without rounding", () => {
    expect(fmt6(1244787728742679575n)).toBe("1.244787");
    expect(fmt6(999999999999999999n)).toBe("0.999999");
    expect(fmt6(10n ** 18n * 10n)).toBe("10.000000");
    expect(fmt6(1_234_567n, 6)).toBe("1.234567");
  });
  it("fullTitle carries full precision and raw wei", () => {
    expect(fullTitle(1244787728742679575n)).toBe("1.244787728742679575 (1244787728742679575 wei)");
  });
  it("shortHex keeps head and tail", () => {
    expect(shortHex("0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0")).toBe("0x9fE4…a6e0");
    expect(shortHex("0x1234")).toBe("0x1234");
  });
  it("deltaSign reads formatDeltaBps output", () => {
    expect(deltaSign("+1.0000")).toBe(1);
    expect(deltaSign("-0.5000")).toBe(-1);
    expect(deltaSign("0.0000")).toBe(0);
  });
});
