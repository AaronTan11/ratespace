// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { MakerTraits } from "@swap-vm-v1/libs/MakerTraits.sol";
import { AquaSwapVMRouter } from "@swap-vm-v1/routers/AquaSwapVMRouter.sol";
import { FeeArgsBuilder } from "@swap-vm-v1/instructions/Fee.sol";
import { dynamic } from "@swap-vm-v1-test/utils/Dynamic.sol";

import { MovingPegSwap } from "../../src/instructions/MovingPegSwap.sol";
import { RateSpaceOrderBuilder } from "../../src/demo/RateSpaceOrderBuilder.sol";
import { IRateSpaceOrderBuilder } from "../../src/demo/IRateSpaceOrderBuilder.sol";
import { MockRateProvider } from "../mocks/MockRateProvider.sol";

import { ExtructionTestBase } from "../extruction/ExtructionTestBase.sol";

/// @notice LOCAL (no network): the on-chain order builder against an AquaSwapVMRouter v1.0.2 + Aqua 0.1.0 built
///   from lib/swap-vm-v1, same fixtures as test/extruction/MovingPegExtruction.t.sol (DEP_WETH 6e18, RATE_B).
contract RateSpaceOrderBuilderTest is ExtructionTestBase {
    MockRateProvider internal mockProvider;
    IRateSpaceOrderBuilder internal builder;

    function setUp() public {
        TokenMock a = new TokenMock("wstETH-like", "wstETH-like");
        TokenMock b = new TokenMock("WETH-like", "WETH-like");
        (wst, weth) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));

        aqua = new Aqua();
        router = ISwapVM(address(new AquaSwapVMRouter(address(aqua), weth, address(this), "1inch SwapVM v1.0", "1.0.2")));

        mockProvider = new MockRateProvider();
        mockProvider.setRate(RATE_B);
        wstProvider = address(mockProvider);

        _initV1();
        builder = new RateSpaceOrderBuilder();
    }

    function _fundWst(address to, uint256 amount) internal override {
        TokenMock(wst).mint(to, amount);
    }

    function _fundWeth(address to, uint256 amount) internal override {
        TokenMock(weth).mint(to, amount);
    }

    // ===== Helpers =====

    function _stripHeader(bytes memory ins) internal pure returns (bytes memory out) {
        out = new bytes(ins.length - 2);
        for (uint256 i = 0; i < out.length; i++) out[i] = ins[i + 2];
    }

    /// @dev The standard order at RATE_B, built entirely through the on-chain builder
    function _builderOrder(uint256 depWst, uint32 fee, uint64 salt) internal view returns (ISwapVM.Order memory) {
        bytes memory mps = builder.buildMovingPegArgs(
            builder.anchorFor(depWst, RATE_B), builder.anchorFor(DEP_WETH, ONE), WIDTH, RATE_B, ONE, wstProvider, address(0), BAND
        );
        return builder.buildOrder(maker, builder.buildProgram(address(target), mps, fee, salt));
    }

    function _eoa(string memory seed) internal returns (address eoa) {
        eoa = vm.addr(uint256(keccak256(bytes(seed))));
        assertEq(eoa.code.length, 0, "EOA has no code");
        vm.label(eoa, seed);
    }

    /// @dev EOA taker, pushMode = true (the app's path): approve(router), quote, swap; asserts quote == swap and deltas
    function _eoaSwap(ISwapVM.Order memory order, address eoa, uint256 amountIn)
        internal
        returns (uint256 aIn, uint256 aOut)
    {
        bytes memory td = builder.buildTakerData(eoa, true, true);
        _fundWeth(eoa, 1e18);
        vm.prank(eoa, eoa);
        (uint256 qIn, uint256 qOut,) = router.quote(order, weth, wst, amountIn, td);
        uint256 wethBefore = IERC20(weth).balanceOf(eoa);
        vm.startPrank(eoa, eoa);
        IERC20(weth).approve(address(router), type(uint256).max);
        (aIn, aOut,) = router.swap(order, weth, wst, amountIn, td);
        vm.stopPrank();
        assertEq(aIn, qIn, "amountIn == quote");
        assertEq(aOut, qOut, "amountOut == quote");
        assertEq(wethBefore - IERC20(weth).balanceOf(eoa), aIn, "EOA WETH delta");
        assertEq(IERC20(wst).balanceOf(eoa), aOut, "EOA wstETH delta");
        emit log_named_uint("EOA amountIn", aIn);
        emit log_named_uint("EOA amountOut", aOut);
    }

    // ===== Opcode indexes =====

    function test_OpcodeConstantsMatchV102Table() public view {
        RateSpaceOrderBuilder b = RateSpaceOrderBuilder(address(builder));
        assertEq(b.SALT_OPCODE(), opSalt, "salt");
        assertEq(b.FLAT_FEE_AMOUNT_IN_OPCODE(), opFlatFee, "flat fee");
        assertEq(b.EXTRUCTION_OPCODE(), opExtruction, "extruction");
        assertEq(b.MOVING_PEG_ARGS_LENGTH(), 202);
    }

    // ===== buildMovingPegArgs == MovingPegSwap.build minus its 2-byte header =====

    function _assertMpsEq(
        uint256 x0, uint256 y0, uint256 w, uint256 rLt, uint256 rGt, address pLt, address pGt, uint16 band, string memory label
    ) internal view {
        bytes memory expected = _stripHeader(MovingPegSwap.build(x0, y0, w, rLt, rGt, pLt, pGt, band));
        bytes memory got = builder.buildMovingPegArgs(x0, y0, w, rLt, rGt, pLt, pGt, band);
        assertEq(got.length, 202, string.concat(label, " length"));
        assertEq(got, expected, label);
    }

    function test_MovingPegArgs_EqualsMovingPegSwapBuild() public view {
        uint256 depWst = _depWst(RATE_B);
        // 1: owner settings (band 500), provider on the Lt side only
        _assertMpsEq(
            MovingPegSwap.anchorFor(depWst, RATE_B), MovingPegSwap.anchorFor(DEP_WETH, ONE), WIDTH, RATE_B, ONE,
            address(0xBEEF), address(0), BAND, "band 500, provider Lt only"
        );
        // 2: provider on the Gt side only
        _assertMpsEq(10e18, 9e18, WIDTH, ONE, 1172468133468041111, address(0), address(0xCAFE), BAND, "band 500, provider Gt only");
        // 3: providers on both sides, band at the cap
        _assertMpsEq(
            123456789, 987654321, 0, 1104406989873418608, RATE_B, address(0x1111), address(0x2222), 1000,
            "band 1000, providers both sides"
        );
    }

    function test_MovingPegArgs_RevertsLikeMovingPegSwapBuild() public {
        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidInitialBalances.selector, uint256(0), uint256(1)));
        builder.buildMovingPegArgs(0, 1, WIDTH, RATE_B, ONE, address(0), address(0), BAND);
        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidMaxDeviation.selector, uint256(1001)));
        builder.buildMovingPegArgs(1, 1, WIDTH, RATE_B, ONE, address(0), address(0), 1001);
        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidRefRates.selector, RATE_B, uint256(0)));
        builder.buildMovingPegArgs(1, 1, WIDTH, RATE_B, 0, address(0), address(0), BAND);
    }

    // ===== buildProgram / buildOrder byte equality with the hand-built lane/extruction orders =====

    function test_Program_EqualsHandBuilt_NoFeeAndFee() public {
        uint256 depWst = _depWst(RATE_B);
        bytes memory ext = _extIns(RATE_B, depWst, wstProvider);
        bytes memory mps = builder.buildMovingPegArgs(
            MovingPegSwap.anchorFor(depWst, RATE_B), MovingPegSwap.anchorFor(DEP_WETH, ONE), WIDTH, RATE_B, ONE, wstProvider, address(0), BAND
        );
        // _programV1 pre-increments saltNonce: first call uses salt 1, second salt 2
        assertEq(builder.buildProgram(address(target), mps, 0, 1), _programV1(ext, false), "no fee, salt 1");
        assertEq(builder.buildProgram(address(target), mps, FEE_1E9, 2), _programV1(ext, true), "fee 500000, salt 2");
    }

    function test_Order_EqualsHandBuilt() public {
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory hand = _stdOrderV1(RATE_B, depWst, wstProvider, false); // salt 1
        ISwapVM.Order memory built = _builderOrder(depWst, 0, 1);
        assertEq(built.maker, hand.maker, "maker");
        assertEq(MakerTraits.unwrap(built.traits), MakerTraits.unwrap(hand.traits), "traits");
        assertEq(built.data, hand.data, "data");
        assertEq(abi.encode(built), abi.encode(hand), "abi.encode(order)");
    }

    function test_Program_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(
            RateSpaceOrderBuilder.RateSpaceOrderBuilderInvalidMovingPegArgsLength.selector, uint256(201)
        ));
        builder.buildProgram(address(target), new bytes(201), 0, 1);
        vm.expectRevert(abi.encodeWithSelector(FeeArgsBuilder.FeeBpsOutOfRange.selector, uint32(1e9 + 1)));
        builder.buildProgram(address(target), new bytes(202), 1e9 + 1, 1);
    }

    // ===== Taker data =====

    function test_TakerData_EqualsTakerTraitsBuild() public view {
        address t = address(0xA11CE);
        for (uint256 i = 0; i < 4; i++) {
            bool exactIn = i & 1 == 1;
            bool push = i & 2 == 2;
            assertEq(builder.buildTakerData(t, exactIn, push), _tdV1(t, exactIn, push), "taker data");
        }
    }

    // ===== (1) orderHash == router.hash, (2) encodeOrder == abi.encode =====

    function test_OrderHash_EqualsRouterHash() public view {
        ISwapVM.Order memory o = _builderOrder(_depWst(RATE_B), 0, 7);
        assertEq(builder.orderHash(o), router.hash(o), "orderHash == router.hash");
        ISwapVM.Order memory f = _builderOrder(_depWst(RATE_B), FEE_1E9, 8);
        assertEq(builder.orderHash(f), router.hash(f), "fee orderHash == router.hash");
    }

    function test_EncodeOrder_EqualsAbiEncode() public view {
        ISwapVM.Order memory o = _builderOrder(_depWst(RATE_B), FEE_1E9, 9);
        assertEq(builder.encodeOrder(o), abi.encode(o), "encodeOrder == abi.encode");
        assertEq(keccak256(builder.encodeOrder(o)), builder.orderHash(o), "keccak(encodeOrder) == orderHash");
    }

    // ===== (3) ship + EOA fill reproduces lane/extruction's S1 to the wei =====

    function test_ShipAndFill_EOA_S1Pinned() public {
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory order = _builderOrder(depWst, 0, 1);

        _fundWst(maker, depWst);
        _fundWeth(maker, DEP_WETH);
        vm.startPrank(maker);
        IERC20(wst).approve(address(aqua), type(uint256).max);
        IERC20(weth).approve(address(aqua), type(uint256).max);
        bytes32 sh = aqua.ship(address(router), builder.encodeOrder(order), dynamic([wst, weth]), dynamic([depWst, DEP_WETH]));
        vm.stopPrank();
        assertEq(sh, builder.orderHash(order), "Aqua strategyHash == builder.orderHash");
        assertEq(sh, router.hash(order), "Aqua strategyHash == router.hash");

        (uint256 aIn, uint256 aOut) = _eoaSwap(order, _eoa("demo-eoa-taker"), 0.1e18);
        assertEq(aIn, _pinned()[0], "S1 in");
        assertEq(aOut, _pinned()[1], "S1 out");
        assertEq(aOut, 80328353854321891, "S1 out literal");
    }

    // ===== (4) fee variant: 0.05% = 5e5 / 1e9 =====

    function test_ShipAndFill_EOA_Fee() public {
        assertEq(uint256(FEE_1E9) * 10000 / 1e9, 5, "500000 / 1e9 = 5 bps = 0.05%");
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory order = _builderOrder(depWst, FEE_1E9, 1);

        _fundWst(maker, depWst);
        _fundWeth(maker, DEP_WETH);
        vm.startPrank(maker);
        IERC20(wst).approve(address(aqua), type(uint256).max);
        IERC20(weth).approve(address(aqua), type(uint256).max);
        bytes32 sh = aqua.ship(address(router), builder.encodeOrder(order), dynamic([wst, weth]), dynamic([depWst, DEP_WETH]));
        vm.stopPrank();
        assertEq(sh, router.hash(order), "fee strategyHash == router.hash");

        (uint256 aIn, uint256 aOut) = _eoaSwap(order, _eoa("demo-eoa-taker-fee"), 0.1e18);
        assertEq(aIn, 0.1e18, "exactIn amountIn");
        assertGt(aOut, 0, "fee fill out > 0");
        assertLt(aOut, _pinned()[1], "fee fill out < no-fee S1 out");
    }
}
