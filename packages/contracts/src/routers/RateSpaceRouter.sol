// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context } from "@swap-vm/libs/VM.sol";
import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import { SwapVM } from "@swap-vm/SwapVM.sol";
import { RateSpaceOpcodes } from "../opcodes/RateSpaceOpcodes.sol";

/// @title RateSpaceRouter
/// @notice Standard router with signature-based order execution and the RateSpace opcode set
contract RateSpaceRouter is Simulator, SwapVM, RateSpaceOpcodes {
    /// @notice Deploy router with Aqua and WETH addresses
    /// @param aqua Address of Aqua protocol for balance management
    /// @param weth Address of WETH token for unwrapping support
    /// @param owner Address of the owner of the router. Only owner can rescue funds.
    /// @param name EIP-712 domain name
    /// @param version EIP-712 domain version
    constructor(address aqua, address weth, address owner, string memory name, string memory version) SwapVM(aqua, weth, owner, name, version) { }

    /// @dev Dispatches an opcode to its handler for VM execution
    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        _runOpcode(ctx, opcode, args);
    }
}
