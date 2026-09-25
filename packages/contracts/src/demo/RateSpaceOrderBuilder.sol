// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@swap-vm-v1/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@swap-vm-v1/libs/TakerTraits.sol";
import { ControlsArgsBuilder } from "@swap-vm-v1/instructions/Controls.sol";
import { FeeArgsBuilder } from "@swap-vm-v1/instructions/Fee.sol";

import { MovingPegExtructionArgs } from "../extruction/MovingPegExtructionArgs.sol";
import { MovingPegSwap } from "../instructions/MovingPegSwap.sol";

import { IRateSpaceOrderBuilder } from "./IRateSpaceOrderBuilder.sol";

/// @notice On-chain order builder for 1inch's AquaSwapVMRouter v1.0.2 + MovingPegExtruction.
///   The app eth_calls these functions and never encodes order bytes itself.
/// @dev Every byte comes from an upstream v1.0.2 builder (MakerTraitsLib.build, TakerTraitsLib.build,
///   ControlsArgsBuilder.buildSalt, FeeArgsBuilder.buildFlatFee) or from lane/extruction's
///   MovingPegExtructionArgs wire format. v1.0.2 instruction encoding is [opcode u8][argsLength u8][args].
contract RateSpaceOrderBuilder is IRateSpaceOrderBuilder {
    /// @dev Index of Controls._salt in v1.0.2 AquaOpcodes._opcodes() (pinned by test against the table)
    uint8 public constant SALT_OPCODE = 20;
    /// @dev Index of Fee._flatFeeAmountInXD in v1.0.2 AquaOpcodes._opcodes() (pinned by test against the table)
    uint8 public constant FLAT_FEE_AMOUNT_IN_OPCODE = 21;
    /// @dev Index of Extruction._extruction in v1.0.2 AquaOpcodes._opcodes()
    uint8 public constant EXTRUCTION_OPCODE = MovingPegExtructionArgs.EXTRUCTION_OPCODE;
    /// @dev 202 = MovingPegSwap args length (5 x uint256 + 2 x address + uint16)
    uint256 public constant MOVING_PEG_ARGS_LENGTH = MovingPegExtructionArgs.MOVING_PEG_ARGS_LENGTH;

    /// @dev Bytes before the MovingPegSwap args inside MovingPegExtructionArgs.build: [opcode][len][target 20]
    uint256 private constant _EXTRUCTION_PREFIX = 2 + 20;

    error RateSpaceOrderBuilderInvalidMovingPegArgsLength(uint256 length);

    /// @inheritdoc IRateSpaceOrderBuilder
    /// @dev Same validation (and revert errors) as MovingPegSwap.build
    function buildMovingPegArgs(
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 refRateLt,
        uint256 refRateGt,
        address providerLt,
        address providerGt,
        uint16 maxDeviationBps
    ) external pure returns (bytes memory args) {
        bytes memory ins = MovingPegExtructionArgs.build(
            address(0), x0, y0, linearWidth, refRateLt, refRateGt, providerLt, providerGt, maxDeviationBps
        );
        args = new bytes(MOVING_PEG_ARGS_LENGTH);
        for (uint256 i = 0; i < MOVING_PEG_ARGS_LENGTH; i++) {
            args[i] = ins[_EXTRUCTION_PREFIX + i];
        }
    }

    /// @inheritdoc IRateSpaceOrderBuilder
    function buildProgram(address extructionTarget, bytes calldata mpsArgs, uint32 feeBps1e9, uint64 salt)
        external
        pure
        returns (bytes memory program)
    {
        // MovingPegExtruction parses fixed offsets; any other length is not a MovingPegSwap args blob
        require(mpsArgs.length == MOVING_PEG_ARGS_LENGTH, RateSpaceOrderBuilderInvalidMovingPegArgsLength(mpsArgs.length));

        bytes memory ext = _ins(EXTRUCTION_OPCODE, abi.encodePacked(extructionTarget, mpsArgs));
        bytes memory saltIns = _ins(SALT_OPCODE, ControlsArgsBuilder.buildSalt(salt));
        program = feeBps1e9 == 0
            ? bytes.concat(ext, saltIns)
            : bytes.concat(_ins(FLAT_FEE_AMOUNT_IN_OPCODE, FeeArgsBuilder.buildFlatFee(feeBps1e9)), ext, saltIns);
    }

    /// @inheritdoc IRateSpaceOrderBuilder
    function buildOrder(address maker, bytes calldata program) external pure returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program
        }));
    }

    /// @inheritdoc IRateSpaceOrderBuilder
    function buildTakerData(address taker, bool isExactIn, bool pushMode) external pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: pushMode,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: !pushMode,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    /// @inheritdoc IRateSpaceOrderBuilder
    function encodeOrder(ISwapVM.Order calldata order) external pure returns (bytes memory) {
        return abi.encode(order);
    }

    /// @inheritdoc IRateSpaceOrderBuilder
    /// @dev Equals router.hash(order) only for Aqua orders (useAquaInsteadOfSignature = true), which is
    ///   what buildOrder produces; signature orders hash with EIP-712 on the router instead
    function orderHash(ISwapVM.Order calldata order) external pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }

    /// @inheritdoc IRateSpaceOrderBuilder
    function anchorFor(uint256 balance, uint256 rate) external pure returns (uint256) {
        return MovingPegSwap.anchorFor(balance, rate);
    }

    function _ins(uint8 opcode, bytes memory args) private pure returns (bytes memory) {
        return abi.encodePacked(opcode, uint8(args.length), args);
    }
}
