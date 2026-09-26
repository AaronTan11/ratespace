// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@swap-vm-v1/routers/AquaSwapVMRouter.sol";
import { TakerTraitsLib } from "@swap-vm-v1/libs/TakerTraits.sol";
import { SwapQuery, SwapRegisters } from "@swap-vm-v1/libs/VM.sol";
import { dynamic } from "@swap-vm-v1-test/utils/Dynamic.sol";

import { ISwapVM as ISwapVMV0 } from "@swap-vm/interfaces/ISwapVM.sol";
import { MakerTraitsLib as MakerTraitsLibV0 } from "@swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib as TakerTraitsLibV0 } from "@swap-vm/libs/TakerTraits.sol";
import { Salt as SaltV0 } from "@swap-vm/instructions/Controls.sol";
import { Context } from "@swap-vm/libs/VM.sol";

import { MovingPegExtructionArgs } from "../../src/extruction/MovingPegExtructionArgs.sol";
import { MovingPegSwap } from "../../src/instructions/MovingPegSwap.sol";

import { MockRateProvider } from "../mocks/MockRateProvider.sol";

import { ExtructionTestBase } from "./ExtructionTestBase.sol";

/// @notice Direct MovingPegSwap (0x59) exec on caller-chosen registers (same shape as test/MovingPegSwap.t.sol's harness)
contract Ox59ExecHarness {
    function exec(bool exactIn, address tokenIn, address tokenOut, uint256 balIn, uint256 balOut, uint256 amount, bytes calldata built)
        external
        view
        returns (uint256, uint256)
    {
        Context memory ctx;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.query.isExactIn = exactIn;
        ctx.swap.balanceIn = balIn;
        ctx.swap.balanceOut = balOut;
        if (exactIn) ctx.swap.amountIn = amount;
        else ctx.swap.amountOut = amount;
        MovingPegSwap.exec(ctx, built[2:]);
        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }
}

/// @notice LOCAL (no network): MovingPegExtruction's edge branches replayed THROUGH AquaSwapVMRouter v1.0.2
///   (Extruction target), each differential against the same order on our RateSpaceAquaRouter (0x59) on the
///   same Aqua: the drain 1-wei min-in, the exactOut dust value floor, and the exactOut > reserve clamp.
/// @dev Tokens: `wst` = Lt (input side, fixed rate, no provider), `weth` = Gt (output side, live rate from
///   `provider`). Every trade here is Lt -> Gt (`wethToWst = false`).
contract MovingPegExtructionEdgesTest is ExtructionTestBase {
    MockRateProvider internal provider;
    Ox59ExecHarness internal h0x59;

    function setUp() public {
        TokenMock a = new TokenMock("Lt-token", "LT");
        TokenMock b = new TokenMock("Gt-token", "GT");
        (wst, weth) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        aqua = new Aqua();
        router = ISwapVM(address(new AquaSwapVMRouter(address(aqua), weth, address(this), "1inch SwapVM v1.0", "1.0.2")));
        provider = new MockRateProvider();
        _initV1();
        _initOurs();
        h0x59 = new Ox59ExecHarness();
        // Low input rates make dust fills expensive in tokenIn: pre-fund both takers generously
        _fundWst(address(taker), 1e27);
        _fundWst(address(oursTaker), 1e27);
    }

    function _fundWst(address to, uint256 amount) internal override {
        TokenMock(wst).mint(to, amount);
    }

    function _fundWeth(address to, uint256 amount) internal override {
        TokenMock(weth).mint(to, amount);
    }

    struct Pair {
        ISwapVM.Order v1;
        ISwapVMV0.Order ours;
        bytes32 hV1;
        bytes32 hOurs;
        bytes built; // MovingPegSwap.build(...) (0x59 instruction), for the direct harness
    }

    /// @dev Ships the SAME MovingPeg args (anchors xA / yA, rates rLt fixed and rGt live via `provider`) on both
    ///   routers, each with deposits (depLt, depGt)
    function _pair(uint256 xA, uint256 yA, uint256 rLt, uint256 rGt, uint256 depLt, uint256 depGt)
        internal
        returns (Pair memory p)
    {
        provider.setRate(rGt);
        p.built = MovingPegSwap.build(xA, yA, WIDTH, rLt, rGt, address(0), address(provider), BAND);
        p.v1 = _orderV1(_programV1(
            MovingPegExtructionArgs.build(address(target), xA, yA, WIDTH, rLt, rGt, address(0), address(provider), BAND), false
        ));
        p.ours = MakerTraitsLibV0.build(MakerTraitsLibV0.Args({
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
            program: bytes.concat(p.built, SaltV0.build(++saltNonce))
        }));
        _fundWst(maker, 2 * depLt);
        _fundWeth(maker, 2 * depGt);
        vm.startPrank(maker);
        IERC20(wst).approve(address(aqua), type(uint256).max);
        IERC20(weth).approve(address(aqua), type(uint256).max);
        p.hV1 = aqua.ship(address(router), abi.encode(p.v1), dynamic([wst, weth]), dynamic([depLt, depGt]));
        p.hOurs = aqua.ship(address(ours), abi.encode(p.ours), dynamic([wst, weth]), dynamic([depLt, depGt]));
        vm.stopPrank();
        assertEq(p.hV1, router.hash(p.v1), "v1 strategy hash");
        assertEq(p.hOurs, ours.hash(p.ours), "ours strategy hash");
    }

    function _balOut(Pair memory p) internal view returns (uint256 v1Out, uint256 oursOut) {
        (, v1Out) = aqua.safeBalances(maker, address(router), p.hV1, wst, weth);
        (, oursOut) = aqua.safeBalances(maker, address(ours), p.hOurs, wst, weth);
    }

    /// @dev The same Lt -> Gt trade on both routers (quote == swap and balance deltas asserted inside); the two
    ///   routers must agree to the wei
    function _both(string memory label, Pair memory p, uint256 amount, bool isExactIn)
        internal
        returns (uint256 aIn, uint256 aOut)
    {
        (uint256 oIn, uint256 oOut) = _qsOurs(string.concat(label, " [0x59]"), p.ours, amount, false, isExactIn);
        (aIn, aOut) = _qsV1(string.concat(label, " [v1.0.2+Extruction]"), p.v1, amount, false, isExactIn);
        assertEq(aIn, oIn, string.concat(label, " amountIn: Extruction == 0x59"));
        assertEq(aOut, oOut, string.concat(label, " amountOut: Extruction == 0x59"));
    }

    // ===== (1) Drain: 1-wei min-in (test/MovingPegSwap.t.sol test_M_DrainDust_MinAmountIn) =====

    /// @notice Pool (7e18 in, bo out) at rIn 1e18 / rOut 0.3e18. Both anchor regimes of the 0x59 test:
    ///   - anchors 6e18 / 6e18, bo = 1..3: normalized y0 == 0 (the value floor also applies);
    ///   - anchors 6e18 / 1e30, bo = 4, 16, 28, 40: y0 > 0, so ONLY the 1-wei min-in prevents a zero-in drain.
    ///   v1.0.2 exactIn requires amountIn == the taker amount, so the drain is requested at exactly 1 wei (the
    ///   0x59 test's 1e18 request drains at the same 1 wei: the drain branch does not read amountIn beyond x1).
    function test_Edges_DrainDust_MinAmountIn() public {
        for (uint256 bo = 1; bo <= 3; bo++) {
            Pair memory p = _pair(6e18, 6e18, ONE, 0.3e18, 7e18, bo);
            (uint256 hIn, uint256 hOut) = h0x59.exec(true, wst, weth, 7e18, bo, 1e18, p.built);
            assertEq(hIn, 1, "0x59 harness (1e18 request): dust drain in = 1");
            assertEq(hOut, bo, "0x59 harness: dust drain out = bo");
            (uint256 aIn, uint256 aOut) = _both(string.concat("dust drain bo=", vm.toString(bo)), p, 1, true);
            assertEq(aIn, 1, "dust drain must charge exactly 1 wei");
            assertEq(aOut, bo, "dust drain must yield the full reserve");
        }
        for (uint256 bo = 4; bo <= 40; bo += 12) {
            Pair memory p = _pair(6e18, 1e30, ONE, 0.3e18, 7e18, bo);
            assertGt(bo * 0.3e18 / ONE, 0, "normalized output nonzero: value floor does not apply");
            (uint256 hIn, uint256 hOut) = h0x59.exec(true, wst, weth, 7e18, bo, 1e18, p.built);
            assertEq(hIn, 1, "0x59 harness (1e18 request): non-dust drain in = 1");
            assertEq(hOut, bo, "0x59 harness: non-dust drain out = bo");
            (uint256 aIn, uint256 aOut) = _both(string.concat("non-dust drain bo=", vm.toString(bo)), p, 1, true);
            assertEq(aIn, 1, "non-dust-normalized drain must charge exactly 1 wei (min-in)");
            assertEq(aOut, bo, "non-dust drain must yield the full reserve");
        }
    }

    // ===== (2) exactOut dust value floor (test_M_DustValueFloor, test_M_DustValueFloor_MultiWei) =====

    /// @dev Value-balanced pool at (rIn, rOut): dLt = 6e18 * 1e18 / rIn, dGt = 6e18 * 1e18 / rOut + 5; reduce the
    ///   output reserve to k wei by an exactOut of dGt - k (both routers), then exactOut j wei for j = 1..k
    function _dustCase(uint256 rIn, uint256 rOut, uint256 k, uint256[5] memory expIn) internal {
        uint256 dLt = 6e18 * ONE / rIn;
        uint256 dGt = 6e18 * ONE / rOut + 5;
        Pair memory p = _pair(MovingPegSwap.anchorFor(dLt, rIn), MovingPegSwap.anchorFor(dGt, rOut), rIn, rOut, dLt, dGt);
        string memory tag = string.concat("rIn=", vm.toString(rIn), " rOut=", vm.toString(rOut), " k=", vm.toString(k));
        _both(string.concat(tag, " reduce"), p, dGt - k, false);
        (uint256 b1, uint256 b0) = _balOut(p);
        assertEq(b1, k, "v1 output reserve = k wei");
        assertEq(b0, k, "0x59 output reserve = k wei");
        assertEq(k * rOut / ONE, 0, "normalized output reserve rounds to 0 (dust)");
        for (uint256 j = 1; j <= k; j++) {
            uint256 snap = vm.snapshotState();
            (uint256 aIn, uint256 aOut) = _both(string.concat(tag, " exactOut j=", vm.toString(j)), p, j, false);
            assertEq(aOut, j, "dust exactOut delivers j wei");
            assertEq(aIn, Math.ceilDiv(j * rOut, rIn), "dust exactOut costs ceilDiv(j * rOut, rIn)");
            assertEq(aIn, expIn[j - 1], "dust exactOut amountIn pinned");
            assertGe(aIn * rIn, j * rOut, "value in >= value out");
            vm.revertToState(snap);
        }
    }

    /// @notice test_M_DustValueFloor (a): rOut 0.999e18, rIn in {0.05, 0.3, 0.9}e18, 1-wei reserve, exactOut 1
    function test_Edges_DustValueFloor_ExactOut() public {
        _dustCase(0.05e18, 0.999e18, 1, [uint256(20), 0, 0, 0, 0]);
        _dustCase(0.3e18, 0.999e18, 1, [uint256(4), 0, 0, 0, 0]);
        _dustCase(0.9e18, 0.999e18, 1, [uint256(2), 0, 0, 0, 0]);
    }

    /// @notice test_M_DustValueFloor_MultiWei / _PartialExactOut: rIn = rOut = 0.05e18, k = 1..5 wei reserve,
    ///   exactOut j <= k costs ceilDiv(j * rOut, rIn) = j
    function test_Edges_DustValueFloor_MultiWei() public {
        for (uint256 k = 1; k <= 5; k++) {
            _dustCase(0.05e18, 0.05e18, k, [uint256(1), 2, 3, 4, 5]);
        }
    }

    // ===== (3) exactOut larger than the reserve: clamped to the reserve =====

    function _extCall(uint256 balIn, uint256 balOut, uint256 amountOut, bytes memory built)
        external
        view
        returns (uint256, uint256)
    {
        SwapQuery memory q;
        q.tokenIn = wst;
        q.tokenOut = weth;
        q.isExactIn = false;
        SwapRegisters memory s;
        s.balanceIn = balIn;
        s.balanceOut = balOut;
        s.amountOut = amountOut;
        bytes memory args = new bytes(built.length - 2);
        for (uint256 i = 0; i < args.length; i++) args[i] = built[i + 2];
        (,, SwapRegisters memory r) = target.extruction(false, 0, q, s, args, "");
        return (r.amountIn, r.amountOut);
    }

    /// @notice Pool 6e18 Lt / 5e18 Gt at rIn 1e18, rOut 1.2e18. An exactOut of reserve + d (d = 1, 1e18):
    ///   (a) at the instruction, MovingPegExtruction clamps amountOut to the reserve and prices the full drain,
    ///       exactly as the 0x59 instruction does;
    ///   (b) through v1.0.2 the clamped fill (amountOut == reserve != taker amount) is refused by
    ///       TakerTraits.validate in quote AND swap with TakerTraitsTakerAmountOutMismatch(reserve + d, reserve);
    ///       the 0x59 router refuses it with the same error (swap-vm 3b3da7d TakerTraitsLib);
    ///   (c) the exactOut of exactly the reserve fills on both routers, equal to the clamped price in (a).
    /// @dev Measured (this test's first run): full drain of 5e18 Gt at rOut 1.2e18 from the 6e18 / 5e18 pool
    uint256 internal constant FULL_RESERVE_IN = 6069801516926199140;

    function test_Edges_ExactOutAboveReserve_Clamped() public {
        uint256 dLt = 6e18;
        uint256 dGt = 5e18;
        uint256 rOut = 1.2e18;
        Pair memory p = _pair(MovingPegSwap.anchorFor(dLt, ONE), MovingPegSwap.anchorFor(dGt, rOut), ONE, rOut, dLt, dGt);

        uint256[2] memory extra = [uint256(1), 1e18];
        uint256 fullIn;
        for (uint256 i = 0; i < 2; i++) {
            uint256 req = dGt + extra[i];
            (uint256 hIn, uint256 hOut) = h0x59.exec(false, wst, weth, dLt, dGt, req, p.built);
            (uint256 eIn, uint256 eOut) = this._extCall(dLt, dGt, req, p.built);
            emit log_named_uint(string.concat("clamp d=", vm.toString(extra[i]), " Extruction amountIn"), eIn);
            assertEq(hOut, dGt, "0x59 instruction: amountOut clamped to the reserve");
            assertEq(eOut, dGt, "Extruction: amountOut clamped to the reserve");
            assertEq(eIn, hIn, "Extruction amountIn == 0x59 amountIn (clamped)");
            if (i == 0) fullIn = eIn;
            assertEq(eIn, fullIn, "clamped price independent of the excess");
            assertEq(eIn, FULL_RESERVE_IN, "clamped price pinned");

            bytes memory td = _tdV1(address(taker), false, false);
            bytes memory mismatch = abi.encodeWithSelector(TakerTraitsLib.TakerTraitsTakerAmountOutMismatch.selector, req, dGt);
            vm.expectRevert(mismatch);
            router.quote(p.v1, wst, weth, req, td);
            vm.expectRevert(mismatch);
            taker.swap(p.v1, wst, weth, req, td);
            bytes memory tdOurs = _tdOurs(false, false);
            vm.expectRevert(abi.encodeWithSelector(TakerTraitsLibV0.TakerTraitsTakerAmountOutMismatch.selector, req, dGt));
            oursTaker.swap(p.ours, req, tdOurs);
        }

        (uint256 aIn, uint256 aOut) = _both("full-reserve exactOut", p, dGt, false);
        assertEq(aOut, dGt, "full-reserve exactOut delivers the reserve");
        assertEq(aIn, fullIn, "full-reserve price == clamped price");
        (uint256 b1, uint256 b0) = _balOut(p);
        assertEq(b1, 0, "v1 output reserve drained");
        assertEq(b0, 0, "0x59 output reserve drained");
    }
}
