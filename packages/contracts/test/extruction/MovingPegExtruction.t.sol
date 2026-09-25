// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@swap-vm-v1/routers/AquaSwapVMRouter.sol";

import { MovingPegExtruction } from "../../src/extruction/MovingPegExtruction.sol";
import { MovingPegExtructionArgs } from "../../src/extruction/MovingPegExtructionArgs.sol";
import { MovingPegSwap } from "../../src/instructions/MovingPegSwap.sol";
import { MockRateProvider } from "../mocks/MockRateProvider.sol";

import { ExtructionTestBase } from "./ExtructionTestBase.sol";

/// @dev Exposes the library builders so their reverts can be asserted with vm.expectRevert
contract ExtructionArgsHarness {
    function buildExtruction(
        address target,
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 refRateLt,
        uint256 refRateGt,
        address providerLt,
        address providerGt,
        uint16 maxDeviationBps
    ) external pure returns (bytes memory) {
        return MovingPegExtructionArgs.build(target, x0, y0, linearWidth, refRateLt, refRateGt, providerLt, providerGt, maxDeviationBps);
    }

    function buildMovingPeg(
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 refRateLt,
        uint256 refRateGt,
        address providerLt,
        address providerGt,
        uint16 maxDeviationBps
    ) external pure returns (bytes memory) {
        return MovingPegSwap.build(x0, y0, linearWidth, refRateLt, refRateGt, providerLt, providerGt, maxDeviationBps);
    }
}

/// @notice LOCAL (no network): MovingPegExtruction on an AquaSwapVMRouter v1.0.2 + Aqua 0.1.0 built from
///   lib/swap-vm-v1, with mock tokens and a mock rate provider fixed at RATE_B.
contract MovingPegExtructionTest is ExtructionTestBase {
    MockRateProvider internal mockProvider;

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
    }

    function _fundWst(address to, uint256 amount) internal override {
        TokenMock(wst).mint(to, amount);
    }

    function _fundWeth(address to, uint256 amount) internal override {
        TokenMock(weth).mint(to, amount);
    }

    // ===== Encoding =====

    function test_OpcodeIndexesFromV102Table() public view {
        assertEq(opExtruction, 0x20, "Extruction index");
        assertEq(opExtruction, MovingPegExtructionArgs.EXTRUCTION_OPCODE);
        assertEq(opSalt, 20, "salt index");
        assertEq(opFlatFee, 21, "flat fee index");
    }

    function test_ArgsTailEqualsMovingPegSwapBuild() public {
        ExtructionArgsHarness h = new ExtructionArgsHarness();
        address tgt = address(0xE11);
        address prov = address(0xBEEF);
        uint256 depWst = _depWst(RATE_B);
        uint256 x0 = MovingPegSwap.anchorFor(depWst, RATE_B);
        uint256 y0 = MovingPegSwap.anchorFor(DEP_WETH, ONE);

        bytes memory ext = h.buildExtruction(tgt, x0, y0, WIDTH, RATE_B, ONE, prov, address(0), BAND);
        bytes memory mps = h.buildMovingPeg(x0, y0, WIDTH, RATE_B, ONE, prov, address(0), BAND);

        assertEq(mps.length, 2 + 202, "MovingPegSwap.build = 2-byte header + 202 args");
        assertEq(uint8(mps[0]), 0x59);
        assertEq(uint8(mps[1]), 202);
        assertEq(ext.length, 2 + 20 + 202, "extruction instruction length");
        assertEq(uint8(ext[0]), 0x20, "Extruction opcode byte");
        assertEq(uint8(ext[1]), 222, "args length byte = 20 + 202");

        bytes memory tgtBytes = new bytes(20);
        for (uint256 i = 0; i < 20; i++) tgtBytes[i] = ext[2 + i];
        assertEq(tgtBytes, abi.encodePacked(tgt), "20-byte target");

        bytes memory tail = new bytes(202);
        bytes memory mpsArgs = new bytes(202);
        for (uint256 i = 0; i < 202; i++) {
            tail[i] = ext[22 + i];
            mpsArgs[i] = mps[2 + i];
        }
        assertEq(tail, mpsArgs, "202-byte tail == MovingPegSwap.build args");
        assertEq(
            tail,
            abi.encodePacked(x0, y0, WIDTH, RATE_B, ONE, prov, address(0), BAND),
            "202-byte tail == independent abi.encodePacked"
        );
    }

    function test_ArgsBuildRevertsLikeMovingPegSwapBuild() public {
        ExtructionArgsHarness h = new ExtructionArgsHarness();
        address tgt = address(0xE11);

        bytes memory e1 = abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidInitialBalances.selector, uint256(0), uint256(1));
        vm.expectRevert(e1);
        h.buildExtruction(tgt, 0, 1, WIDTH, RATE_B, ONE, address(0), address(0), BAND);
        vm.expectRevert(e1);
        h.buildMovingPeg(0, 1, WIDTH, RATE_B, ONE, address(0), address(0), BAND);

        bytes memory e2 = abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidRefRates.selector, RATE_B, uint256(0));
        vm.expectRevert(e2);
        h.buildExtruction(tgt, 1, 1, WIDTH, RATE_B, 0, address(0), address(0), BAND);
        vm.expectRevert(e2);
        h.buildMovingPeg(1, 1, WIDTH, RATE_B, 0, address(0), address(0), BAND);

        bytes memory e3 = abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidMaxDeviation.selector, uint256(1001));
        vm.expectRevert(e3);
        h.buildExtruction(tgt, 1, 1, WIDTH, RATE_B, ONE, address(0), address(0), 1001);
        vm.expectRevert(e3);
        h.buildMovingPeg(1, 1, WIDTH, RATE_B, ONE, address(0), address(0), 1001);

        bytes memory e4 = abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidMaxDeviation.selector, uint256(0));
        vm.expectRevert(e4);
        h.buildExtruction(tgt, 1, 1, WIDTH, RATE_B, ONE, address(0), address(0), 0);
        vm.expectRevert(e4);
        h.buildMovingPeg(1, 1, WIDTH, RATE_B, ONE, address(0), address(0), 0);
    }

    function test_ErrorSelectorsMatchMovingPegSwap() public pure {
        assertEq(MovingPegExtruction.MovingPegSwapInvalidInitialBalances.selector, MovingPegSwap.MovingPegSwapInvalidInitialBalances.selector);
        assertEq(MovingPegExtruction.MovingPegSwapInvalidLinearWidth.selector, MovingPegSwap.MovingPegSwapInvalidLinearWidth.selector);
        assertEq(MovingPegExtruction.MovingPegSwapInvalidRefRates.selector, MovingPegSwap.MovingPegSwapInvalidRefRates.selector);
        assertEq(MovingPegExtruction.MovingPegSwapInvalidMaxDeviation.selector, MovingPegSwap.MovingPegSwapInvalidMaxDeviation.selector);
        assertEq(MovingPegExtruction.MovingPegSwapZeroRate.selector, MovingPegSwap.MovingPegSwapZeroRate.selector);
        assertEq(MovingPegExtruction.MovingPegSwapRateOutOfBand.selector, MovingPegSwap.MovingPegSwapRateOutOfBand.selector);
    }

    // ===== The 5-swap sequence, pinned to the wei =====

    function test_Sequence_PinnedWei() public {
        uint256[12] memory r = _sequenceV1(RATE_B, wstProvider);
        _assertEq12(r, _pinned(), "v1.0.2 router + MovingPegExtruction vs pinned");
    }

    function test_RouterCallsTargetInSwap() public {
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory order = _stdOrderV1(RATE_B, depWst, wstProvider, false);
        _shipV1(order, depWst);
        _fundWeth(address(taker), 1e18);
        vm.expectCall(address(target), abi.encodePacked(MovingPegExtruction.extruction.selector));
        (, uint256 aOut) = taker.swap(order, weth, wst, 0.01e18, _tdV1(address(taker), true, false));
        assertGt(aOut, 0);
    }

    // ===== Guards: reverts with our selectors in BOTH quote and swap =====

    function _expectGuard(ISwapVM.Order memory order, bytes memory err) internal {
        bytes memory td = _tdV1(address(taker), true, false);
        vm.expectRevert(err);
        router.quote(order, weth, wst, 0.1e18, td);
        _fundWeth(address(taker), 1e18);
        vm.expectRevert(err);
        taker.swap(order, weth, wst, 0.1e18, td);
    }

    function test_Guard_RateOutOfBand() public {
        uint256 farRef = RATE_B * 9 / 10;
        uint256 depWst = _depWst(farRef);
        ISwapVM.Order memory order = _stdOrderV1(farRef, depWst, wstProvider, false);
        _shipV1(order, depWst);
        _expectGuard(order, abi.encodeWithSelector(
            MovingPegExtruction.MovingPegSwapRateOutOfBand.selector, wstProvider, RATE_B, farRef, uint256(BAND)
        ));
    }

    /// @dev Order bytes need not come from build(): a hand-encoded band of 1001 bps is rejected at exec time
    function test_Guard_BandCapAtExec() public {
        uint256 depWst = _depWst(RATE_B);
        bytes memory raw = abi.encodePacked(
            MovingPegSwap.anchorFor(depWst, RATE_B), MovingPegSwap.anchorFor(DEP_WETH, ONE), WIDTH, RATE_B, ONE,
            wstProvider, address(0), uint16(1001)
        );
        ISwapVM.Order memory order = _orderV1(_programV1(_ins(opExtruction, abi.encodePacked(address(target), raw)), false));
        _shipV1(order, depWst);
        _expectGuard(order, abi.encodeWithSelector(MovingPegExtruction.MovingPegSwapInvalidMaxDeviation.selector, uint256(1001)));
    }

    function test_Guard_ZeroRate() public {
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory order = _stdOrderV1(RATE_B, depWst, wstProvider, false);
        _shipV1(order, depWst);
        mockProvider.setRate(0);
        _expectGuard(order, abi.encodeWithSelector(MovingPegExtruction.MovingPegSwapZeroRate.selector, wstProvider));
    }

    // ===== No taker gate: an arbitrary EOA fills directly =====

    function test_ArbitraryEoaTaker() public {
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory order = _stdOrderV1(RATE_B, depWst, wstProvider, false);
        _shipV1(order, depWst);

        address eoa = vm.addr(uint256(keccak256("random-taker-eoa")));
        assertEq(eoa.code.length, 0, "EOA has no code");
        _fundWeth(eoa, 1e18);
        (uint256 qIn, uint256 qOut) = _quoteV1(order, 0.1e18, true, true);
        uint256 wethBefore = IERC20(weth).balanceOf(eoa);
        vm.startPrank(eoa, eoa);
        IERC20(weth).approve(address(router), type(uint256).max);
        (uint256 aIn, uint256 aOut,) = router.swap(order, weth, wst, 0.1e18, _tdV1(eoa, true, true));
        vm.stopPrank();
        assertEq(aIn, qIn, "EOA amountIn == quote");
        assertEq(aOut, qOut, "EOA amountOut == quote");
        assertEq(aOut, _pinned()[1], "EOA fill = pinned S1 out");
        assertEq(wethBefore - IERC20(weth).balanceOf(eoa), aIn);
        assertEq(IERC20(wst).balanceOf(eoa), aOut);
    }
}
