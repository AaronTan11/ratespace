// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@swap-vm-v1/routers/AquaSwapVMRouter.sol";
import { dynamic } from "@swap-vm-v1-test/utils/Dynamic.sol";
import { ISwapVM as ISwapVMV0 } from "@swap-vm/interfaces/ISwapVM.sol";
import { MakerTraitsLib as MakerTraitsLibV0 } from "@swap-vm/libs/MakerTraits.sol";
import { Salt as SaltV0 } from "@swap-vm/instructions/Controls.sol";

import { MovingPegExtructionArgs } from "../../src/extruction/MovingPegExtructionArgs.sol";
import { MovingPegSwap } from "../../src/instructions/MovingPegSwap.sol";

import { MockRateProvider } from "../mocks/MockRateProvider.sol";

import { ExtructionTestBase } from "./ExtructionTestBase.sol";

/// @notice LOCAL (no network): the same order and 5-swap sequence through
///   (a) our RateSpaceAquaRouter (swap-vm 3b3da7d, MovingPegSwap opcode 0x59) and
///   (b) AquaSwapVMRouter v1.0.2 + Extruction(MovingPegExtruction),
///   both on ONE Aqua instance (as on mainnet, where both routers use the live Aqua).
///   Every amount must be equal to the wei between the two routers.
contract MovingPegExtructionEquivalenceTest is ExtructionTestBase {
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
        _initOurs();
    }

    function _fundWst(address to, uint256 amount) internal override {
        TokenMock(wst).mint(to, amount);
    }

    function _fundWeth(address to, uint256 amount) internal override {
        TokenMock(weth).mint(to, amount);
    }

    function test_Equivalence_Sequence() public {
        uint256[12] memory o = _sequenceOurs(RATE_B, wstProvider);
        uint256[12] memory v = _sequenceV1(RATE_B, wstProvider);
        _assertEq12(v, o, "v1.0.2+Extruction vs RateSpaceAquaRouter");
    }

    /// @dev The live rate steps +2% (inside the 500 bps band) with the order's refRate left at RATE_B.
    ///   Both routers must read the LIVE rate on the wstETH side in both directions (S1..S5 trade both ways).
    function test_Equivalence_SteppedRate() public {
        uint256 stepped = RATE_B * 10200 / 10000;
        mockProvider.setRate(stepped);
        emit log_named_uint("stepped live rate", stepped);
        uint256[12] memory o = _sequenceOurs(RATE_B, wstProvider);
        uint256[12] memory v = _sequenceV1(RATE_B, wstProvider);
        _assertEq12(v, o, "stepped: v1.0.2+Extruction vs RateSpaceAquaRouter");
        emit log_named_uint("S1 out, stepped", v[1]);
        emit log_named_uint("S1 out, unstepped (pinned)", _pinned()[1]);
        assertEq(_pinned()[1], 80328353854321891, "unstepped S1 out literal");
        assertTrue(v[1] != 80328353854321891, "stepped S1 out must differ from the unstepped S1 out");
    }

    // ===== Asymmetric anchors: x0 (wstETH value) ~ 2 x y0 (WETH value) =====
    // Value-imbalanced ON PURPOSE (test only): with near-equal anchors a missing Lt/Gt anchor swap is invisible.

    uint256 internal constant ASYM_WST_VALUE = 6e18;
    uint256 internal constant ASYM_WETH = 3e18;

    function _asymDepWst() internal pure returns (uint256) {
        return ASYM_WST_VALUE * ONE / RATE_B;
    }

    /// @dev MovingPegSwap args for the asymmetric order; Lt / Gt follow the CURRENT wst / weth address order
    function _asymArgs() internal view returns (
        uint256 x0, uint256 y0, uint256 rLt, uint256 rGt, address pLt, address pGt
    ) {
        uint256 aWst = MovingPegSwap.anchorFor(_asymDepWst(), RATE_B);
        uint256 aWeth = MovingPegSwap.anchorFor(ASYM_WETH, ONE);
        if (wst < weth) return (aWst, aWeth, RATE_B, ONE, wstProvider, address(0));
        return (aWeth, aWst, ONE, RATE_B, address(0), wstProvider);
    }

    function _asymOrderV1() internal returns (ISwapVM.Order memory) {
        (uint256 x0, uint256 y0, uint256 rLt, uint256 rGt, address pLt, address pGt) = _asymArgs();
        bytes memory ext = MovingPegExtructionArgs.build(address(target), x0, y0, WIDTH, rLt, rGt, pLt, pGt, BAND);
        return _orderV1(_programV1(ext, false));
    }

    function _shipAsym(address app, bytes memory encodedOrder) internal returns (bytes32 sh) {
        _fundWst(maker, _asymDepWst());
        _fundWeth(maker, ASYM_WETH);
        vm.startPrank(maker);
        IERC20(wst).approve(address(aqua), type(uint256).max);
        IERC20(weth).approve(address(aqua), type(uint256).max);
        sh = aqua.ship(app, encodedOrder, dynamic([wst, weth]), dynamic([_asymDepWst(), ASYM_WETH]));
        vm.stopPrank();
    }

    function _asymSeqV1() internal returns (uint256[12] memory r) {
        ISwapVM.Order memory order = _asymOrderV1();
        bytes32 h = _shipAsym(address(router), abi.encode(order));
        assertEq(h, router.hash(order), "asym v1 strategy hash");
        (r[0], r[1]) = _qsV1("asym v1 S1 WETH->wstETH exactIn 0.1", order, 0.1e18, true, true);
        (r[2], r[3]) = _qsV1("asym v1 S2 wstETH->WETH exactOut 0.05", order, 0.05e18, false, false);
        (r[4], r[5]) = _qsV1("asym v1 S3 wstETH->WETH exactIn 0.1", order, 0.1e18, false, true);
        (r[6], r[7]) = _qsV1("asym v1 S4 WETH->wstETH exactOut 0.05", order, 0.05e18, true, false);
        (r[8], r[9]) = _qsV1("asym v1 S5 WETH->wstETH exactOut 1wei", order, 1, true, false);
        (r[10], r[11]) = aqua.safeBalances(maker, address(router), h, wst, weth);
    }

    function _asymSeqOurs() internal returns (uint256[12] memory r) {
        (uint256 x0, uint256 y0, uint256 rLt, uint256 rGt, address pLt, address pGt) = _asymArgs();
        assertLt(uint160(wst), uint160(weth), "ours helpers assume wstETH = tokenA (Lt)");
        ISwapVMV0.Order memory order = MakerTraitsLibV0.build(MakerTraitsLibV0.Args({
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
            program: bytes.concat(MovingPegSwap.build(x0, y0, WIDTH, rLt, rGt, pLt, pGt, BAND), SaltV0.build(++saltNonce))
        }));
        bytes32 h = _shipAsym(address(ours), abi.encode(order));
        assertEq(h, ours.hash(order), "asym ours strategy hash");
        (r[0], r[1]) = _qsOurs("asym ours S1 WETH->wstETH exactIn 0.1", order, 0.1e18, true, true);
        (r[2], r[3]) = _qsOurs("asym ours S2 wstETH->WETH exactOut 0.05", order, 0.05e18, false, false);
        (r[4], r[5]) = _qsOurs("asym ours S3 wstETH->WETH exactIn 0.1", order, 0.1e18, false, true);
        (r[6], r[7]) = _qsOurs("asym ours S4 WETH->wstETH exactOut 0.05", order, 0.05e18, true, false);
        (r[8], r[9]) = _qsOurs("asym ours S5 WETH->wstETH exactOut 1wei", order, 1, true, false);
        (r[10], r[11]) = aqua.safeBalances(maker, address(ours), h, wst, weth);
    }

    /// @dev Fresh asymmetric order, one exactIn 0.1 trade each way on its own fresh order (no shared state)
    function _asymBothWaysV1(string memory tag) internal returns (uint256 outWethToWst, uint256 outWstToWeth) {
        ISwapVM.Order memory o1 = _asymOrderV1();
        _shipAsym(address(router), abi.encode(o1));
        (, outWethToWst) = _qsV1(string.concat(tag, " WETH->wstETH exactIn 0.1"), o1, 0.1e18, true, true);
        ISwapVM.Order memory o2 = _asymOrderV1();
        _shipAsym(address(router), abi.encode(o2));
        (, outWstToWeth) = _qsV1(string.concat(tag, " wstETH->WETH exactIn 0.1"), o2, 0.1e18, false, true);
    }

    function test_Equivalence_AsymmetricAnchors() public {
        (uint256 x0, uint256 y0,,,,) = _asymArgs();
        emit log_named_uint("asym x0 (wstETH anchor, Lt)", x0);
        emit log_named_uint("asym y0 (WETH anchor, Gt)", y0);
        assertGt(x0, y0 * 19 / 10, "x0 ~ 2 x y0");

        // (1) Full S1..S5 sequence (both directions): v1.0.2+Extruction == our 0x59 router, to the wei
        uint256[12] memory o = _asymSeqOurs();
        uint256[12] memory v = _asymSeqV1();
        _assertEq12(v, o, "asym: v1.0.2+Extruction vs RateSpaceAquaRouter");

        // (2) Token address order flipped: identical per-direction outputs
        (uint256 aFwd, uint256 aRev) = _asymBothWaysV1("asym wst=Lt");
        TokenMock c = new TokenMock("wstETH-like-2", "wstETH-like-2");
        TokenMock d = new TokenMock("WETH-like-2", "WETH-like-2");
        (weth, wst) = address(c) < address(d) ? (address(c), address(d)) : (address(d), address(c));
        assertGt(uint160(wst), uint160(weth), "flipped: wstETH is now the greater address (Gt)");
        emit log_named_address("flipped wstETH (Gt)", wst);
        emit log_named_address("flipped WETH (Lt)", weth);
        (uint256 bFwd, uint256 bRev) = _asymBothWaysV1("asym wst=Gt");
        assertEq(bFwd, aFwd, "flipped order: WETH->wstETH out");
        assertEq(bRev, aRev, "flipped order: wstETH->WETH out");
    }
}
