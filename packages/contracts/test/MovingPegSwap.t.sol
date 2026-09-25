// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "@swap-vm/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@swap-vm/routers/AquaSwapVMRouter.sol";
import { MakerTraitsLib } from "@swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@swap-vm/libs/TakerTraits.sol";
import { PeggedSwap } from "@swap-vm/instructions/PeggedSwap.sol";
import { FeeFlatIn } from "@swap-vm/instructions/FeeFlat.sol";
import { Salt } from "@swap-vm/instructions/Controls.sol";
import { Context } from "@swap-vm/libs/VM.sol";
import { PeggedSwapMath } from "@swap-vm/libs/PeggedSwapMath.sol";

import { MockTaker } from "@swap-vm-test/mocks/MockTaker.sol";
import { dynamic } from "@swap-vm-test/utils/Dynamic.sol";

import { RateSpaceAquaRouter } from "../src/routers/RateSpaceAquaRouter.sol";
import { MovingPegSwap } from "../src/instructions/MovingPegSwap.sol";
import { MockRateProvider } from "./mocks/MockRateProvider.sol";

/// @notice Shared plumbing for the MovingPegSwap Aqua tests.
///   Roles: stETH-like (rate 1e18) and wstETH-like (live rate from MockRateProvider).
///   Demo deposit: 6e18 stETH-like + 5e18 wstETH-like, ship-time rate 1.20e18 (value-balanced).
abstract contract MovingPegSwapAquaBase is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant REF_RATE = 1.2e18;   // ship-time / reference rate (1 wstETH = 1.2 stETH)
    uint256 internal constant WORLD_RATE = 1.25e18; // "world" rate used for the demo loss numbers
    uint256 internal constant WIDTH = 50e27;        // owner-approved 2026-09-24
    uint16 internal constant MAX_DEV_BPS = 500;     // owner-approved 2026-09-24
    uint256 internal constant DEPOSIT_STETH = 6e18;
    uint256 internal constant DEPOSIT_WSTETH = 5e18;

    Aqua internal aqua = new Aqua();
    RateSpaceAquaRouter internal swapVM;
    MockRateProvider internal rateProvider;
    MockTaker internal taker;

    address internal maker;
    uint256 internal makerPK = 0x1234;

    TokenMock internal stEthLike;  // rate 1e18 side
    TokenMock internal wstEthLike; // live-rate side
    TokenMock internal tokenLt;    // lower-address token (order tokenA)
    TokenMock internal tokenGt;    // greater-address token (order tokenB)

    uint256 internal depositLt; // order tokenA deposit
    uint256 internal depositGt; // order tokenB deposit
    uint16 internal band = MAX_DEV_BPS;

    uint64 internal saltNonce;

    function _configure() internal virtual;

    function setUp() public {
        maker = vm.addr(makerPK);
        rateProvider = new MockRateProvider();
        rateProvider.setRate(REF_RATE);
        swapVM = new RateSpaceAquaRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
        taker = new MockTaker(aqua, swapVM, address(this));
        _configure();
        assertTrue(address(tokenLt) < address(tokenGt), "order tokens must be sorted");
        if (address(stEthLike) == address(tokenLt)) {
            depositLt = DEPOSIT_STETH;
            depositGt = DEPOSIT_WSTETH;
        } else {
            depositLt = DEPOSIT_WSTETH;
            depositGt = DEPOSIT_STETH;
        }
    }

    // ===== ORDER PLUMBING =====

    function _program(uint256 providerRefRate) internal returns (bytes memory) {
        bool stEthIsLt = address(stEthLike) == address(tokenLt);
        uint256 rateLt = stEthIsLt ? ONE : providerRefRate;
        uint256 rateGt = stEthIsLt ? providerRefRate : ONE;
        address providerLt = stEthIsLt ? address(0) : address(rateProvider);
        address providerGt = stEthIsLt ? address(rateProvider) : address(0);

        return bytes.concat(
            MovingPegSwap.build(
                MovingPegSwap.anchorFor(depositLt, rateLt),
                MovingPegSwap.anchorFor(depositGt, rateGt),
                WIDTH,
                rateLt,
                rateGt,
                providerLt,
                providerGt,
                band
            ),
            Salt.build(++saltNonce)
        );
    }

    /// @dev Build an order whose anchors are value-balanced at `providerRefRate` (targetValue on
    ///   each side), so the curve center sits exactly at that rate. Sets the per-order deposits.
    function _programValueBalanced(uint256 providerRefRate, uint256 targetValue) internal returns (bytes memory) {
        bool stEthIsLt = address(stEthLike) == address(tokenLt);
        uint256 rateLt = stEthIsLt ? ONE : providerRefRate;
        uint256 rateGt = stEthIsLt ? providerRefRate : ONE;
        address providerLt = stEthIsLt ? address(0) : address(rateProvider);
        address providerGt = stEthIsLt ? address(rateProvider) : address(0);
        depositLt = targetValue * ONE / rateLt;
        depositGt = targetValue * ONE / rateGt;

        return bytes.concat(
            MovingPegSwap.build(
                MovingPegSwap.anchorFor(depositLt, rateLt),
                MovingPegSwap.anchorFor(depositGt, rateGt),
                WIDTH,
                rateLt,
                rateGt,
                providerLt,
                providerGt,
                band
            ),
            Salt.build(++saltNonce)
        );
    }

    /// @dev Build an order with explicit deposits at `providerRefRate` (no value balancing).
    ///   Used by the rounding tests, which need non-round deposits/rates.
    function _programWithDeposits(uint256 providerRefRate, uint256 depLt, uint256 depGt) internal returns (bytes memory) {
        bool stEthIsLt = address(stEthLike) == address(tokenLt);
        uint256 rateLt = stEthIsLt ? ONE : providerRefRate;
        uint256 rateGt = stEthIsLt ? providerRefRate : ONE;
        address providerLt = stEthIsLt ? address(0) : address(rateProvider);
        address providerGt = stEthIsLt ? address(rateProvider) : address(0);
        depositLt = depLt;
        depositGt = depGt;

        return bytes.concat(
            MovingPegSwap.build(
                MovingPegSwap.anchorFor(depositLt, rateLt),
                MovingPegSwap.anchorFor(depositGt, rateGt),
                WIDTH,
                rateLt,
                rateGt,
                providerLt,
                providerGt,
                band
            ),
            Salt.build(++saltNonce)
        );
    }

    /// @dev Build an order with fully explicit Lt/Gt rates (the wstETH-like side keeps the live
    ///   provider; the other side is static). Used by the dust value-floor tests, which need to
    ///   pick the output-side rate freely (the plain `_program*` helpers pin one side to 1e18).
    function _programRates(uint256 rateLt_, uint256 rateGt_, uint256 depLt_, uint256 depGt_) internal returns (bytes memory) {
        bool stEthIsLt = address(stEthLike) == address(tokenLt);
        address providerLt = stEthIsLt ? address(0) : address(rateProvider);
        address providerGt = stEthIsLt ? address(rateProvider) : address(0);
        depositLt = depLt_;
        depositGt = depGt_;

        return bytes.concat(
            MovingPegSwap.build(
                MovingPegSwap.anchorFor(depLt_, rateLt_),
                MovingPegSwap.anchorFor(depGt_, rateGt_),
                WIDTH,
                rateLt_,
                rateGt_,
                providerLt,
                providerGt,
                band
            ),
            Salt.build(++saltNonce)
        );
    }

    /// @dev The demo order with a 0.05% (feeBps 5000 on the upstream 1e7 BPS scale) flat input fee
    ///   placed BEFORE MovingPegSwap.
    function _programFee(uint24 feeBps) internal returns (bytes memory) {
        return bytes.concat(FeeFlatIn.build(feeBps), _program(REF_RATE));
    }

    function _createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenLt),
            tokenB: address(tokenGt),
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

    function _ship(ISwapVM.Order memory order) internal returns (bytes32 orderHash) {
        orderHash = swapVM.hash(order);

        vm.startPrank(maker);
        tokenLt.approve(address(aqua), type(uint256).max);
        tokenGt.approve(address(aqua), type(uint256).max);
        bytes32 strategyHash = aqua.ship(
            address(swapVM),
            abi.encode(order),
            dynamic([address(tokenLt), address(tokenGt)]),
            dynamic([depositLt, depositGt])
        );
        vm.stopPrank();

        assertEq(strategyHash, orderHash, "strategy hash mismatch");

        // Fund the maker so the router can pull liquidity on swap
        tokenLt.mint(maker, depositLt);
        tokenGt.mint(maker, depositGt);
    }

    function _isAToB(bool stEthToWstEth) internal view returns (bool) {
        address tokenIn = stEthToWstEth ? address(stEthLike) : address(wstEthLike);
        return tokenIn == address(tokenLt);
    }

    function _takerDataFor(address takerAddr, bool isAToB, bool isExactIn, bool partialFill) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddr,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            allowPartialFill: partialFill,
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

    function _takerData(bool isAToB, bool isExactIn, bool partialFill) internal view returns (bytes memory) {
        return _takerDataFor(address(taker), isAToB, isExactIn, partialFill);
    }

    function _view() internal view returns (ISwapVM) {
        return ISwapVM(address(swapVM));
    }

    function _quote(ISwapVM.Order memory order, uint256 amount, bool stEthToWstEth, bool isExactIn) internal returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = _view().quote(order, amount, _takerData(_isAToB(stEthToWstEth), isExactIn, false));
    }

    /// @notice Swap and assert real ERC20 taker balance deltas
    function _performSwap(
        ISwapVM.Order memory order,
        uint256 amount,
        bool stEthToWstEth,
        bool isExactIn,
        bool partialFill
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        (address tokenIn, address tokenOut) = stEthToWstEth
            ? (address(stEthLike), address(wstEthLike))
            : (address(wstEthLike), address(stEthLike));

        TokenMock(tokenIn).mint(address(taker), amount * 2 + 10e18);
        uint256 inBefore = TokenMock(tokenIn).balanceOf(address(taker));
        uint256 outBefore = TokenMock(tokenOut).balanceOf(address(taker));

        (amountIn, amountOut) = taker.swap(order, amount, _takerData(_isAToB(stEthToWstEth), isExactIn, partialFill));

        assertEq(inBefore - TokenMock(tokenIn).balanceOf(address(taker)), amountIn, "taker tokenIn delta");
        assertEq(TokenMock(tokenOut).balanceOf(address(taker)) - outBefore, amountOut, "taker tokenOut delta");
    }

    function _aquaBalanceOf(ISwapVM.Order memory order, address token) internal view returns (uint256 balance) {
        (uint248 bal,) = aqua.rawBalances(maker, address(swapVM), swapVM.hash(order), token);
        return bal;
    }

    /// @dev Value of the order's two Aqua reserves at the reference rate (1e18-scaled). Used by the
    ///   fee tests, where the live rate equals REF_RATE.
    function _orderValue(ISwapVM.Order memory order) internal view returns (uint256) {
        uint256 bLt = _aquaBalanceOf(order, address(tokenLt));
        uint256 bGt = _aquaBalanceOf(order, address(tokenGt));
        bool stEthIsLt = address(stEthLike) == address(tokenLt);
        uint256 rLt = stEthIsLt ? ONE : REF_RATE;
        uint256 rGt = stEthIsLt ? REF_RATE : ONE;
        return bLt * rLt + bGt * rGt;
    }
}

/// @notice Minimal direct-VM harness, used for determinism: it sets exact balances and anchors
///   directly instead of reaching them through a trade sequence. The dust-drain state is also
///   reachable through a normal Aqua order (one exactOut of balance-k at rateOut < 1e18), see
///   test_M_DrainDust_Router. Used by the dust-drain min-in test.
contract MovingPegSwapHarness {
    function exec(
        bool exactIn,
        address tokenIn,
        address tokenOut,
        uint256 balIn,
        uint256 balOut,
        uint256 amount,
        bytes calldata built
    ) external view returns (uint256, uint256) {
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

/// @notice MovingPegSwap with the wstETH-like token as the GREATER address (no Lt/Gt flip)
contract MovingPegSwapTest is MovingPegSwapAquaBase {
    function _configure() internal override {
        stEthLike = new TokenMock("stETH-like", "stETH-like");
        TokenMock w;
        do {
            w = new TokenMock("wstETH-like", "wstETH-like");
        } while (address(w) <= address(stEthLike));
        wstEthLike = w;
        tokenLt = stEthLike;
        tokenGt = wstEthLike;
    }

    // ===== M1: center tracks the rate =====

    function test_M1_CenterTracksRate() public {
        uint256[4] memory rates = [ONE, REF_RATE, 1.25e18, 1.5e18];

        for (uint256 i = 0; i < rates.length; i++) {
            rateProvider.setRate(rates[i]);
            // Each order is anchored value-balanced at its own rate so the curve center sits on it
            ISwapVM.Order memory order = _createOrder(_programValueBalanced(rates[i], DEPOSIT_STETH));
            _ship(order);

            (uint256 amountIn, uint256 amountOut) = _quote(order, 1e12, true, true);
            assertEq(amountIn, 1e12, "exactIn amount");

            uint256 valueOut = amountOut * rates[i] / ONE;
            assertApproxEqRel(valueOut, 1e12, 1e12, "value-for-value at center");
        }
    }

    // ===== M2: same order hash, rate moves, no re-ship =====

    function test_M2_SameOrderHash_RateMoves() public {
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory order = _createOrder(_program(REF_RATE));
        bytes32 h = _ship(order);
        bytes32 hashBefore = swapVM.hash(order);

        (uint256 in1, uint256 out1) = _performSwap(order, 1e12, true, true, false);
        assertGt(in1, 0);
        assertGt(out1, 0);

        rateProvider.setRate(WORLD_RATE);
        assertEq(swapVM.hash(order), hashBefore, "order hash must not change");

        (uint256 qIn, uint256 qOut) = _quote(order, 1e12, true, true);
        (uint256 in2, uint256 out2) = _performSwap(order, 1e12, true, true, false);
        assertEq(in2, qIn, "quote == swap amountIn");
        assertEq(out2, qOut, "quote == swap amountOut");
        assertGt(out2, 0);

        (uint256 balA, uint256 balB) = aqua.safeBalances(maker, address(swapVM), h, address(tokenLt), address(tokenGt));
        assertGt(balA, 0);
        assertGt(balB, 0);
    }

    // ===== M3: the "after" picture =====

    function test_M3_After_Picture() public {
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory order = _createOrder(_program(REF_RATE));
        _ship(order);

        rateProvider.setRate(WORLD_RATE);

        (uint256 amountIn, uint256 amountOut) = _performSwap(order, 0.125e18, true, true, false);
        int256 takerGain = int256(amountOut * WORLD_RATE / ONE) - int256(amountIn);

        int256 baselineGain = _baselineGain();

        emit log_named_int("M3 takerGain (wei tokenA-value)", takerGain);
        emit log_named_int("M3 baselineGain (wei tokenA-value)", baselineGain);
        assertLt(takerGain, baselineGain / 100, "moving peg must shrink the stale-peg gain by >100x");
    }

    /// @notice Recompute the baseline (frozen-peg) gain in-test with an upstream AquaSwapVMRouter
    function _baselineGain() internal returns (int256) {
        AquaSwapVMRouter baseVM = new AquaSwapVMRouter(address(aqua), address(0), address(this), "Base", "1.0.0");
        MockTaker baseTaker = new MockTaker(aqua, baseVM, address(this));

        bytes memory program = bytes.concat(PeggedSwap.build(DEPOSIT_STETH, DEPOSIT_WSTETH, WIDTH, 1, 1), Salt.build(++saltNonce));
        ISwapVM.Order memory border = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenLt),
            tokenB: address(tokenGt),
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

        vm.startPrank(maker);
        tokenLt.approve(address(aqua), type(uint256).max);
        tokenGt.approve(address(aqua), type(uint256).max);
        aqua.ship(
            address(baseVM),
            abi.encode(border),
            dynamic([address(tokenLt), address(tokenGt)]),
            dynamic([DEPOSIT_STETH, DEPOSIT_WSTETH])
        );
        vm.stopPrank();
        tokenLt.mint(maker, DEPOSIT_STETH);
        tokenGt.mint(maker, DEPOSIT_WSTETH);

        tokenLt.mint(address(baseTaker), 1e18);
        (uint256 bIn, uint256 bOut) = baseTaker.swap(border, 0.125e18, _takerDataFor(address(baseTaker), true, true, false));
        return int256(bOut * WORLD_RATE / ONE) - int256(bIn);
    }

    // ===== M4: rate down =====

    /// @dev 1.10e18 is NOT inside a 500 bps band around refRate 1.2e18 (lower edge 1.14e18),
    ///   so this test order uses a wider test-only band to let the same order
    ///   see both 1.20e18 and 1.10e18.
    function test_M4_RateDown() public {
        band = 1000; // test-only; = owner cap 1000
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory order = _createOrder(_program(REF_RATE));
        _ship(order);

        (uint256 in12, uint256 out12) = _quote(order, 1e12, true, true);
        (uint256 revIn12, uint256 revOut12) = _quote(order, 1e12, false, true);
        _performSwap(order, 1e12, true, true, false);

        rateProvider.setRate(1.10e18);
        (uint256 in10, uint256 out10) = _quote(order, 1e12, true, true);
        (uint256 revIn10, uint256 revOut10) = _quote(order, 1e12, false, true);
        _performSwap(order, 1e12, true, true, false);

        assertEq(in10, in12);
        assertGt(out10, out12, "tokenB must be cheaper when the rate is lower");
        assertGt(revIn12, 0);
        assertGt(revOut12, 0);
        assertGt(revIn10, 0);
        assertGt(revOut10, 0);
    }

    // ===== M5: guards =====

    function test_M5_Guards() public {
        ISwapVM.Order memory order = _createOrder(_program(REF_RATE));
        _ship(order);
        bytes memory td = _takerData(true, true, false);

        rateProvider.setRate(0);
        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapZeroRate.selector, address(rateProvider)));
        _view().quote(order, 1e12, td);

        uint256 high = REF_RATE * 10501 / 10000;
        rateProvider.setRate(high);
        vm.expectRevert(abi.encodeWithSelector(
            MovingPegSwap.MovingPegSwapRateOutOfBand.selector,
            address(rateProvider),
            high,
            REF_RATE,
            MAX_DEV_BPS
        ));
        _view().quote(order, 1e12, td);

        uint256 low = REF_RATE * 9499 / 10000;
        rateProvider.setRate(low);
        vm.expectRevert(abi.encodeWithSelector(
            MovingPegSwap.MovingPegSwapRateOutOfBand.selector,
            address(rateProvider),
            low,
            REF_RATE,
            MAX_DEV_BPS
        ));
        _view().quote(order, 1e12, td);

        rateProvider.setShouldRevert(true);
        vm.expectRevert(MockRateProvider.MockRateProviderForcedRevert.selector);
        _view().quote(order, 1e12, td);

        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidMaxDeviation.selector, 0));
        this._buildExternal(6e18, 6e18, WIDTH, ONE, REF_RATE, address(0), address(rateProvider), 0);

        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidMaxDeviation.selector, 10000));
        this._buildExternal(6e18, 6e18, WIDTH, ONE, REF_RATE, address(0), address(rateProvider), 10000);

        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidRefRates.selector, 0, 1));
        this._buildExternal(6e18, 6e18, WIDTH, 0, 1, address(0), address(rateProvider), 500);

        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidRefRates.selector, 1, 0));
        this._buildExternal(6e18, 6e18, WIDTH, 1, 0, address(0), address(rateProvider), 500);
    }

    /// @dev External wrapper so `vm.expectRevert` can observe the internal library revert
    function _buildExternal(
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 refRateLt,
        uint256 refRateGt,
        address providerLt,
        address providerGt,
        uint16 maxDeviationBps
    ) external pure {
        MovingPegSwap.build(x0, y0, linearWidth, refRateLt, refRateGt, providerLt, providerGt, maxDeviationBps);
    }

    // ===== M6: quote == swap =====

    function test_M6_QuoteEqualsSwap() public {
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory order = _createOrder(_program(REF_RATE));
        _ship(order);

        uint256[5] memory amounts = [uint256(1e12), 1e15, 1e17, 1e18, 3e18];
        for (uint256 i = 0; i < amounts.length; i++) {
            _assertQuoteSwapEq(order, amounts[i], true, true);
            _assertQuoteSwapEq(order, amounts[i], true, false);
            _assertQuoteSwapEq(order, amounts[i], false, true);
            _assertQuoteSwapEq(order, amounts[i], false, false);
        }
    }

    function _assertQuoteSwapEq(ISwapVM.Order memory order, uint256 amount, bool stEthToWstEth, bool isExactIn) internal {
        uint256 snap = vm.snapshot();
        (uint256 qIn, uint256 qOut) = _quote(order, amount, stEthToWstEth, isExactIn);
        (uint256 sIn, uint256 sOut) = _performSwap(order, amount, stEthToWstEth, isExactIn, false);
        assertEq(sIn, qIn, "quote/swap amountIn mismatch");
        assertEq(sOut, qOut, "quote/swap amountOut mismatch");
        vm.revertTo(snap);
    }

    // ===== M7: finite reserves =====

    function test_M7_FiniteReserves() public {
        uint256[2] memory rates = [REF_RATE, WORLD_RATE];

        for (uint256 i = 0; i < rates.length; i++) {
            rateProvider.setRate(rates[i]);
            ISwapVM.Order memory order = _createOrder(_program(REF_RATE));
            _ship(order);

            // exactOut of balanceOut + 1 reverts (no partial fill)
            TokenMock(address(stEthLike)).mint(address(taker), 20e18);
            vm.expectRevert();
            taker.swap(order, DEPOSIT_WSTETH + 1, _takerData(true, false, false));

            // huge exactIn drains at most balanceOut
            (uint256 amountIn, uint256 amountOut) = _performSwap(order, 1000e18, true, true, true);
            assertEq(amountOut, DEPOSIT_WSTETH, "drain must yield exactly balanceOut");
            assertGt(amountIn, 0);
            assertLe(amountOut, DEPOSIT_WSTETH);
        }
    }

    // ===== F2: B→A drain amountIn rounding pinned =====

    /// @notice B→A drain at a fractional rate; amountIn pinned exactly against an independent
    ///   PeggedSwapMath.solve / invariantFromReserves computation. The quotient is non-exact,
    ///   so a floor mutant differs by 1 wei and is caught.
    function test_M_BtoA_Drain_RoundingPinned() public {
        uint256 r = 1_183_746_519_283_746_519;
        uint256 depLt_ = 6e18;
        uint256 depGt_ = 5e18;
        rateProvider.setRate(r);
        ISwapVM.Order memory order = _createOrder(_programWithDeposits(r, depLt_, depGt_));
        _ship(order);

        // Independent expectation (computed from the math library, not by calling MovingPegSwap)
        uint256 x0 = depGt_ * r / ONE;               // normalized input reserve (B→A)
        uint256 y0 = depLt_ * ONE / ONE;             // normalized output reserve
        uint256 x0Init = MovingPegSwap.anchorFor(depGt_, r);
        uint256 y0Init = MovingPegSwap.anchorFor(depLt_, ONE);
        uint256 target = PeggedSwapMath.invariantFromReserves(x0, y0, x0Init, y0Init, WIDTH);
        uint256 uMax = PeggedSwapMath.solve(target, WIDTH);
        uint256 x1Capped = Math.ceilDiv(uMax * x0Init, PeggedSwapMath.ONE);
        uint256 expectedIn = Math.ceilDiv((x1Capped - x0) * ONE, r);
        assertGt((x1Capped - x0) * ONE % r, 0, "need a non-exact quotient (floor != ceil)");

        (uint256 amountIn, uint256 amountOut) = _performSwap(order, 1000e18, false, true, true);
        assertEq(amountOut, depLt_, "drain must yield the full stETH-like reserve");
        assertEq(amountIn, expectedIn, "B->A drain amountIn must be the ceil (pinned)");
    }

    // ===== F3: full-reserve exactOut saturation =====

    /// @notice A full-reserve exactOut at a fractional rate must fill (not panic on underflow),
    ///   deliver exactly balanceOut to the taker, and never decrease maker value.
    function test_M_FullReserveExactOut_FractionalRate() public {
        uint256 r = 1_183_746_519_283_746_519;
        uint256 depLt_ = 6e18;
        uint256 depGt_ = 5e18 + 7;
        rateProvider.setRate(r);
        ISwapVM.Order memory order = _createOrder(_programWithDeposits(r, depLt_, depGt_));
        _ship(order);

        assertGt((depGt_ * r) % ONE, 0, "want a fractional output product");

        uint256 valueBefore = depLt_ * ONE + depGt_ * r; // scaled by 1e18
        (uint256 amountIn, uint256 amountOut) = _performSwap(order, depGt_, true, false, false);
        assertEq(amountOut, depGt_, "taker must receive exactly balanceOut");
        assertGt(amountIn, 0, "full reserve must cost a positive input");

        uint256 valueAfter = (depLt_ + amountIn) * ONE + (depGt_ - amountOut) * r;
        assertGe(valueAfter, valueBefore, "maker value must not decrease on a full drain");
    }

    // ===== F4: dust drain charges a minimum input =====

    /// @notice When the output side is dust, the drain branch must charge at least 1 wei of tokenIn
    ///   (never a zero-in/positive-out order). Two anchor regimes:
    ///     - y0_init = 6e18: normalized y0 == 0, so the dust value floor (`if (y0 == 0)`) also applies;
    ///     - y0_init = 1e30: y0 > 0 while the normalized v0 still floors to 0, so the value floor does
    ///       NOT apply and only the 1-wei min-in stands between the maker and a zero-in drain.
    function test_M_DrainDust_MinAmountIn() public {
        MovingPegSwapHarness h = new MovingPegSwapHarness();
        address lt = address(0x1000);
        address gt = address(0x2000);
        uint256 rOut = 0.3e18;

        bytes memory dustProgram = MovingPegSwap.build(6e18, 6e18, WIDTH, ONE, rOut, address(0), address(0), 500);
        for (uint256 bo = 1; bo <= 3; bo++) {
            (uint256 amountIn, uint256 amountOut) = h.exec(true, lt, gt, 7e18, bo, 1e18, dustProgram);
            assertEq(amountOut, bo, "drain must yield the full dust output reserve");
            assertEq(amountIn, 1, "dust drain must charge at least 1 wei of tokenIn");
        }

        bytes memory nonDustProgram = MovingPegSwap.build(6e18, 1e30, WIDTH, ONE, rOut, address(0), address(0), 500);
        for (uint256 bo = 4; bo <= 40; bo += 12) {
            (uint256 amountIn, uint256 amountOut) = h.exec(true, lt, gt, 7e18, bo, 1e18, nonDustProgram);
            assertGt(bo * rOut / ONE, 0, "normalized output must be nonzero (value floor does not apply)");
            assertEq(amountOut, bo, "drain must yield the full output reserve");
            assertEq(amountIn, 1, "non-dust-normalized drain must charge at least 1 wei of tokenIn");
        }
    }

    // ===== F4b: dust value floor (normalized output rounds to 0) =====

    /// @notice In the dust/saturated region the taker must never receive more value than it pays,
    ///   for a dust exactOut and a dust exactIn drain. Both run through RateSpaceAquaRouter with
    ///   default traits; the output-side provider rate is below 1e18 so normalized y0 rounds to 0.
    function test_M_DustValueFloor() public {
        uint256[3] memory rIns = [uint256(0.05e18), 0.3e18, 0.9e18];
        uint256 rOut = 0.999e18;
        rateProvider.setRate(rOut);

        for (uint256 i = 0; i < 3; i++) {
            uint256 rIn = rIns[i];
            uint256 dLt = 6e18 * ONE / rIn;
            uint256 dGt = 6e18 * ONE / rOut + 5;
            ISwapVM.Order memory order = _createOrder(_programRates(rIn, rOut, dLt, dGt));
            _ship(order);
            // The input value equals the output value, so at a low rIn the taker must fund a large
            // tokenIn balance; fund it before the snapshot so it survives the per-branch reverts.
            TokenMock(address(stEthLike)).mint(address(taker), 1e27);

            uint256 snap = vm.snapshotState();

            // (a) reduce the output reserve to 1 wei, then exactOut that dust
            _performSwap(order, dGt - 1, true, false, false);
            assertEq(_aquaBalanceOf(order, address(tokenGt)), 1, "output reserve must be 1 wei");
            (uint256 aIn, uint256 aOut) = _performSwap(order, 1, true, false, false);
            assertEq(aOut, 1, "dust exactOut must deliver 1 wei");
            assertGe(aIn * rIn, aOut * rOut, "dust exactOut: value in < value out");
            vm.revertToState(snap);

            // (b) same reduction, then a dust exactIn drain
            _performSwap(order, dGt - 1, true, false, false);
            (uint256 bIn, uint256 bOut) = _performSwap(order, 1e18, true, true, true);
            assertEq(bOut, 1, "dust drain must deliver the 1 wei reserve");
            assertGe(bIn * rIn, bOut * rOut, "dust drain: value in < value out");
            vm.revertToState(snap);
        }
    }

    /// @notice Multi-wei dust (F3, mutant o10): rIn = rOut = 0.05e18, output reserve reduced to k
    ///   wei (k = 2..5, normalized y0 = floor(k * 0.05) = 0). The value floor must charge input worth
    ///   at least the full k-wei output: k = 2 costs exactly 2 wei, and value in >= value out for
    ///   every k, for the exactIn drain and for the exactOut of the whole dust reserve.
    function test_M_DustValueFloor_MultiWei() public {
        uint256 rIn = 0.05e18;
        uint256 rOut = 0.05e18;
        rateProvider.setRate(rOut);
        uint256 dLt = 6e18 * ONE / rIn;
        uint256 dGt = 6e18 * ONE / rOut + 5;
        ISwapVM.Order memory order = _createOrder(_programRates(rIn, rOut, dLt, dGt));
        _ship(order);
        TokenMock(address(stEthLike)).mint(address(taker), 1e27);

        for (uint256 k = 2; k <= 5; k++) {
            uint256 snap = vm.snapshotState();
            _performSwap(order, dGt - k, true, false, false);
            assertEq(_aquaBalanceOf(order, address(tokenGt)), k, "output reserve must be k wei");
            assertEq(k * rOut / ONE, 0, "normalized output reserve must round to 0");
            uint256 snap2 = vm.snapshotState();

            (uint256 dIn, uint256 dOut) = _performSwap(order, 1e18, true, true, true);
            emit log_named_uint("F3 k", k);
            emit log_named_uint("F3   exactIn-drain amountIn", dIn);
            assertEq(dOut, k, "dust drain must deliver the k-wei reserve");
            assertGe(dIn * rIn, dOut * rOut, "dust drain: value in < value out");
            if (k == 2) assertEq(dIn, 2, "k=2 dust drain must charge exactly 2 wei");
            vm.revertToState(snap2);

            (uint256 oIn, uint256 oOut) = _performSwap(order, k, true, false, false);
            emit log_named_uint("F3   exactOut-dust amountIn", oIn);
            assertEq(oOut, k, "dust exactOut must deliver k wei");
            assertGe(oIn * rIn, oOut * rOut, "dust exactOut: value in < value out");
            vm.revertToState(snap);
        }
    }

    /// @notice F2(c): balanced pools, full-reserve exactOut through the router, output-side rates
    ///   {0.3, 0.999, 1.0, 1.1837.., 1.2, 3.0}e18, input side 1e18. With the exactOut value floor
    ///   gated on y0 == 0 only, the saturated-but-not-dust region (y0 > 0, ceil(out*rate) > y0) is
    ///   priced by the curve alone; it must still charge value in >= value out. The output deposit
    ///   is the value-balanced amount + 7 wei so the product is fractional where the rate allows;
    ///   rates 1.0e18 and 3.0e18 are integer multiples of 1e18, so their product is always exact
    ///   (c == y0, not saturated) and they are checked for the value property only.
    function test_M_FullReserveExactOut_BalancedValue() public {
        uint256[6] memory rOuts = [uint256(0.3e18), 0.999e18, 1e18, 1_183_746_519_283_746_519, 1.2e18, 3e18];
        uint256 rIn = ONE;
        TokenMock(address(stEthLike)).mint(address(taker), 1e27);

        for (uint256 i = 0; i < rOuts.length; i++) {
            uint256 rOut = rOuts[i];
            rateProvider.setRate(rOut);
            uint256 dLt = 6e18;
            uint256 dGt = 6e18 * ONE / rOut + 7;
            ISwapVM.Order memory order = _createOrder(_programRates(rIn, rOut, dLt, dGt));
            _ship(order);

            uint256 y0 = dGt * rOut / ONE;
            uint256 c = Math.ceilDiv(dGt * rOut, ONE);
            assertGt(y0, 0, "not dust");
            if (rOut % ONE != 0) assertGt(c, y0, "saturated: ceil(out * rate) > floored y0");

            (uint256 aIn, uint256 aOut) = _performSwap(order, dGt, true, false, false);
            emit log_named_uint("F2c rOut", rOut);
            emit log_named_uint("F2c   amountIn", aIn);
            emit log_named_uint("F2c   value out (1e18 units, ceil)", c);
            assertEq(aOut, dGt, "full-reserve exactOut must deliver the whole reserve");
            assertGe(aIn * rIn, aOut * rOut, "full-reserve exactOut: value in < value out");
        }
    }

    // ===== F4c: exactOut-of-dust min-in (non-saturated, so the value floor does not apply) =====

    /// @notice exactOut min-in pin (mutant xG). After G1, a saturated dust exactOut is covered by the
    ///   value floor, which also yields >= 1 wei and so masks the min-in rule. The rule is only
    ///   load-bearing where the curve itself rounds amountIn to 0 WITHOUT saturation. That happens
    ///   when the anchors exceed PeggedSwapMath.ONE (1e27), so 1 wei of output moves the normalized
    ///   curve by less than 1 unit of input. Pool: value-balanced 1.2e30 per side at 1.2e18, shipped
    ///   through RateSpaceAquaRouter with default traits. Under xG, amountIn is 0 and the router
    ///   rejects it (MakerTraitsZeroAmountInNotAllowed).
    /// @dev The value-at-rate floor is NOT asserted here: at this scale 1 wei of WETH-side in buys
    ///   1 wei of wstETH-side (value 1.2 wei) and up to k=1000 wei at the center. This is an open
    ///   finding from an earlier internal review (outside the G1 fix, which only covers the saturated region).
    function test_M_DustExactOut_MinAmountIn() public {
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory order = _createOrder(_programValueBalanced(REF_RATE, 1.2e30));
        _ship(order);
        uint256 balOut = _aquaBalanceOf(order, address(wstEthLike));

        // A->B exactOut of 1 wei of the wstETH-like side: far from saturation (c = 2 << y0 ~ 1.2e30)
        (uint256 amountIn, uint256 amountOut) = _performSwap(order, 1, true, false, false);
        assertEq(amountOut, 1, "dust exactOut must deliver 1 wei");
        assertGt(balOut * REF_RATE / ONE, Math.ceilDiv(amountOut * REF_RATE, ONE), "must not be saturated");
        assertEq(amountIn, 1, "curve rounds to 0; the 1-wei min-in must charge exactly 1 wei");
    }

    // ===== F4e: partial dust exactOut value floor (round-4 M1, mutant N7) =====

    /// @notice Partial exactOut of a dust reserve. rIn = rOut = 0.05e18, output reserve reduced to
    ///   5 wei through the router (normalized y0 = floor(5 * 0.05) = 0, so the value floor applies).
    ///   For j in 1..4 wei the floor must charge input worth the REQUESTED j-wei output, not the whole
    ///   5-wei reserve: amountIn == ceilDiv(j * rOut, rIn) (= j here) and value in >= value out.
    ///   Pins N7 (`ctx.swap.amountOut` -> `y0_raw` in the exactOut floor), which charges 5 for every j.
    function test_M_DustValueFloor_PartialExactOut() public {
        uint256 rIn = 0.05e18;
        uint256 rOut = 0.05e18;
        uint256 k = 5;
        rateProvider.setRate(rOut);
        uint256 dLt = 6e18 * ONE / rIn;
        uint256 dGt = 6e18 * ONE / rOut + 5;
        ISwapVM.Order memory order = _createOrder(_programRates(rIn, rOut, dLt, dGt));
        _ship(order);
        TokenMock(address(stEthLike)).mint(address(taker), 1e27);

        _performSwap(order, dGt - k, true, false, false);
        assertEq(_aquaBalanceOf(order, address(tokenGt)), k, "output reserve must be k wei");
        assertEq(k * rOut / ONE, 0, "normalized output reserve must round to 0");

        for (uint256 j = 1; j < k; j++) {
            uint256 snap = vm.snapshotState();
            (uint256 qIn, uint256 qOut) = _quote(order, j, true, false);
            (uint256 aIn, uint256 aOut) = _performSwap(order, j, true, false, false);
            emit log_named_uint("N7 j", j);
            emit log_named_uint("N7   partial dust exactOut amountIn", aIn);
            assertEq(aOut, j, "partial dust exactOut must deliver j wei");
            assertEq(qIn, aIn, "quote amountIn == swap amountIn");
            assertEq(qOut, aOut, "quote amountOut == swap amountOut");
            assertEq(aIn, Math.ceilDiv(j * rOut, rIn), "floor must price the requested j wei, not the reserve");
            assertEq(aIn, j, "rIn == rOut: j wei out costs exactly j wei in");
            assertGe(aIn * rIn, j * rOut, "partial dust exactOut: value in < value out");
            vm.revertToState(snap);
        }
    }

    // ===== F4f: exactOut gate `y0 == 0` pinned at large anchors (round-4 m2, mutant N3) =====

    /// @notice The exactOut value floor is gated on normalized y0 == 0. With anchors <= 1e27 a
    ///   y0 == 1 reserve is already priced >= value by the curve, so `y0 <= 1` is indistinguishable
    ///   there. Above 1e27 (anchors 1e30 per side) the curve rounds a y0 == 1 exactOut to the 1-wei
    ///   min-in. This pins the owner-accepted behaviour of the real gate; it is NOT a value-floor
    ///   assertion. Direct harness, output reserve 2 wei at rOut 0.9e18 (y0 = floor(1.8) = 1).
    /// @dev balIn is rounded UP so normalized x0 == anchor exactly. With a floored balIn at
    ///   rIn 0.9e18 (x0 = 1e30 - 1) the exactOut path panics 0x11; not pinned here.
    function test_M_ExactOutGate_LargeAnchors_Pinned() public {
        MovingPegSwapHarness h = new MovingPegSwapHarness();
        address lt = address(0x1000);
        address gt = address(0x2000);
        uint256 anchor = 1e30;
        uint256 rOut = 0.9e18;
        uint256 balOut = 2;
        assertEq(balOut * rOut / ONE, 1, "normalized output reserve must be exactly 1");

        uint256[2] memory rIns = [uint256(0.05e18), 0.9e18];
        for (uint256 i = 0; i < rIns.length; i++) {
            uint256 rIn = rIns[i];
            uint256 balIn = Math.ceilDiv(anchor * ONE, rIn);
            assertEq(balIn * rIn / ONE, anchor, "normalized x0 must equal the anchor");
            bytes memory prog = MovingPegSwap.build(anchor, anchor, WIDTH, rIn, rOut, address(0), address(0), 500);
            for (uint256 j = 1; j <= balOut; j++) {
                (uint256 amountIn, uint256 amountOut) = h.exec(false, lt, gt, balIn, balOut, j, prog);
                emit log_named_uint("N3 rIn", rIn);
                emit log_named_uint("N3   j", j);
                emit log_named_uint("N3   exactOut amountIn", amountIn);
                assertEq(amountOut, j, "exactOut must deliver j wei");
                // Measured with the real gate: the curve rounds to 0 and the 1-wei min-in charges 1.
                // Under N3 (`y0 <= 1`) the floor would charge ceilDiv(j * rOut, rIn): 18/36 at
                // rIn 0.05e18, 1/2 at rIn 0.9e18.
                assertEq(amountIn, 1, "real gate (y0 == 0) does not floor a y0 == 1 exactOut: 1 wei");
            }
        }
    }

    // ===== F4d: the dust-drain state is reachable through a normal Aqua order =====

    /// @notice Router-level twin of the direct-harness dust-drain test. One ordinary exactOut through
    ///   RateSpaceAquaRouter leaves a dust output reserve (normalized y0 == 0); the following exactIn
    ///   drain must charge at least 1 wei. The state is reachable via a normally shipped Aqua order.
    function test_M_DrainDust_Router() public {
        uint256 r = 0.3e18;
        rateProvider.setRate(r);
        uint256 depLt_ = 6e18;
        uint256 depGt_ = 20e18 + 7;
        ISwapVM.Order memory order = _createOrder(_programWithDeposits(r, depLt_, depGt_));
        _ship(order);

        for (uint256 k = 1; k <= 3; k++) {
            uint256 snap = vm.snapshotState();
            uint256 balGt = _aquaBalanceOf(order, address(tokenGt));
            _performSwap(order, balGt - k, true, false, false);
            assertEq(_aquaBalanceOf(order, address(tokenGt)), k, "reserve must be the dust k wei");
            assertEq(k * r / ONE, 0, "normalized output must round to 0");
            (uint256 amountIn, uint256 amountOut) = _performSwap(order, 1e18, true, true, true);
            assertEq(amountOut, k, "drain must yield the dust reserve");
            assertEq(amountIn, 1, "dust drain must charge at least 1 wei");
            vm.revertToState(snap);
        }
    }

    // ===== F3b: over-valued full drain prices identically through both paths =====

    /// @notice A full drain of an OVER-valued output reserve charges the identical amountIn through
    ///   the exactOut saturation path and the exactIn drain path. This is the AMM curve pricing a
    ///   maker-chosen imbalanced pool, not a saturation defect. Covers an exact output product
    ///   (depGt 6e18) and fractional ones (balance*rate not a multiple of 1e18), where the
    ///   exactOut ceil exceeds the floored y0 but y0 > 0, so the dust value floor must not fire.
    function test_M_FullDrainOverValued_EqualInput() public {
        uint256 r = 1_183_746_519_283_746_519;
        uint256 depLt_ = 6e18;
        uint256[5] memory depGts = [uint256(6e18), 6e18 + 1, 6e18 + 7, 6e18 + 123456789, 6.5e18];
        rateProvider.setRate(r);

        for (uint256 i = 0; i < depGts.length; i++) {
            uint256 depGt_ = depGts[i];
            assertGt(depGt_ * r, depLt_ * ONE, "output reserve must be over-valued");
            if (i == 0) assertEq(depGt_ * r % ONE, 0, "case 0: exact product");
            else assertGt(depGt_ * r % ONE, 0, "fractional product: exactOut ceil exceeds floored y0");
            ISwapVM.Order memory order = _createOrder(_programWithDeposits(r, depLt_, depGt_));
            _ship(order);

            uint256 snap = vm.snapshotState();
            (uint256 eoIn, uint256 eoOut) = _performSwap(order, depGt_, true, false, false);
            vm.revertToState(snap);
            (uint256 eiIn, uint256 eiOut) = _performSwap(order, 1000e18, true, true, true);
            vm.revertToState(snap);

            emit log_named_uint("F2a depGt", depGt_);
            emit log_named_uint("F2a   exactOut-full amountIn", eoIn);
            emit log_named_uint("F2a   exactIn-drain amountIn", eiIn);
            assertEq(eoOut, depGt_, "exactOut must drain the full output reserve");
            assertEq(eiOut, depGt_, "exactIn must drain the full output reserve");
            assertEq(eoIn, eiIn, "exactOut and exactIn drains must charge identical amountIn");
        }
    }

    // ===== N-C: per-order drift band hard cap =====

    /// @notice The owner cap on maxDeviationBps is 1000 (10%). 1000 is accepted; 1001 and 9999 are
    ///   rejected with the exact selector and argument.
    function test_M_BandCap() public {
        this._buildExternal(6e18, 6e18, WIDTH, ONE, REF_RATE, address(0), address(rateProvider), 1000);

        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidMaxDeviation.selector, 1001));
        this._buildExternal(6e18, 6e18, WIDTH, ONE, REF_RATE, address(0), address(rateProvider), 1001);

        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidMaxDeviation.selector, 9999));
        this._buildExternal(6e18, 6e18, WIDTH, ONE, REF_RATE, address(0), address(rateProvider), 9999);

        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidMaxDeviation.selector, 65535));
        this._buildExternal(6e18, 6e18, WIDTH, ONE, REF_RATE, address(0), address(rateProvider), 65535);
    }

    /// @dev Demo order built with the legal band 1000, then the trailing uint16 band bytes of the
    ///   MovingPegSwap instruction are patched to `bandBytes`, bypassing build()'s cap check.
    function _handProg(uint16 bandBytes) internal returns (bytes memory) {
        bytes memory b = MovingPegSwap.build(
            MovingPegSwap.anchorFor(depositLt, ONE),
            MovingPegSwap.anchorFor(depositGt, REF_RATE),
            WIDTH,
            ONE,
            REF_RATE,
            address(0),
            address(rateProvider),
            1000
        );
        assertEq(uint8(b[b.length - 2]), 0x03, "band 1000 high byte");
        assertEq(uint8(b[b.length - 1]), 0xE8, "band 1000 low byte");
        b[b.length - 2] = bytes1(uint8(bandBytes >> 8));
        b[b.length - 1] = bytes1(uint8(bandBytes));
        return bytes.concat(b, Salt.build(++saltNonce));
    }

    /// @notice The band cap is enforced at exec time, not only in build(): an order whose bytes carry
    ///   an out-of-cap band (hand-encoded, never passed through build()) must revert on quote AND
    ///   swap, in both directions and both modes, with the exact selector and argument. Includes
    ///   the hand-encoded-band drain scenario (band 9999, live rate 0.0001 x ref). Control: the same patch
    ///   path with band 1000 still trades.
    function test_M_BandCap_Exec() public {
        uint16[5] memory bad = [uint16(0), 1001, 9999, 10000, 65535];
        stEthLike.mint(address(taker), 1e30);
        wstEthLike.mint(address(taker), 1e30);

        for (uint256 i = 0; i < bad.length; i++) {
            rateProvider.setRate(REF_RATE);
            ISwapVM.Order memory order = _createOrder(_handProg(bad[i]));
            _ship(order);
            bytes memory err = abi.encodeWithSelector(MovingPegSwap.MovingPegSwapInvalidMaxDeviation.selector, uint256(bad[i]));

            for (uint256 j = 0; j < 4; j++) {
                bytes memory td = _takerData(j < 2, j % 2 == 0, true);
                vm.expectRevert(err);
                _view().quote(order, 1e15, td);
                vm.expectRevert(err);
                taker.swap(order, 1e15, td);
            }

            if (bad[i] == 9999) {
                // hand-encoded-band drain scenario: live rate 0.0001 x ref, full-drain exactIn
                rateProvider.setRate(REF_RATE / 10000);
                vm.expectRevert(err);
                _view().quote(order, 1000e18, _takerData(true, true, true));
                vm.expectRevert(err);
                taker.swap(order, 1000e18, _takerData(true, true, true));
            }
        }

        // Control: the patch path itself is sound (band 1000 is legal and trades)
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory ok = _createOrder(_handProg(1000));
        _ship(ok);
        (uint256 cIn, uint256 cOut) = _performSwap(ok, 1e15, true, true, false);
        assertEq(cIn, 1e15, "control swap amountIn");
        assertGt(cOut, 0, "control swap amountOut");
    }

    // ===== F9: 0.05% flat input fee =====

    /// @notice Quote must equal swap with the fee opcode in both directions and both modes.
    function test_M_Fee_QuoteEqualsSwap() public {
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory order = _createOrder(_programFee(5000));
        _ship(order);

        uint256[5] memory amounts = [uint256(1e12), 1e15, 1e17, 1e18, 3e18];
        for (uint256 i = 0; i < amounts.length; i++) {
            _assertQuoteSwapEq(order, amounts[i], true, true);
            _assertQuoteSwapEq(order, amounts[i], true, false);
            _assertQuoteSwapEq(order, amounts[i], false, true);
            _assertQuoteSwapEq(order, amounts[i], false, false);
        }
    }

    /// @notice The taker pays more with the fee than without it, and the maker's value is strictly
    ///   higher after a fee round trip.
    function test_M_Fee_TakerPaysMore() public {
        rateProvider.setRate(REF_RATE);

        ISwapVM.Order memory noFee = _createOrder(_program(REF_RATE));
        _ship(noFee);
        (, uint256 nfOut) = _quote(noFee, 1e17, true, true);
        (uint256 nfIn,,) = _view().quote(noFee, 1e17, _takerData(true, false, false));

        ISwapVM.Order memory fee = _createOrder(_programFee(5000));
        _ship(fee);
        (, uint256 fOut) = _quote(fee, 1e17, true, true);
        (uint256 fIn,,) = _view().quote(fee, 1e17, _takerData(true, false, false));

        assertLt(fOut, nfOut, "fee must reduce the exactIn output");
        assertGt(fIn, nfIn, "fee must raise the exactOut input");

        uint256 valueBefore = _orderValue(fee);
        (, uint256 out1) = _performSwap(fee, 1e17, true, true, false);
        _performSwap(fee, out1, false, true, false);
        uint256 valueAfter = _orderValue(fee);
        assertGt(valueAfter, valueBefore, "maker value must rise after a fee round trip");

        // The same round trip on the no-fee order: rounding alone also favors the maker, so the
        // fee's contribution is pinned by requiring a strictly larger maker gain with the fee.
        uint256 nfBefore = _orderValue(noFee);
        (, uint256 nfOut1) = _performSwap(noFee, 1e17, true, true, false);
        _performSwap(noFee, nfOut1, false, true, false);
        uint256 nfAfter = _orderValue(noFee);
        emit log_named_uint("F9 maker round-trip gain no-fee (value 1e36)", nfAfter - nfBefore);
        emit log_named_uint("F9 maker round-trip gain fee (value 1e36)", valueAfter - valueBefore);
        assertGt(valueAfter - valueBefore, nfAfter - nfBefore, "fee must add maker value beyond rounding");
    }

    /// @notice Pins the exact fee amounts against upstream FeeFlatIn (lib/swap-vm FeeFlat.sol:49-66,
    ///   BPS = 1e7). A no-fee and a fee order are shipped with identical deposits, so both see the
    ///   same reserves. exactIn(A): FeeFlatIn strips fee = ceil(A * f / 1e7), the curve runs on
    ///   A - fee (non-drain, so amountIn is unchanged and `reduction == 0` restores A); hence
    ///   amountIn == A and amountOut == noFee.exactIn(A - fee).amountOut. exactOut(B): amountIn ==
    ///   n + ceil(n * f / (1e7 - f)) with n = noFee.exactOut(B).amountIn.
    function test_M_Fee_AmountsPinned() public {
        uint256 f = 5000;        // owner-approved fee, upstream 1e7 scale
        uint256 feeScale = 1e7;  // upstream FeeFlatIn.BPS
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory noFee = _createOrder(_program(REF_RATE));
        _ship(noFee);
        ISwapVM.Order memory fee = _createOrder(_programFee(uint24(f)));
        _ship(fee);

        uint256[4] memory amounts = [uint256(1e12), 1e15 + 3, 1e17 + 12345, 1e18];
        for (uint256 i = 0; i < amounts.length; i++) {
            for (uint256 d = 0; d < 2; d++) {
                bool stToW = d == 0;
                uint256 a = amounts[i];

                (uint256 fIn, uint256 fOut) = _quote(fee, a, stToW, true);
                uint256 feeAmt = Math.ceilDiv(a * f, feeScale);
                (uint256 nIn, uint256 nOut) = _quote(noFee, a - feeAmt, stToW, true);
                assertEq(nIn, a - feeAmt, "no-fee exactIn is non-drain");
                assertEq(fIn, a, "fee exactIn amountIn == A");
                assertEq(fOut, nOut, "fee exactIn amountOut == noFee.exactIn(A - ceil(A*f/1e7))");

                (uint256 gIn, uint256 gOut) = _quote(fee, a, stToW, false);
                (uint256 mIn,) = _quote(noFee, a, stToW, false);
                assertEq(gOut, a, "fee exactOut amountOut == B");
                assertEq(gIn, mIn + Math.ceilDiv(mIn * f, feeScale - f), "fee exactOut amountIn == n + ceil(n*f/(1e7-f))");
            }
        }
    }

    /// @notice Rate-step round trip (F9): the provider moves up by +1bp / +3bp between the buy and
    ///   the sell. With the 0.05% fee the taker's net tokenA (WETH-side) P&L is negative; without
    ///   the fee the +1bp round trip is positive (the fee is what closes it).
    function test_M_Fee_RateStepRoundTrip() public {
        int256 p1NoFee = _rateStepPnL(false, 1);
        int256 p1Fee = _rateStepPnL(true, 1);
        int256 p3Fee = _rateStepPnL(true, 3);
        int256 p3NoFee = _rateStepPnL(false, 3);

        emit log_named_int("F9 +1bp no-fee taker net tokenA", p1NoFee);
        emit log_named_int("F9 +1bp fee taker net tokenA", p1Fee);
        emit log_named_int("F9 +3bp fee taker net tokenA", p3Fee);
        emit log_named_int("F9 +3bp no-fee taker net tokenA", p3NoFee);

        assertGt(p1NoFee, 0, "no-fee +1bp round trip must be taker-positive");
        assertLt(p1Fee, 0, "fee must make the +1bp round trip taker-negative");
        assertLt(p3Fee, 0, "fee must make the +3bp round trip taker-negative");
        assertGt(p3NoFee, 0, "no-fee +3bp round trip must be taker-positive");
    }

    function _rateStepPnL(bool withFee, uint256 bps) internal returns (int256 pnl) {
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory order = _createOrder(withFee ? _programFee(5000) : _program(REF_RATE));
        _ship(order);
        TokenMock(address(stEthLike)).mint(address(taker), 200e18);
        TokenMock(address(wstEthLike)).mint(address(taker), 200e18);

        uint256 aBefore = stEthLike.balanceOf(address(taker));
        (, uint256 out1) = taker.swap(order, 1e18, _takerData(true, true, false));
        rateProvider.setRate(REF_RATE + REF_RATE * bps / 10000);
        taker.swap(order, out1, _takerData(false, true, false));
        pnl = int256(stEthLike.balanceOf(address(taker))) - int256(aBefore);
    }

    // ===== M9: fuzz =====

    function testFuzz_M9_QuoteSwapAndRoundTrip(uint256 rateSeed, uint256 amountSeed) public {
        uint256 rate = REF_RATE * (9500 + bound(rateSeed, 0, 1000)) / 10000;
        uint256 amount = 1e12 + bound(amountSeed, 0, 1e18 - 1e12);

        rateProvider.setRate(rate);
        ISwapVM.Order memory order = _createOrder(_program(REF_RATE));
        _ship(order);

        _checkQuoteSwap(order, amount, true, true);
        _checkQuoteSwap(order, amount, false, true);
        _checkQuoteSwap(order, amount, true, false);
        _checkQuoteSwap(order, amount, false, false);

        // Round trip: in -> out -> back must never net the taker a positive stETH-like balance
        TokenMock(address(stEthLike)).mint(address(taker), amount + 10e18);
        TokenMock(address(wstEthLike)).mint(address(taker), amount + 10e18);
        uint256 stBefore = stEthLike.balanceOf(address(taker));

        (, uint256 out1) = taker.swap(order, amount, _takerData(true, true, false));
        taker.swap(order, out1, _takerData(false, true, false));

        uint256 stAfter = stEthLike.balanceOf(address(taker));
        assertLe(stAfter, stBefore, "round trip must not net taker a positive stETH-like balance");
    }

    function _checkQuoteSwap(ISwapVM.Order memory order, uint256 amount, bool stEthToWstEth, bool isExactIn) internal {
        uint256 snap = vm.snapshot();

        (, address tokenOut) = stEthToWstEth
            ? (address(stEthLike), address(wstEthLike))
            : (address(wstEthLike), address(stEthLike));
        uint256 balanceOut = _aquaBalanceOf(order, tokenOut);

        (uint256 qIn, uint256 qOut) = _quote(order, amount, stEthToWstEth, isExactIn);
        (uint256 sIn, uint256 sOut) = _performSwap(order, amount, stEthToWstEth, isExactIn, false);

        assertEq(sIn, qIn, "quote/swap amountIn mismatch");
        assertEq(sOut, qOut, "quote/swap amountOut mismatch");
        if (isExactIn) {
            assertLe(sOut, balanceOut, "amountOut must not exceed balanceOut");
        }

        vm.revertTo(snap);
    }
}

/// @notice MovingPegSwap with the wstETH-like token as the LOWER address (exercises the Lt/Gt flip)
contract MovingPegSwapFlipTest is MovingPegSwapAquaBase {
    function _configure() internal override {
        tokenGt = new TokenMock("stETH-like", "stETH-like");
        TokenMock w;
        do {
            w = new TokenMock("wstETH-like", "wstETH-like");
        } while (address(w) >= address(tokenGt));
        wstEthLike = w;
        stEthLike = tokenGt;
        tokenLt = wstEthLike;
        assertTrue(address(wstEthLike) < address(stEthLike), "wstETH-like must be lower");
    }

    // ===== M8: repeat M1 (one rate) with the Lt/Gt flip =====

    function test_M8_Flip_CenterTracksRate() public {
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory order = _createOrder(_program(REF_RATE));
        _ship(order);

        (uint256 amountIn, uint256 amountOut) = _quote(order, 1e12, true, true);
        assertEq(amountIn, 1e12);

        uint256 valueOut = amountOut * REF_RATE / ONE;
        assertApproxEqRel(valueOut, 1e12, 1e12, "value-for-value at center (flip)");
    }

    // ===== M8: repeat M2 with the Lt/Gt flip =====

    function test_M8_Flip_SameOrderHash_RateMoves() public {
        rateProvider.setRate(REF_RATE);
        ISwapVM.Order memory order = _createOrder(_program(REF_RATE));
        bytes32 h = _ship(order);
        bytes32 hashBefore = swapVM.hash(order);

        (uint256 in1, uint256 out1) = _performSwap(order, 1e12, true, true, false);
        assertGt(in1, 0);
        assertGt(out1, 0);

        rateProvider.setRate(WORLD_RATE);
        assertEq(swapVM.hash(order), hashBefore, "order hash must not change");

        (uint256 in2, uint256 out2) = _performSwap(order, 1e12, true, true, false);
        assertGt(in2, 0);
        assertGt(out2, 0);

        (uint256 balA, uint256 balB) = aqua.safeBalances(maker, address(swapVM), h, address(tokenLt), address(tokenGt));
        assertGt(balA, 0);
        assertGt(balB, 0);
    }
}
