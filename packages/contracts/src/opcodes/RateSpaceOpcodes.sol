// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Context } from "@swap-vm/libs/VM.sol";
import { Opcode } from "@swap-vm/libs/OpcodeList.sol";
import { Opcodes } from "@swap-vm/opcodes/Opcodes.sol";
import { MovingPegSwap } from "../instructions/MovingPegSwap.sol";

/// @title RateSpaceOpcodes
/// @notice Full opcode set extended with the MovingPegSwap instruction
/// @dev Used by the non-Aqua DynamicBalances-based invariant harness
contract RateSpaceOpcodes is Opcodes {
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual override {
        if (opcode == MovingPegSwap.opcode.asU8()) MovingPegSwap.exec(ctx, args);
        else super._runOpcode(ctx, opcode, args);
    }
}
