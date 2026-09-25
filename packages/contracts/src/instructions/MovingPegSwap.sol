// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "@swap-vm/libs/VM.sol";
import { Opcode } from "@swap-vm/libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "@swap-vm/libs/MemoryPtr.sol";
import { InstructionBuilder } from "@swap-vm/libs/InstructionBuilder.sol";
import { InstructionArgs } from "@swap-vm/libs/InstructionArgs.sol";
import { PeggedSwapMath } from "@swap-vm/libs/PeggedSwapMath.sol";

import { IRateProvider } from "../rate-providers/IRateProvider.sol";

/// @notice MovingPegSwap opcode: PeggedSwap whose per-token rate multipliers are read live
///   from rate-provider contracts instead of being frozen in the order bytecode
/// @dev Encoding: [uint256 x0, uint256 y0, uint256 linearWidth, uint256 refRateLt, uint256 refRateGt, address providerLt, address providerGt, uint16 maxDeviationBps]
/// @dev `Lt` / `Gt` refer to the token with the lower / greater address, exactly as in PeggedSwap
/// @dev Rates are 1e18-scaled (RATE_ONE = 1e18); a side with `provider == address(0)` uses its
///   reference rate, and the ETH-side rate is exactly 1e18 so its normalization is the identity
library MovingPegSwap {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

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

    Opcode constant opcode = Opcode._59;

    function sizeOf(uint256, uint256, uint256, uint256, uint256, address, address, uint16) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 32 + 32 + 32 + 32 + 32 + 20 + 20 + 2;
    }

    /// @param x0 Initial X reserve (normalization factor) in value units = initial_balance_X * rateX / RATE_ONE
    /// @param y0 Initial Y reserve (normalization factor) in value units = initial_balance_Y * rateY / RATE_ONE
    /// @param linearWidth Linear component coefficient A scaled by 1e27 (e.g., 100e27 for A=100)
    /// @param refRateLt Reference rate for the token with the LOWER address, scaled by 1e18
    /// @param refRateGt Reference rate for the token with the GREATER address, scaled by 1e18
    /// @param providerLt Rate provider for the token with the LOWER address (address(0) = use refRateLt)
    /// @param providerGt Rate provider for the token with the GREATER address (address(0) = use refRateGt)
    /// @param maxDeviationBps Maximum allowed live-rate deviation from the reference rate, in bps
    function build(
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 refRateLt,
        uint256 refRateGt,
        address providerLt,
        address providerGt,
        uint16 maxDeviationBps
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(x0, y0, linearWidth, refRateLt, refRateGt, providerLt, providerGt, maxDeviationBps)),
            x0,
            y0,
            linearWidth,
            refRateLt,
            refRateGt,
            providerLt,
            providerGt,
            maxDeviationBps
        ).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 refRateLt,
        uint256 refRateGt,
        address providerLt,
        address providerGt,
        uint16 maxDeviationBps
    ) internal pure returns (MemoryPtr ptr) {
        require(x0 > 0 && y0 > 0, MovingPegSwapInvalidInitialBalances(x0, y0));
        require(linearWidth <= PeggedSwapMath.MAX_LINEAR_WIDTH, MovingPegSwapInvalidLinearWidth(linearWidth));
        require(refRateLt > 0 && refRateGt > 0, MovingPegSwapInvalidRefRates(refRateLt, refRateGt));
        require(maxDeviationBps > 0 && maxDeviationBps <= MAX_DEVIATION_BPS_CAP, MovingPegSwapInvalidMaxDeviation(maxDeviationBps));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(x0, 32).push(y0, 32).push(linearWidth, 32).push(refRateLt, 32).push(refRateGt, 32);
        ptr = ptr.push(providerLt).push(providerGt).push(maxDeviationBps, 2);
        ptrStart.patchLength(ptr);
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

    /// @notice Anchor (normalization factor) for one side, in value units
    /// @param balance Raw token balance at ship time
    /// @param rate Rate of that token at ship time, 1e18-scaled
    /// @return balance * rate / RATE_ONE (floor)
    function anchorFor(uint256 balance, uint256 rate) internal pure returns (uint256) {
        return balance * rate / RATE_ONE;
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
    function exec(Context memory ctx, bytes calldata args) internal view {
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

            if (ctx.query.tokenIn < ctx.query.tokenOut) {
                rateIn = _resolveRate(providerLt, refRateLt, maxDeviationBps);
                rateOut = _resolveRate(providerGt, refRateGt, maxDeviationBps);
            } else {
                (x0_init, y0_init) = (y0_init, x0_init);
                rateIn = _resolveRate(providerGt, refRateGt, maxDeviationBps);
                rateOut = _resolveRate(providerLt, refRateLt, maxDeviationBps);
            }
        }

        uint256 x0_raw = ctx.swap.balanceIn;
        uint256 y0_raw = ctx.swap.balanceOut;

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

        if (ctx.query.isExactIn) {
            // ExactIn: calculate y1 from x1 = x0 + amountIn (normalized)
            uint256 x1 = x0 + ctx.swap.amountIn * rateIn / RATE_ONE;

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

                ctx.swap.amountIn = drainIn;
                ctx.swap.amountOut = y0_raw; // drain output reserve
            } else {
                uint256 rightSide = targetInvariant - invariantU1;
                uint256 v1 = PeggedSwapMath.solve(rightSide, linearWidth);

                // Round UP y1 (normalized) to ensure amountOut rounds DOWN (protects maker)
                uint256 y1 = Math.ceilDiv(v1 * y0_init, PeggedSwapMath.ONE);

                // Convert back from value units: amountOut = (y0 - y1) * RATE_ONE / rateOut
                // Round DOWN to protect maker
                ctx.swap.amountOut = (y0 - y1) * RATE_ONE / rateOut;
            }
        } else {
            if (ctx.swap.amountOut > y0_raw) ctx.swap.amountOut = y0_raw;

            // ExactOut: calculate x1 from y1 = y0 - amountOut (normalized).
            // Saturate: a full-reserve exactOut makes ceilDiv(...) exceed the floored y0 by
            // at most 1; the true remaining value is 0, so clamp to 0 instead of underflowing.
            uint256 c = Math.ceilDiv(ctx.swap.amountOut * rateOut, RATE_ONE);
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
            if (amountIn == 0 && ctx.swap.amountOut != 0) {
                amountIn = 1;
            }

            // Dust fill (normalized output reserve rounds to 0): 1 wei of tokenIn can be worth less
            // than the output. Charge input worth at least the output value. Same gate as the drain floor.
            if (y0 == 0) {
                amountIn = Math.max(amountIn, Math.ceilDiv(ctx.swap.amountOut * rateOut, rateIn));
            }

            ctx.swap.amountIn = amountIn;
        }
    }
}
