// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Per-trade math is a mechanical port of src/instructions/MovingPegSwap.sol:
//   parse() and _resolveRate() copied verbatim,
//   exec() copied as _exec() with ONLY `ctx.query.` -> `query.` and `ctx.swap.` -> `s.`.
// PeggedSwapMath and InstructionArgs are imported from lib/swap-vm (1inch swap-vm 3b3da7d), the same
// files MovingPegSwap uses. SwapQuery / SwapRegisters / IStaticExtruction come from lib/swap-vm-v1
// (1inch swap-vm v1.0.2, 32c687c), the version of 1inch's live AquaSwapVMRouter.

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SwapQuery, SwapRegisters } from "@swap-vm-v1/libs/VM.sol";
import { IStaticExtruction } from "@swap-vm-v1/instructions/Extruction.sol";

import { InstructionArgs } from "@swap-vm/libs/InstructionArgs.sol";
import { PeggedSwapMath } from "@swap-vm/libs/PeggedSwapMath.sol";

import { IRateProvider } from "../rate-providers/IRateProvider.sol";

/// @notice MovingPegSwap pricing served to 1inch's AquaSwapVMRouter v1.0.2 through the Extruction opcode.
/// @dev Stateless and `view`: the router STATICCALLs it in quote() and CALLs it in swap(); both paths run the
///   same code on the same inputs. nextPC is returned unchanged and no taker args are consumed.
/// @dev Extruction args (after the 20-byte target): exactly MovingPegSwap's args
///   [uint256 x0, uint256 y0, uint256 linearWidth, uint256 refRateLt, uint256 refRateGt, address providerLt, address providerGt, uint16 maxDeviationBps]
/// @dev `Lt` / `Gt` refer to the token with the lower / greater address, exactly as in MovingPegSwap
contract MovingPegExtruction is IStaticExtruction {
    using InstructionArgs for bytes;

    uint256 internal constant RATE_ONE = 1e18;
    uint256 internal constant BPS = 10000;
    /// @dev Hard cap on the per-order drift band (10%); owner-approved 2026-09-24
    uint256 internal constant MAX_DEVIATION_BPS_CAP = 1000;

    error MovingPegSwapInvalidInitialBalances(uint256 x0, uint256 y0);
    error MovingPegSwapInvalidLinearWidth(uint256 linearWidth);
    error MovingPegSwapInvalidRefRates(uint256 refRateLt, uint256 refRateGt);
    error MovingPegSwapInvalidMaxDeviation(uint256 maxDeviationBps);
    error MovingPegSwapZeroRate(address provider);
    error MovingPegSwapRateOutOfBand(address provider, uint256 rate, uint256 refRate, uint256 maxDeviationBps);

    function extruction(
        bool, /* isStaticContext */
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata /* takerData */
    ) external view returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap) {
        updatedSwap = swap;
        _exec(query, updatedSwap, args);
        return (nextPC, 0, updatedSwap);
    }

    function parse(bytes calldata args) internal pure returns (
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 refRateLt,
        uint256 refRateGt,
        address providerLt,
        address providerGt,
        uint16 maxDeviationBps
    ) {
        x0 = args.at(0).asU256();
        y0 = args.at(32).asU256();
        linearWidth = args.at(64).asU256();
        refRateLt = args.at(96).asU256();
        refRateGt = args.at(128).asU256();
        providerLt = args.at(160).asAddress();
        providerGt = args.at(180).asAddress();
        maxDeviationBps = args.at(200).asU16();
    }

    /// @notice Resolve and validate one side's live rate
    /// @dev Fail-closed: a zero rate or an out-of-band rate reverts; a reverting provider propagates
    function _resolveRate(address provider, uint256 refRate, uint16 maxDeviationBps) private view returns (uint256 rate) {
        rate = provider == address(0) ? refRate : IRateProvider(provider).rate();
        if (rate == 0) revert MovingPegSwapZeroRate(provider);
        if (rate * BPS < refRate * (BPS - maxDeviationBps) || rate * BPS > refRate * (BPS + maxDeviationBps)) {
            revert MovingPegSwapRateOutOfBand(provider, rate, refRate, maxDeviationBps);
        }
    }

    // ╔═══════════════════════════════════════════════════════════════════════════╗
    // ║  MOVING PEGGED SWAP CURVE                                                 ║
    // ║                                                                           ║
    // ║  Identical to PeggedSwap's math, except the per-token rate multipliers    ║
    // ║  are 1e18-scaled and read live from rate providers. The maker supplies    ║
    // ║  x0_init / y0_init in value units at ship time, so the center price       ║
    // ║  follows the live rate with no anchor change.                             ║
    // ║                                                                           ║
    // ║  Rounding directions are maker-favoring, exactly as in PeggedSwap:        ║
    // ║    amountOut rounds DOWN, amountIn rounds UP, y1 rounds UP, x1 rounds UP  ║
    // ╚═══════════════════════════════════════════════════════════════════════════╝
    function _exec(SwapQuery calldata query, SwapRegisters memory s, bytes calldata args) internal view {
        uint256 x0_init;
        uint256 y0_init;
        uint256 linearWidth;
        uint256 rateIn;
        uint256 rateOut;
        {
            uint256 refRateLt;
            uint256 refRateGt;
            address providerLt;
            address providerGt;
            uint16 maxDeviationBps;
            (x0_init, y0_init, linearWidth, refRateLt, refRateGt, providerLt, providerGt, maxDeviationBps) = parse(args);
            // Re-check the band cap at exec time: order bytes need not come from build()
            require(maxDeviationBps > 0 && maxDeviationBps <= MAX_DEVIATION_BPS_CAP, MovingPegSwapInvalidMaxDeviation(maxDeviationBps));

            if (query.tokenIn < query.tokenOut) {
                rateIn = _resolveRate(providerLt, refRateLt, maxDeviationBps);
                rateOut = _resolveRate(providerGt, refRateGt, maxDeviationBps);
            } else {
                (x0_init, y0_init) = (y0_init, x0_init);
                rateIn = _resolveRate(providerGt, refRateGt, maxDeviationBps);
                rateOut = _resolveRate(providerLt, refRateLt, maxDeviationBps);
            }
        }

        uint256 x0_raw = s.balanceIn;
        uint256 y0_raw = s.balanceOut;

        // Apply live rate multipliers to normalize to value units (1e18-scaled)
        uint256 x0 = x0_raw * rateIn / RATE_ONE;
        uint256 y0 = y0_raw * rateOut / RATE_ONE;

        // Calculate target invariant from initial state (using normalized values)
        uint256 targetInvariant = PeggedSwapMath.invariantFromReserves(
            x0,
            y0,
            x0_init,
            y0_init,
            linearWidth
        );

        if (query.isExactIn) {
            // ExactIn: calculate y1 from x1 = x0 + amountIn (normalized)
            uint256 x1 = x0 + s.amountIn * rateIn / RATE_ONE;

            // Solve for y1: given x1, find y1 that maintains invariant
            uint256 u1 = x1 * PeggedSwapMath.ONE / x0_init;  // Round DOWN u1

            // u-side invariant contribution: √u1 + a·u1
            uint256 invariantU1 = Math.sqrt(u1 * PeggedSwapMath.ONE) + linearWidth * u1 / PeggedSwapMath.ONE;

            // Capacity check without a dedicated solve(uMax):
            // g(u) = √u + a·u is strictly increasing and g(uMax) = targetInvariant,
            // so u1 >= uMax  ⟺  invariantU1 >= targetInvariant  ⟺  solve(u1) has no solution.
            if (invariantU1 >= targetInvariant) {
                // Input exceeds capacity (v would be ≤ 0): drain output reserve, recompute amountIn.
                // Cap x1 at uMax (v=0 → rightSide = targetInvariant), round UP (protects maker)
                uint256 uMax = PeggedSwapMath.solve(targetInvariant, linearWidth);
                uint256 x1Capped = Math.ceilDiv(uMax * x0_init, PeggedSwapMath.ONE);

                uint256 drainIn = Math.ceilDiv((x1Capped - x0) * RATE_ONE, rateIn);

                // At least 1 wei of tokenIn for any nonzero output (maker-favorable, matches the exactOut rule)
                if (drainIn == 0 && y0_raw != 0) {
                    drainIn = 1;
                }

                // In the dust/saturated region (normalized output rounds to 0) 1 wei of tokenIn can be
                // worth less than the output. Charge input worth at least the output value.
                if (y0 == 0) {
                    drainIn = Math.max(drainIn, Math.ceilDiv(y0_raw * rateOut, rateIn));
                }

                s.amountIn = drainIn;
                s.amountOut = y0_raw; // drain output reserve
            } else {
                uint256 rightSide = targetInvariant - invariantU1;
                uint256 v1 = PeggedSwapMath.solve(rightSide, linearWidth);

                // Round UP y1 (normalized) to ensure amountOut rounds DOWN (protects maker)
                uint256 y1 = Math.ceilDiv(v1 * y0_init, PeggedSwapMath.ONE);

                // Convert back from value units: amountOut = (y0 - y1) * RATE_ONE / rateOut
                // Round DOWN to protect maker
                s.amountOut = (y0 - y1) * RATE_ONE / rateOut;
            }
        } else {
            if (s.amountOut > y0_raw) s.amountOut = y0_raw;

            // ExactOut: calculate x1 from y1 = y0 - amountOut (normalized).
            // Saturate: a full-reserve exactOut makes ceilDiv(...) exceed the floored y0 by
            // at most 1; the true remaining value is 0, so clamp to 0 instead of underflowing.
            uint256 c = Math.ceilDiv(s.amountOut * rateOut, RATE_ONE);
            uint256 y1 = y0 > c ? y0 - c : 0;

            // Solve for x1: given y1, find x1 that maintains invariant
            uint256 v1 = y1 * PeggedSwapMath.ONE / y0_init;  // Round DOWN v1

            uint256 invariantV1 = Math.sqrt(v1 * PeggedSwapMath.ONE) + linearWidth * v1 / PeggedSwapMath.ONE;
            require(targetInvariant >= invariantV1, PeggedSwapMath.PeggedSwapMathInvalidInput());
            uint256 u1 = PeggedSwapMath.solve(targetInvariant - invariantV1, linearWidth);

            // Round UP x1 (normalized) to ensure amountIn rounds UP (protects maker)
            uint256 x1 = Math.ceilDiv(u1 * x0_init, PeggedSwapMath.ONE);

            // Convert back from value units: amountIn = (x1 - x0) * RATE_ONE / rateIn
            // Round UP to protect maker
            uint256 amountIn = Math.ceilDiv((x1 - x0) * RATE_ONE, rateIn);

            // least 1 wei of tokenIn for any nonzero output (maker-favorable, matches the ceilDiv intent).
            if (amountIn == 0 && s.amountOut != 0) {
                amountIn = 1;
            }

            // Dust fill (normalized output reserve rounds to 0): 1 wei of tokenIn can be worth less
            // than the output. Charge input worth at least the output value. Same gate as the drain floor.
            if (y0 == 0) {
                amountIn = Math.max(amountIn, Math.ceilDiv(s.amountOut * rateOut, rateIn));
            }

            s.amountIn = amountIn;
        }
    }
}
