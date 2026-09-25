// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { PeggedSwapMath } from "@swap-vm/libs/PeggedSwapMath.sol";

import { MovingPegSwap } from "../instructions/MovingPegSwap.sol";

/// @notice Builds the Extruction instruction that points 1inch's AquaSwapVMRouter v1.0.2 at a MovingPegExtruction target
/// @dev Wire format (v1.0.2 program encoding is [opcode u8][argsLength u8][args]):
///   [EXTRUCTION_OPCODE][ARGS_LENGTH][address target (20)][MovingPegSwap args (202)]
///   The 202-byte tail is byte-identical to MovingPegSwap.build(...) without its 2-byte [0x59][len] header.
/// @dev Validation mirrors MovingPegSwap.build(...) and reverts with the same errors.
library MovingPegExtructionArgs {
    /// @dev Index of Extruction._extruction in v1.0.2 AquaOpcodes._opcodes() (the table AquaSwapVMRouter uses)
    uint8 internal constant EXTRUCTION_OPCODE = 0x20;
    /// @dev MovingPegSwap args: 5 x uint256 + 2 x address + uint16
    uint256 internal constant MOVING_PEG_ARGS_LENGTH = 32 + 32 + 32 + 32 + 32 + 20 + 20 + 2;
    /// @dev Extruction args: 20-byte target + MovingPegSwap args
    uint256 internal constant ARGS_LENGTH = 20 + MOVING_PEG_ARGS_LENGTH;

    /// @param target MovingPegExtruction contract the router calls
    /// @dev All other params are exactly MovingPegSwap.build's
    function build(
        address target,
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 refRateLt,
        uint256 refRateGt,
        address providerLt,
        address providerGt,
        uint16 maxDeviationBps
    ) internal pure returns (bytes memory) {
        require(x0 > 0 && y0 > 0, MovingPegSwap.MovingPegSwapInvalidInitialBalances(x0, y0));
        require(linearWidth <= PeggedSwapMath.MAX_LINEAR_WIDTH, MovingPegSwap.MovingPegSwapInvalidLinearWidth(linearWidth));
        require(refRateLt > 0 && refRateGt > 0, MovingPegSwap.MovingPegSwapInvalidRefRates(refRateLt, refRateGt));
        require(
            maxDeviationBps > 0 && maxDeviationBps <= MovingPegSwap.MAX_DEVIATION_BPS_CAP,
            MovingPegSwap.MovingPegSwapInvalidMaxDeviation(maxDeviationBps)
        );

        return abi.encodePacked(
            EXTRUCTION_OPCODE,
            uint8(ARGS_LENGTH),
            target,
            x0,
            y0,
            linearWidth,
            refRateLt,
            refRateGt,
            providerLt,
            providerGt,
            maxDeviationBps
        );
    }
}
