// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { ISwapVM } from "@swap-vm/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@swap-vm/routers/AquaSwapVMRouter.sol";
import { SwapVM } from "@swap-vm/SwapVM.sol";
import { MakerTraitsLib } from "@swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@swap-vm/libs/TakerTraits.sol";
import { PeggedSwap } from "@swap-vm/instructions/PeggedSwap.sol";
import { FeeFlatIn } from "@swap-vm/instructions/FeeFlat.sol";
import { Salt } from "@swap-vm/instructions/Controls.sol";

import { MockTaker } from "@swap-vm-test/mocks/MockTaker.sol";
import { dynamic } from "@swap-vm-test/utils/Dynamic.sol";

import { RateSpaceAquaRouter } from "../../src/routers/RateSpaceAquaRouter.sol";
import { MovingPegSwap } from "../../src/instructions/MovingPegSwap.sol";
import { WstETHRateProvider } from "../../src/rate-providers/WstETHRateProvider.sol";
import { IWstETH } from "../../src/rate-providers/interfaces/IWstETH.sol";

interface IWETH9 {
    function deposit() external payable;
}

/// @notice Mainnet-fork proof: MovingPegSwap against REAL wstETH / WETH / Lido state.
/// @dev Uses 1inch's LIVE mainnet Aqua deployment (AQUA_LIVE, listed in the 1inch/aqua README).
///   1inch's deployed SwapVM router has a different swap ABI, so our RateSpaceAquaRouter and the
///   upstream AquaSwapVMRouter are deployed on the fork from the vendored source, both pointed at
///   the live Aqua.
/// @dev Requires MAINNET_RPC_URL. When it is unset every test here is SKIPPED (vm.skip), so the
///   default `forge test` keeps working offline.
contract MainnetForkTest is Test {
    // ===== Real mainnet addresses =====
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    /// @dev 1inch Aqua, live mainnet deployment
    address internal constant AQUA_LIVE = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;

    // ===== Pinned blocks / rates (measured with `cast call ... stEthPerToken() --block <n>`) =====
    uint256 internal constant BLOCK_T1 = 26052660;
    uint256 internal constant RATE_T1 = 1244787728742679575;
    /// @dev Last block BEFORE the Lido oracle report (AccountingOracle tx
    ///   0x4732fc5cb4a1f4abe1cb35b86a5933358d6c54cd488687a8a96b5045eb3eec95, stETH TokenRebased
    ///   emitted in block 26047293)
    uint256 internal constant BLOCK_A = 26047292;
    uint256 internal constant RATE_A = 1244710915700866902;
    /// @dev First block AFTER the report
    uint256 internal constant BLOCK_B = 26047293;
    uint256 internal constant RATE_B = 1244787728742679575;

    // ===== Owner-approved settings (LOCKED) =====
    uint256 internal constant WIDTH = 50e27;
    uint16 internal constant BAND = 500;
    uint24 internal constant FEE = 5000; // FeeFlatIn scale 1e7 -> 0.05%

    // ===== Test fixtures =====
    uint256 internal constant ONE = 1e18;
    uint256 internal constant DEP_WETH = 6e18; // WETH deposit per order; wstETH side value-balanced

    string internal rpcUrl;
    bool internal forkOn;

    Aqua internal aqua;
    RateSpaceAquaRouter internal router;
    AquaSwapVMRouter internal baseRouter;
    WstETHRateProvider internal provider;
    MockTaker internal taker;
    MockTaker internal baseTaker;

    uint256 internal constant MAKER_PK = 0x1234;
    address internal maker;
    uint64 internal saltNonce;

    function setUp() public {
        rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        forkOn = bytes(rpcUrl).length > 0;
        maker = vm.addr(MAKER_PK);
    }

    modifier onFork(uint256 blockNumber) {
        if (!forkOn) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl, blockNumber);
        assertEq(block.number, blockNumber, "fork block");
        _deploy();
        _;
    }

    // ===== Deployment / funding =====

    function _deploy() internal {
        assertTrue(WSTETH < WETH, "wstETH must be the lower address (tokenA)");
        assertGt(AQUA_LIVE.code.length, 0, "live Aqua has code at this block");
        aqua = Aqua(AQUA_LIVE);
        provider = new WstETHRateProvider(IWstETH(WSTETH));
        router = new RateSpaceAquaRouter(address(aqua), WETH, address(this), "SwapVM", "1.0.0");
        baseRouter = new AquaSwapVMRouter(address(aqua), WETH, address(this), "SwapVM", "1.0.0");
        taker = new MockTaker(aqua, router, address(this));
        baseTaker = new MockTaker(aqua, baseRouter, address(this));
    }

    /// @dev Real WETH: ETH via vm.deal, then WETH.deposit from `to`. Adds `amount` to the balance.
    function _fundWeth(address to, uint256 amount) internal {
        vm.deal(to, amount);
        vm.prank(to);
        IWETH9(WETH).deposit{ value: amount }();
    }

    /// @dev Real wstETH: forge-std `deal` (stdstore locates wstETH's balance slot). Adds `amount`.
    function _fundWstEth(address to, uint256 amount) internal {
        uint256 before = IERC20(WSTETH).balanceOf(to);
        deal(WSTETH, to, before + amount);
        assertEq(IERC20(WSTETH).balanceOf(to), before + amount, "wstETH deal");
    }

    function _depWst(uint256 rate) internal pure returns (uint256) {
        return DEP_WETH * ONE / rate; // value-balanced at `rate`
    }

    // ===== Programs / orders =====

    /// @dev Our order: [FeeFlatIn(fee)] + MovingPegSwap (wstETH = Lt with live provider, WETH = Gt static 1e18)
    function _ourProgram(uint256 refRateWst, uint256 depWst, uint16 band, bool withFee) internal returns (bytes memory) {
        bytes memory mps = MovingPegSwap.build(
            MovingPegSwap.anchorFor(depWst, refRateWst),
            MovingPegSwap.anchorFor(DEP_WETH, ONE),
            WIDTH,
            refRateWst,
            ONE,
            address(provider),
            address(0),
            band
        );
        return withFee
            ? bytes.concat(FeeFlatIn.build(FEE), mps, Salt.build(++saltNonce))
            : bytes.concat(mps, Salt.build(++saltNonce));
    }

    /// @dev Upstream baseline: PeggedSwap with rates 1:1 and anchors = deposits value-balanced at
    ///   `pegRate`, i.e. the peg is FROZEN at `pegRate` (same encoding as PeggedSwapBaseline.t.sol)
    function _baseProgram(uint256 depWst, bool withFee) internal returns (bytes memory) {
        bytes memory ps = PeggedSwap.build(depWst, DEP_WETH, WIDTH, 1, 1);
        return withFee
            ? bytes.concat(FeeFlatIn.build(FEE), ps, Salt.build(++saltNonce))
            : bytes.concat(ps, Salt.build(++saltNonce));
    }

    function _order(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: WSTETH,
            tokenB: WETH,
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

    /// @dev Ship on `app` and fund the maker with the real tokens backing it
    function _ship(SwapVM app, ISwapVM.Order memory order, uint256 depWst) internal returns (bytes32 h) {
        h = app.hash(order);
        _fundWstEth(maker, depWst);
        _fundWeth(maker, DEP_WETH);
        _approveMaker();
        vm.prank(maker);
        bytes32 strategyHash = aqua.ship(address(app), abi.encode(order), dynamic([WSTETH, WETH]), dynamic([depWst, DEP_WETH]));
        assertEq(strategyHash, h, "strategy hash");
    }

    function _approveMaker() internal {
        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(aqua), type(uint256).max);
        IERC20(WETH).approve(address(aqua), type(uint256).max);
        vm.stopPrank();
    }

    function _takerData(address takerAddr, bool wethToWst, bool isExactIn) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddr,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: !wethToWst, // tokenA = wstETH
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

    function _quote(SwapVM app, MockTaker t, ISwapVM.Order memory order, uint256 amount, bool wethToWst, bool isExactIn)
        internal
        returns (uint256 qIn, uint256 qOut)
    {
        (qIn, qOut,) = ISwapVM(address(app)).quote(order, amount, _takerData(address(t), wethToWst, isExactIn));
    }

    /// @dev Swap through MockTaker `t`; fund taker with real tokenIn; assert REAL ERC20 deltas on
    ///   taker AND maker equal the returned amounts
    function _swap(MockTaker t, ISwapVM.Order memory order, uint256 amount, bool wethToWst, bool isExactIn)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        (address tIn, address tOut) = wethToWst ? (WETH, WSTETH) : (WSTETH, WETH);
        if (tIn == WETH) _fundWeth(address(t), amount * 2 + 1e18);
        else _fundWstEth(address(t), amount * 2 + 1e18);

        uint256[4] memory b = [
            IERC20(tIn).balanceOf(address(t)),
            IERC20(tOut).balanceOf(address(t)),
            IERC20(tIn).balanceOf(maker),
            IERC20(tOut).balanceOf(maker)
        ];

        (amountIn, amountOut) = t.swap(order, amount, _takerData(address(t), wethToWst, isExactIn));

        assertEq(b[0] - IERC20(tIn).balanceOf(address(t)), amountIn, "taker tokenIn delta");
        assertEq(IERC20(tOut).balanceOf(address(t)) - b[1], amountOut, "taker tokenOut delta");
        assertEq(IERC20(tIn).balanceOf(maker) - b[2], amountIn, "maker tokenIn delta");
        assertEq(b[3] - IERC20(tOut).balanceOf(maker), amountOut, "maker tokenOut delta");
    }

    /// @dev WETH-value gain of a WETH->wstETH exactIn taker at world rate `rate`
    function _gain(uint256 amountIn, uint256 amountOut, uint256 rate) internal pure returns (int256) {
        return int256(amountOut * rate / ONE) - int256(amountIn);
    }

    // =====================================================================
    // T1: live rate
    // =====================================================================

    function test_T1_LiveRate() public onFork(BLOCK_T1) {
        uint256 direct = IWstETH(WSTETH).stEthPerToken();
        uint256 viaProvider = provider.rate();
        emit log_named_uint("T1 block", block.number);
        emit log_named_uint("T1 wstETH.stEthPerToken()", direct);
        emit log_named_uint("T1 provider.rate()", viaProvider);
        emit log_named_address("T1 aqua (live 1inch)", address(aqua));
        emit log_named_uint("T1 aqua code bytes", address(aqua).code.length);
        emit log_named_bytes32("T1 aqua codehash", address(aqua).codehash);
        assertEq(viaProvider, direct, "provider == wstETH");
        assertEq(direct, RATE_T1, "pinned rate");
    }

    // =====================================================================
    // T2: real-token lifecycle
    // =====================================================================

    function test_T2_RealTokenLifecycle() public onFork(BLOCK_T1) {
        uint256 live = provider.rate();
        uint256 depWst = _depWst(live);
        ISwapVM.Order memory order = _order(_ourProgram(live, depWst, BAND, true));
        bytes32 h = _ship(router, order, depWst);
        emit log_named_uint("T2 live rate", live);
        emit log_named_uint("T2 deposit wstETH", depWst);
        emit log_named_uint("T2 deposit WETH", DEP_WETH);

        // WETH -> wstETH exactIn
        (uint256 qIn, uint256 qOut) = _quote(router, taker, order, 0.1e18, true, true);
        (uint256 aIn, uint256 aOut) = _swap(taker, order, 0.1e18, true, true);
        assertEq(aIn, qIn, "exactIn quote == swap (in)");
        assertEq(aOut, qOut, "exactIn quote == swap (out)");
        assertEq(aIn, 0.1e18);
        assertGt(aOut, 0);
        emit log_named_uint("T2 exactIn WETH in", aIn);
        emit log_named_uint("T2 exactIn wstETH out", aOut);

        // wstETH -> WETH exactOut (0.05 WETH, far from full reserve)
        (qIn, qOut) = _quote(router, taker, order, 0.05e18, false, false);
        (aIn, aOut) = _swap(taker, order, 0.05e18, false, false);
        assertEq(aIn, qIn, "exactOut quote == swap (in)");
        assertEq(aOut, qOut, "exactOut quote == swap (out)");
        assertEq(aOut, 0.05e18);
        emit log_named_uint("T2 exactOut wstETH in", aIn);
        emit log_named_uint("T2 exactOut WETH out", aOut);

        (uint256 balWst, uint256 balWeth) = aqua.safeBalances(maker, address(router), h, WSTETH, WETH);
        emit log_named_uint("T2 aqua wstETH after", balWst);
        emit log_named_uint("T2 aqua WETH after", balWeth);

        // close
        vm.prank(maker);
        aqua.dock(address(router), h, dynamic([WSTETH, WETH]));

        _fundWeth(address(taker), 1e18);
        bytes memory td = _takerData(address(taker), true, true);
        vm.expectRevert(abi.encodeWithSelector(
            IAqua.SafeBalancesForTokenNotInActiveStrategy.selector, maker, address(router), h, WETH
        ));
        taker.swap(order, 0.01e18, td);
    }

    // =====================================================================
    // T3: real Lido rate change, no strategy re-creation
    // =====================================================================

    struct T3Orders {
        ISwapVM.Order ours;
        ISwapVM.Order oursNoFee;
        ISwapVM.Order base;
        ISwapVM.Order baseNoFee;
        bytes32 hOurs;
        bytes32 hBase;
    }

    function test_T3_RealRateChange_NoReship() public onFork(BLOCK_A) {
        assertEq(provider.rate(), RATE_A, "rate at A");
        uint256 depWst = _depWst(RATE_A);

        T3Orders memory o;
        o.ours = _order(_ourProgram(RATE_A, depWst, BAND, true));
        o.oursNoFee = _order(_ourProgram(RATE_A, depWst, BAND, false));
        o.base = _order(_baseProgram(depWst, true));
        o.baseNoFee = _order(_baseProgram(depWst, false));
        o.hOurs = _ship(router, o.ours, depWst);
        _ship(router, o.oursNoFee, depWst);
        o.hBase = _ship(baseRouter, o.base, depWst);
        _ship(baseRouter, o.baseNoFee, depWst);

        // Sanity at A: both designs price near the same center (value-for-value at rate(A))
        (, uint256 oursA) = _quote(router, taker, o.oursNoFee, 1e12, true, true);
        (, uint256 baseA) = _quote(baseRouter, baseTaker, o.baseNoFee, 1e12, true, true);
        emit log_named_uint("T3 @A ours(no fee) 1e12 WETH -> wstETH", oursA);
        emit log_named_uint("T3 @A base(no fee) 1e12 WETH -> wstETH", baseA);

        // Keep deployed contracts + maker across the roll; token/Lido storage comes from block B
        address[] memory keep = new address[](7);
        keep[0] = address(aqua);
        keep[1] = address(router);
        keep[2] = address(baseRouter);
        keep[3] = address(provider);
        keep[4] = address(taker);
        keep[5] = address(baseTaker);
        keep[6] = maker;
        vm.makePersistent(keep);

        uint256 makerWethBeforeRoll = IERC20(WETH).balanceOf(maker);
        vm.rollFork(BLOCK_B);
        assertEq(block.number, BLOCK_B, "rolled to B");
        uint256 makerWethAfterRoll = IERC20(WETH).balanceOf(maker);
        emit log_named_uint("T3 maker WETH before roll (A, test-funded)", makerWethBeforeRoll);
        emit log_named_uint("T3 maker WETH after roll (B, real state)", makerWethAfterRoll);

        // Contracts and Aqua state survived; the rate is block B's real Lido rate
        assertEq(provider.rate(), RATE_B, "rate at B");
        assertEq(IWstETH(WSTETH).stEthPerToken(), RATE_B, "wstETH at B");
        assertEq(router.hash(o.ours), o.hOurs, "same order hash");
        (uint256 bw, uint256 be) = aqua.safeBalances(maker, address(router), o.hOurs, WSTETH, WETH);
        assertEq(bw, depWst, "aqua wstETH kept");
        assertEq(be, DEP_WETH, "aqua WETH kept");

        // Token balances/approvals live in WETH/wstETH storage, which the roll replaced with block
        // B's state: re-fund the maker to exactly what the four orders need (test funding only)
        if (makerWethAfterRoll < 4 * DEP_WETH) _fundWeth(maker, 4 * DEP_WETH - makerWethAfterRoll);
        uint256 makerWst = IERC20(WSTETH).balanceOf(maker);
        if (makerWst < 4 * depWst) _fundWstEth(maker, 4 * depWst - makerWst);
        _approveMaker();

        emit log_named_uint("T3 rate(A)", RATE_A);
        emit log_named_uint("T3 rate(B)", RATE_B);

        // Center price at B (ours, with fee): tiny exactIn, value-for-value at rate(B) within 0.1%
        {
            (uint256 cIn, uint256 cOut) = _quote(router, taker, o.ours, 1e12, true, true);
            uint256 valueOut = cOut * RATE_B / ONE;
            emit log_named_uint("T3 @B ours center: 1e12 WETH -> wstETH", cOut);
            emit log_named_uint("T3 @B ours center: WETH-value out (rate B)", valueOut);
            assertEq(cIn, 1e12);
            assertApproxEqRel(valueOut, 1e12, 1e15, "center tracks rate(B) within 0.1% after fee");

            // The A->B move is below 0.1%, so the check above alone cannot tell a moving center from
            // a frozen one. Direct comparison (no fee on either): at A both quoted the same; at B
            // wstETH is worth more, so the moving center must give strictly LESS wstETH than the
            // frozen upstream peg.
            (, uint256 oursB) = _quote(router, taker, o.oursNoFee, 1e12, true, true);
            (, uint256 baseB) = _quote(baseRouter, baseTaker, o.baseNoFee, 1e12, true, true);
            emit log_named_uint("T3 @B ours(no fee) 1e12 WETH -> wstETH", oursB);
            emit log_named_uint("T3 @B base(no fee) 1e12 WETH -> wstETH", baseB);
            emit log_named_uint("T3 @B ours(no fee) WETH-value out (rate B)", oursB * RATE_B / ONE);
            emit log_named_uint("T3 @B base(no fee) WETH-value out (rate B)", baseB * RATE_B / ONE);
            assertEq(baseB, baseA, "frozen peg: upstream center did not move");
            assertLt(oursB, oursA, "moving peg: our center moved with the rate");
            assertLt(oursB, baseB, "moving peg gives less wstETH than frozen peg at B");
        }

        // Stale-arb, 0.1 WETH -> wstETH exactIn, valued at rate(B)
        uint256 amt = 0.1e18;
        int256 gOurs;
        int256 gBase;
        {
            (uint256 qIn, uint256 qOut) = _quote(router, taker, o.ours, amt, true, true);
            (uint256 i1, uint256 o1) = _swap(taker, o.ours, amt, true, true);
            assertEq(i1, qIn, "quote == swap in @B (no re-ship)");
            assertEq(o1, qOut, "quote == swap out @B (no re-ship)");
            gOurs = _gain(i1, o1, RATE_B);
            emit log_named_uint("T3 @B ours(fee) wstETH out", o1);
        }
        {
            (uint256 i2, uint256 o2) = _swap(baseTaker, o.base, amt, true, true);
            gBase = _gain(i2, o2, RATE_B);
            emit log_named_uint("T3 @B base(fee) wstETH out", o2);
        }
        int256 gOursNoFee;
        int256 gBaseNoFee;
        {
            (uint256 i3, uint256 o3) = _swap(taker, o.oursNoFee, amt, true, true);
            gOursNoFee = _gain(i3, o3, RATE_B);
            (uint256 i4, uint256 o4) = _swap(baseTaker, o.baseNoFee, amt, true, true);
            gBaseNoFee = _gain(i4, o4, RATE_B);
        }
        emit log_named_int("T3 takerGain ours  (fee 0.05%) wei WETH-value", gOurs);
        emit log_named_int("T3 takerGain base  (fee 0.05%) wei WETH-value", gBase);
        emit log_named_int("T3 takerGain ours  (no fee)    wei WETH-value", gOursNoFee);
        emit log_named_int("T3 takerGain base  (no fee)    wei WETH-value", gBaseNoFee);

        assertLt(gOurs, gBase, "ours < baseline (same fee)");
        assertLt(gOursNoFee, gBaseNoFee, "ours < baseline (no fee)");
    }

    // =====================================================================
    // T4: band guard on real data
    // =====================================================================

    function test_T4_BandGuard_RealRate() public onFork(BLOCK_B) {
        uint256 live = provider.rate();
        assertEq(live, RATE_B, "rate at B");

        // |rate(B)/rate(A) - 1| in bps (x100 for resolution)
        uint256 diff = RATE_B > RATE_A ? RATE_B - RATE_A : RATE_A - RATE_B;
        emit log_named_uint("T4 |rate(B)-rate(A)| wei", diff);
        emit log_named_uint("T4 drift, 1e-6 bps units", diff * 1e10 / RATE_A);
        assertLe(diff * 10000, RATE_A * BAND, "drift within 500 bps");

        // refRate = rate(A), band 500 -> still trades at B
        uint256 depWstA = _depWst(RATE_A);
        ISwapVM.Order memory inBand = _order(_ourProgram(RATE_A, depWstA, BAND, true));
        _ship(router, inBand, depWstA);
        (uint256 aIn, uint256 aOut) = _swap(taker, inBand, 0.1e18, true, true);
        emit log_named_uint("T4 in-band order: WETH in", aIn);
        emit log_named_uint("T4 in-band order: wstETH out", aOut);
        assertGt(aOut, 0);

        // refRate = rate(B) * 0.9 -> 10% away, band 500 -> reverts
        uint256 farRef = RATE_B * 9 / 10;
        uint256 depWstFar = _depWst(farRef);
        ISwapVM.Order memory outBand = _order(_ourProgram(farRef, depWstFar, BAND, true));
        _ship(router, outBand, depWstFar);
        bytes memory err = abi.encodeWithSelector(
            MovingPegSwap.MovingPegSwapRateOutOfBand.selector, address(provider), RATE_B, farRef, uint256(BAND)
        );
        bytes memory td = _takerData(address(taker), true, true);
        vm.expectRevert(err);
        ISwapVM(address(router)).quote(outBand, 0.1e18, td);

        _fundWeth(address(taker), 1e18);
        vm.expectRevert(err);
        taker.swap(outBand, 0.1e18, td);
        emit log_named_uint("T4 out-of-band refRate", farRef);
    }

    // =====================================================================
    // T5: gas
    // =====================================================================

    function test_T5_Gas() public onFork(BLOCK_B) {
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory ours = _order(_ourProgram(RATE_B, depWst, BAND, true));
        ISwapVM.Order memory base = _order(_baseProgram(depWst, false));
        ISwapVM.Order memory baseFee = _order(_baseProgram(depWst, true));
        _ship(router, ours, depWst);
        _ship(baseRouter, base, depWst);
        _ship(baseRouter, baseFee, depWst);

        _fundWeth(address(taker), 10e18);
        _fundWeth(address(baseTaker), 10e18);
        bytes memory td = _takerData(address(taker), true, true);
        bytes memory btd = _takerData(address(baseTaker), true, true);

        // Warm-up swap on each order so all three measurements see the same warm storage
        taker.swap(ours, 0.01e18, td);
        baseTaker.swap(base, 0.01e18, btd);
        baseTaker.swap(baseFee, 0.01e18, btd);

        uint256 g = gasleft();
        taker.swap(ours, 0.1e18, td);
        uint256 gasOurs = g - gasleft();

        g = gasleft();
        baseTaker.swap(base, 0.1e18, btd);
        uint256 gasBase = g - gasleft();

        g = gasleft();
        baseTaker.swap(baseFee, 0.1e18, btd);
        uint256 gasBaseFee = g - gasleft();

        emit log_named_uint("T5 gas ours (FeeFlatIn + MovingPegSwap, RateSpaceAquaRouter)", gasOurs);
        emit log_named_uint("T5 gas upstream PeggedSwap (AquaSwapVMRouter)", gasBase);
        emit log_named_uint("T5 gas upstream FeeFlatIn + PeggedSwap (AquaSwapVMRouter)", gasBaseFee);
    }
}
