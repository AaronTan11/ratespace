// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ===== 1inch swap-vm v1.0.2 (lib/swap-vm-v1): the live AquaSwapVMRouter's version =====
import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { SwapVM } from "@swap-vm-v1/SwapVM.sol";
import { AquaOpcodes } from "@swap-vm-v1/opcodes/AquaOpcodes.sol";
import { MakerTraitsLib } from "@swap-vm-v1/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@swap-vm-v1/libs/TakerTraits.sol";
import { MockTaker } from "@swap-vm-v1-test/mocks/MockTaker.sol";
import { ProgramBuilder, Program } from "@swap-vm-v1-test/utils/ProgramBuilder.sol";
import { dynamic } from "@swap-vm-v1-test/utils/Dynamic.sol";

// ===== 1inch swap-vm 3b3da7d (lib/swap-vm): our RateSpaceAquaRouter's version =====
import { Aqua as AquaV0 } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM as ISwapVMV0 } from "@swap-vm/interfaces/ISwapVM.sol";
import { MakerTraitsLib as MakerTraitsLibV0 } from "@swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib as TakerTraitsLibV0 } from "@swap-vm/libs/TakerTraits.sol";
import { Salt as SaltV0 } from "@swap-vm/instructions/Controls.sol";
import { MockTaker as MockTakerV0 } from "@swap-vm-test/mocks/MockTaker.sol";

import { MovingPegExtruction } from "../../src/extruction/MovingPegExtruction.sol";
import { MovingPegExtructionArgs } from "../../src/extruction/MovingPegExtructionArgs.sol";
import { MovingPegSwap } from "../../src/instructions/MovingPegSwap.sol";
import { RateSpaceAquaRouter } from "../../src/routers/RateSpaceAquaRouter.sol";

/// @notice Derives opcode indexes mechanically from v1.0.2 AquaOpcodes._opcodes() (the table AquaSwapVMRouter uses)
contract V1OpcodeIndex is AquaOpcodes {
    using ProgramBuilder for Program;

    constructor() AquaOpcodes(address(0)) { }

    function indexes() external pure returns (uint8 salt, uint8 flatFeeIn, uint8 extruction) {
        Program memory p = ProgramBuilder.init(_opcodes());
        salt = p.findOpcode(_salt);
        flatFeeIn = p.findOpcode(_flatFeeAmountInXD);
        extruction = p.findOpcode(_extruction);
    }
}

/// @notice Shared fixtures for MovingPegExtruction on the v1.0.2 AquaSwapVMRouter, and the same order on
///   our RateSpaceAquaRouter (opcode 0x59). Token / Aqua / router addresses are set by the concrete test
///   (local deployment or mainnet fork).
/// @dev The pair is wstETH (lower address = Lt, live-rate side) / WETH (greater address = Gt, rate 1e18).
abstract contract ExtructionTestBase is Test {
    // ===== Owner-approved settings (LOCKED) =====
    uint256 internal constant WIDTH = 50e27;
    uint16 internal constant BAND = 500;
    /// @dev Owner fee 5000 on the 1e7 scale (0.05%) = 500000 on v1.0.2's flat-fee 1e9 scale
    uint32 internal constant FEE_1E9 = 500000;

    // ===== Fixtures (from the verified spike and test/fork/MainnetFork.t.sol) =====
    uint256 internal constant ONE = 1e18;
    uint256 internal constant DEP_WETH = 6e18;
    /// @dev wstETH stEthPerToken() at mainnet block 26047293 (MainnetFork.t.sol RATE_B)
    uint256 internal constant RATE_B = 1244787728742679575;

    /// @dev S1..S5 (amountIn, amountOut) then final Aqua (wstETH, WETH) balances, produced by
    ///   RateSpaceAquaRouter + MovingPegSwap 0x59 at RATE_B with DEP_WETH / (DEP_WETH * 1e18 / RATE_B)
    ///   deposits, WIDTH, BAND
    function _pinned() internal pure returns (uint256[12] memory) {
        return [
            uint256(100000000000000000), 80328353854321891,
            40162519808791328, 50000000000000000,
            100000000000000000, 124476258544691896,
            62234933082211362, 50000000000000000,
            2, 1,
            4829933096444737713, 5987758674537519468
        ];
    }

    uint256 internal constant MAKER_PK = 0x1234;
    address internal maker;

    address internal wst;
    address internal weth;
    Aqua internal aqua;
    ISwapVM internal router;
    MovingPegExtruction internal target;
    MockTaker internal taker;
    address internal wstProvider;

    uint8 internal opSalt;
    uint8 internal opFlatFee;
    uint8 internal opExtruction;
    uint64 internal saltNonce;

    function _fundWst(address to, uint256 amount) internal virtual;
    function _fundWeth(address to, uint256 amount) internal virtual;

    function _initV1() internal {
        maker = vm.addr(MAKER_PK);
        assertLt(uint160(wst), uint160(weth), "wstETH must be the lower address (Lt)");
        (opSalt, opFlatFee, opExtruction) = new V1OpcodeIndex().indexes();
        assertEq(opExtruction, MovingPegExtructionArgs.EXTRUCTION_OPCODE, "Extruction opcode = v1.0.2 table index");
        target = new MovingPegExtruction();
        taker = new MockTaker(aqua, SwapVM(payable(address(router))), address(this));
    }

    function _depWst(uint256 rate) internal pure returns (uint256) {
        return DEP_WETH * ONE / rate;
    }

    // ===== v1.0.2 program / order =====

    function _ins(uint8 op, bytes memory args) internal pure returns (bytes memory) {
        require(args.length <= type(uint8).max, "args > 255");
        return abi.encodePacked(op, uint8(args.length), args);
    }

    /// @dev The Extruction instruction for the standard order at `refRateWst`, via the product builder
    function _extIns(uint256 refRateWst, uint256 depWst, address provider) internal view returns (bytes memory) {
        return MovingPegExtructionArgs.build(
            address(target),
            MovingPegSwap.anchorFor(depWst, refRateWst),
            MovingPegSwap.anchorFor(DEP_WETH, ONE),
            WIDTH,
            refRateWst,
            ONE,
            provider,
            address(0),
            BAND
        );
    }

    function _programV1(bytes memory ext, bool withFee) internal returns (bytes memory) {
        bytes memory salt = _ins(opSalt, abi.encodePacked(++saltNonce));
        return withFee ? bytes.concat(_ins(opFlatFee, abi.encodePacked(FEE_1E9)), ext, salt) : bytes.concat(ext, salt);
    }

    function _orderV1(bytes memory program) internal view returns (ISwapVM.Order memory) {
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

    /// @dev Standard order: Extruction(MovingPegExtruction) [+ salt], optional flat fee in front
    function _stdOrderV1(uint256 refRateWst, uint256 depWst, address provider, bool withFee)
        internal
        returns (ISwapVM.Order memory)
    {
        return _orderV1(_programV1(_extIns(refRateWst, depWst, provider), withFee));
    }

    function _shipV1(ISwapVM.Order memory order, uint256 depWst) internal returns (bytes32 h) {
        h = router.hash(order);
        _fundWst(maker, depWst);
        _fundWeth(maker, DEP_WETH);
        vm.startPrank(maker);
        IERC20(wst).approve(address(aqua), type(uint256).max);
        IERC20(weth).approve(address(aqua), type(uint256).max);
        bytes32 sh = aqua.ship(address(router), abi.encode(order), dynamic([wst, weth]), dynamic([depWst, DEP_WETH]));
        vm.stopPrank();
        assertEq(sh, h, "strategy hash");
    }

    function _tdV1(address takerAddr, bool isExactIn, bool pushMode) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddr,
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

    function _tokens(bool wethToWst) internal view returns (address tIn, address tOut) {
        (tIn, tOut) = wethToWst ? (weth, wst) : (wst, weth);
    }

    function _fundIn(address tIn, address to, uint256 amount) internal {
        if (tIn == weth) _fundWeth(to, amount);
        else _fundWst(to, amount);
    }

    function _quoteV1(ISwapVM.Order memory order, uint256 amount, bool wethToWst, bool isExactIn)
        internal
        view
        returns (uint256 qIn, uint256 qOut)
    {
        (address tIn, address tOut) = _tokens(wethToWst);
        (qIn, qOut,) = router.quote(order, tIn, tOut, amount, _tdV1(address(taker), isExactIn, false));
    }

    /// @dev quote, then swap through the MockTaker; asserts quote == swap and exact balance deltas
    function _qsV1(string memory label, ISwapVM.Order memory order, uint256 amount, bool wethToWst, bool isExactIn)
        internal
        returns (uint256 aIn, uint256 aOut)
    {
        (uint256 qIn, uint256 qOut) = _quoteV1(order, amount, wethToWst, isExactIn);
        (address tIn, address tOut) = _tokens(wethToWst);
        _fundIn(tIn, address(taker), amount * 2 + 1e18);
        uint256[4] memory b = [
            IERC20(tIn).balanceOf(address(taker)),
            IERC20(tOut).balanceOf(address(taker)),
            IERC20(tIn).balanceOf(maker),
            IERC20(tOut).balanceOf(maker)
        ];
        (aIn, aOut) = taker.swap(order, tIn, tOut, amount, _tdV1(address(taker), isExactIn, false));
        assertEq(b[0] - IERC20(tIn).balanceOf(address(taker)), aIn, "taker tokenIn delta");
        assertEq(IERC20(tOut).balanceOf(address(taker)) - b[1], aOut, "taker tokenOut delta");
        assertEq(IERC20(tIn).balanceOf(maker) - b[2], aIn, "maker tokenIn delta");
        assertEq(b[3] - IERC20(tOut).balanceOf(maker), aOut, "maker tokenOut delta");
        assertEq(aIn, qIn, string.concat(label, " quote==swap amountIn"));
        assertEq(aOut, qOut, string.concat(label, " quote==swap amountOut"));
        emit log_named_uint(string.concat(label, " amountIn"), aIn);
        emit log_named_uint(string.concat(label, " amountOut"), aOut);
    }

    /// @dev The 5-swap sequence S1..S5 on a freshly shipped standard order; returns the 12 values in _pinned() order
    function _sequenceV1(uint256 refRateWst, address provider) internal returns (uint256[12] memory r) {
        uint256 depWst = _depWst(refRateWst);
        ISwapVM.Order memory order = _stdOrderV1(refRateWst, depWst, provider, false);
        bytes32 h = _shipV1(order, depWst);
        (r[0], r[1]) = _qsV1("v1 S1 WETH->wstETH exactIn 0.1", order, 0.1e18, true, true);
        (r[2], r[3]) = _qsV1("v1 S2 wstETH->WETH exactOut 0.05", order, 0.05e18, false, false);
        (r[4], r[5]) = _qsV1("v1 S3 wstETH->WETH exactIn 0.1", order, 0.1e18, false, true);
        (r[6], r[7]) = _qsV1("v1 S4 WETH->wstETH exactOut 0.05", order, 0.05e18, true, false);
        (r[8], r[9]) = _qsV1("v1 S5 WETH->wstETH exactOut 1wei", order, 1, true, false);
        (r[10], r[11]) = aqua.safeBalances(maker, address(router), h, wst, weth);
        emit log_named_uint("v1 aqua wstETH after", r[10]);
        emit log_named_uint("v1 aqua WETH after", r[11]);
    }

    function _assertEq12(uint256[12] memory a, uint256[12] memory b, string memory label) internal pure {
        for (uint256 i = 0; i < 12; i++) {
            assertEq(a[i], b[i], string.concat(label, " [", vm.toString(i), "]"));
        }
    }

    // ===== Our RateSpaceAquaRouter (swap-vm 3b3da7d, MovingPegSwap opcode 0x59) on the same Aqua =====

    RateSpaceAquaRouter internal ours;
    MockTakerV0 internal oursTaker;

    function _initOurs() internal {
        ours = new RateSpaceAquaRouter(address(aqua), weth, address(this), "SwapVM", "1.0.0");
        oursTaker = new MockTakerV0(AquaV0(address(aqua)), ours, address(this));
    }

    function _orderOurs(uint256 refRateWst, uint256 depWst, address provider) internal returns (ISwapVMV0.Order memory) {
        bytes memory program = bytes.concat(
            MovingPegSwap.build(
                MovingPegSwap.anchorFor(depWst, refRateWst),
                MovingPegSwap.anchorFor(DEP_WETH, ONE),
                WIDTH,
                refRateWst,
                ONE,
                provider,
                address(0),
                BAND
            ),
            SaltV0.build(++saltNonce)
        );
        return MakerTraitsLibV0.build(MakerTraitsLibV0.Args({
            maker: maker,
            tokenA: wst,
            tokenB: weth,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            receiver: address(0),
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

    function _tdOurs(bool wethToWst, bool isExactIn) internal view returns (bytes memory) {
        return TakerTraitsLibV0.build(TakerTraitsLibV0.Args({
            taker: address(oursTaker),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: !wethToWst,
            allowPartialFill: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: true,
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

    function _qsOurs(string memory label, ISwapVMV0.Order memory order, uint256 amount, bool wethToWst, bool isExactIn)
        internal
        returns (uint256 aIn, uint256 aOut)
    {
        bytes memory td = _tdOurs(wethToWst, isExactIn);
        (uint256 qIn, uint256 qOut,) = ISwapVMV0(address(ours)).quote(order, amount, td);
        (address tIn, address tOut) = _tokens(wethToWst);
        _fundIn(tIn, address(oursTaker), amount * 2 + 1e18);
        uint256 inBefore = IERC20(tIn).balanceOf(address(oursTaker));
        uint256 outBefore = IERC20(tOut).balanceOf(address(oursTaker));
        (aIn, aOut) = oursTaker.swap(order, amount, td);
        assertEq(inBefore - IERC20(tIn).balanceOf(address(oursTaker)), aIn, "ours taker tokenIn delta");
        assertEq(IERC20(tOut).balanceOf(address(oursTaker)) - outBefore, aOut, "ours taker tokenOut delta");
        assertEq(aIn, qIn, string.concat(label, " quote==swap amountIn"));
        assertEq(aOut, qOut, string.concat(label, " quote==swap amountOut"));
        emit log_named_uint(string.concat(label, " amountIn"), aIn);
        emit log_named_uint(string.concat(label, " amountOut"), aOut);
    }

    function _sequenceOurs(uint256 refRateWst, address provider) internal returns (uint256[12] memory r) {
        uint256 depWst = _depWst(refRateWst);
        ISwapVMV0.Order memory order = _orderOurs(refRateWst, depWst, provider);
        bytes32 h = ours.hash(order);
        _fundWst(maker, depWst);
        _fundWeth(maker, DEP_WETH);
        vm.startPrank(maker);
        IERC20(wst).approve(address(aqua), type(uint256).max);
        IERC20(weth).approve(address(aqua), type(uint256).max);
        bytes32 sh = aqua.ship(address(ours), abi.encode(order), dynamic([wst, weth]), dynamic([depWst, DEP_WETH]));
        vm.stopPrank();
        assertEq(sh, h, "ours strategy hash");
        (r[0], r[1]) = _qsOurs("ours S1 WETH->wstETH exactIn 0.1", order, 0.1e18, true, true);
        (r[2], r[3]) = _qsOurs("ours S2 wstETH->WETH exactOut 0.05", order, 0.05e18, false, false);
        (r[4], r[5]) = _qsOurs("ours S3 wstETH->WETH exactIn 0.1", order, 0.1e18, false, true);
        (r[6], r[7]) = _qsOurs("ours S4 WETH->wstETH exactOut 0.05", order, 0.05e18, true, false);
        (r[8], r[9]) = _qsOurs("ours S5 WETH->wstETH exactOut 1wei", order, 1, true, false);
        (r[10], r[11]) = aqua.safeBalances(maker, address(ours), h, wst, weth);
        emit log_named_uint("ours aqua wstETH after", r[10]);
        emit log_named_uint("ours aqua WETH after", r[11]);
    }
}
