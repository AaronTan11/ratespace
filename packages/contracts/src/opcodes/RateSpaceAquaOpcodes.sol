// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Context } from "@swap-vm/libs/VM.sol";
import { Opcode } from "@swap-vm/libs/OpcodeList.sol";
import { AquaOpcodes } from "@swap-vm/opcodes/AquaOpcodes.sol";
import { MovingPegSwap } from "../instructions/MovingPegSwap.sol";

/// @title RateSpaceAquaOpcodes
/// @notice Aqua opcode set extended with the MovingPegSwap instruction
contract RateSpaceAquaOpcodes is AquaOpcodes {
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual override {
        if (opcode == MovingPegSwap.opcode.asU8()) MovingPegSwap.exec(ctx, args);
        else super._runOpcode(ctx, opcode, args);
    }
}
