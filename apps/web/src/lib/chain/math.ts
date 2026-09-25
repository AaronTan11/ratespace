// Pure bigint helpers. No floating point anywhere on token amounts or rates.

/** rate * (10000 + bps) / 10000 (the brief's feed bump). */
export function bumpByBps(rate: bigint, bps: bigint): bigint {
  return (rate * (10000n + bps)) / 10000n;
}

/**
 * delta_bps = (after - before) * 10000 / before, returned in units of 1e-4 bps
 * (i.e. scaled by 10^4 so it can be shown with 4 decimals). Truncates toward zero.
 */
export function deltaBpsScaled(before: bigint, after: bigint): bigint {
  if (before === 0n) throw new Error("deltaBps: before must be non-zero");
  return ((after - before) * 10000n * 10000n) / before;
}

/** Formats a value scaled by 10^decimals as a fixed-point string with exactly `decimals` places. */
export function formatScaled(value: bigint, decimals: number): string {
  const neg = value < 0n;
  const abs = neg ? -value : value;
  const base = 10n ** BigInt(decimals);
  const int = abs / base;
  const frac = (abs % base).toString().padStart(decimals, "0");
  return `${neg ? "-" : ""}${int.toString()}${decimals > 0 ? `.${frac}` : ""}`;
}

/** delta in bps with 4 decimals, e.g. "1.0000" for a +1 bp step. */
export function formatDeltaBps(before: bigint, after: bigint): string {
  const s = deltaBpsScaled(before, after);
  return `${s > 0n ? "+" : ""}${formatScaled(s, 4)}`;
}

/**
 * Formats a 1e`decimals`-scaled value truncated to `dp` places (no rounding, no floats).
 * e.g. formatFixed(1244787728742679575n, 18, 6) === "1.244787".
 */
export function formatFixed(value: bigint, decimals: number, dp: number): string {
  if (dp >= decimals) return formatScaled(value * 10n ** BigInt(dp - decimals), dp);
  return formatScaled(value / 10n ** BigInt(decimals - dp), dp);
}

/** Price in 1e18 units: numerator * 1e18 / denominator (both in the same decimals). */
export function ratio1e18(numerator: bigint, denominator: bigint): bigint | null {
  if (denominator === 0n) return null;
  return (numerator * 10n ** 18n) / denominator;
}
