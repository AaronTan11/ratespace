// Display-only formatting. Pure bigint (via chain/math); no floats touch amounts or rates.
import { formatUnits } from "viem";

import { formatFixed } from "@/lib/chain/math";

/** Display precision for rates and amounts (brief: 6 dp, truncated, never rounded up). */
export const DISPLAY_DP = 6;

/** 1e`decimals` value truncated to 6 dp, e.g. 1.244787. */
export function fmt6(value: bigint, decimals = 18): string {
  return formatFixed(value, decimals, DISPLAY_DP);
}

/** Hover text carrying the full precision: "1.244787728742679575 (1244787728742679575 wei)". */
export function fullTitle(value: bigint, decimals = 18): string {
  return `${formatUnits(value, decimals)} (${value.toString()} wei)`;
}

/** 0x1234…abcd for addresses and hashes. */
export function shortHex(h: string, head = 6, tail = 4): string {
  return h.length <= head + tail + 1 ? h : `${h.slice(0, head)}…${h.slice(-tail)}`;
}

/** Sign of a formatDeltaBps string ("+1.0000" / "-0.5000" / "0.0000") for good/bad colouring. */
export function deltaSign(delta: string): 1 | -1 | 0 {
  if (delta.startsWith("-")) return -1;
  return /[1-9]/.test(delta) ? 1 : 0;
}
