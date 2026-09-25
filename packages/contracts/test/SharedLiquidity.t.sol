// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { SafeERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { ISwapVM } from "@swap-vm/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@swap-vm/libs/TakerTraits.sol";
import { Salt } from "@swap-vm/instructions/Controls.sol";

import { MockTaker } from "@swap-vm-test/mocks/MockTaker.sol";
import { dynamic } from "@swap-vm-test/utils/Dynamic.sol";

import { RateSpaceAquaRouter } from "../src/routers/RateSpaceAquaRouter.sol";
import { MovingPegSwap } from "../src/instructions/MovingPegSwap.sol";
import { MockRateProvider } from "./mocks/MockRateProvider.sol";

/// @notice Shared liquidity through Aqua: ONE maker wallet with 10e18 WETH-like backs THREE
///   MovingPegSwap orders (wstETH-like, rETH-like, weETH-like vs WETH-like). Each order is shipped
///   with a 10e18 WETH virtual balance, so the same 10e18 wallet balance is promised three times
///   (30e18 virtual). Aqua `pull` moves real tokens from the wallet at trade time, so when the
///   wallet runs short a trade fails closed even though its order's virtual balance still covers it.
contract SharedLiquidityTest is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant WIDTH = 50e27;    // owner-approved 2026-09-24
    uint16 internal constant MAX_DEV_BPS = 500; // owner-approved 2026-09-24
    uint256 internal constant WETH_WALLET = 10e18;
    uint256 internal constant SELL = 1e18;

    // Orchestrator-verified on-chain rates (brief): wstETH stEthPerToken, rETH getExchangeRate, weETH getRate
    uint256 internal constant RATE_WSTETH = 1244787728742679575;
    uint256 internal constant RATE_RETH = 1172468133468041111;
    uint256 internal constant RATE_WEETH = 1104406989873418608;

    Aqua internal aqua = new Aqua();
    RateSpaceAquaRouter internal swapVM;
    MockTaker internal taker;

    address internal maker;
    uint256 internal makerPK = 0x1234;

    TokenMock internal weth;          // static rate 1e18 side
    TokenMock[3] internal yieldTokens; // wstETH-like, rETH-like, weETH-like
    MockRateProvider[3] internal providers;
    uint256[3] internal rates;
    uint256[3] internal yieldDeposits;
    ISwapVM.Order[3] internal orders;

    uint64 internal saltNonce;

    function setUp() public {
        maker = vm.addr(makerPK);
        swapVM = new RateSpaceAquaRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
        taker = new MockTaker(aqua, swapVM, address(this));

        weth = new TokenMock("WETH-like", "WETH-like");
        yieldTokens[0] = new TokenMock("wstETH-like", "wstETH-like");
        yieldTokens[1] = new TokenMock("rETH-like", "rETH-like");
        yieldTokens[2] = new TokenMock("weETH-like", "weETH-like");
        rates = [RATE_WSTETH, RATE_RETH, RATE_WEETH];

        for (uint256 i = 0; i < 3; i++) {
            providers[i] = new MockRateProvider();
            providers[i].setRate(rates[i]);
            // Value-balanced: yieldDeposit * rate / 1e18 ~= 10e18 WETH value
            yieldDeposits[i] = WETH_WALLET * ONE / rates[i];
        }

        vm.startPrank(maker);
        weth.approve(address(aqua), type(uint256).max);
        for (uint256 i = 0; i < 3; i++) {
            yieldTokens[i].approve(address(aqua), type(uint256).max);
        }
        vm.stopPrank();

        for (uint256 i = 0; i < 3; i++) {
            orders[i] = _createOrder(i);
            _ship(i);
        }

        // Fund the ONE wallet: exactly 10e18 WETH (once, not per order) plus each yield deposit
        weth.mint(maker, WETH_WALLET);
        for (uint256 i = 0; i < 3; i++) {
            yieldTokens[i].mint(maker, yieldDeposits[i]);
        }
    }

    // ===== G.2: the same 10e18 wallet WETH is promised to three strategies =====

    function test_G2_ThreeStrategiesShareOneWethBalance() public {
        assertEq(weth.balanceOf(maker), WETH_WALLET, "wallet WETH");
        emit log_named_uint("G2 maker wallet WETH", weth.balanceOf(maker));

        uint256 totalVirtual;
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(address(yieldTokens[i]) != address(weth), "distinct tokens");
            uint256 virtualWeth = _aquaBalanceOf(i, address(weth));
            uint256 virtualYield = _aquaBalanceOf(i, address(yieldTokens[i]));
            assertEq(virtualWeth, WETH_WALLET, "virtual WETH per strategy");
            assertEq(virtualYield, yieldDeposits[i], "virtual yield per strategy");
            totalVirtual += virtualWeth;
            emit log_named_uint(string.concat("G2 strategy ", vm.toString(i), " virtual WETH"), virtualWeth);
            emit log_named_uint(string.concat("G2 strategy ", vm.toString(i), " virtual yield"), virtualYield);
        }
        assertTrue(address(yieldTokens[0]) != address(yieldTokens[1]), "distinct yield tokens 0/1");
        assertTrue(address(yieldTokens[1]) != address(yieldTokens[2]), "distinct yield tokens 1/2");
        assertTrue(address(yieldTokens[0]) != address(yieldTokens[2]), "distinct yield tokens 0/2");
        assertTrue(swapVM.hash(orders[0]) != swapVM.hash(orders[1]), "distinct strategies 0/1");
        assertTrue(swapVM.hash(orders[1]) != swapVM.hash(orders[2]), "distinct strategies 1/2");
        assertEq(totalVirtual, 3 * WETH_WALLET, "30e18 virtual WETH total");
        emit log_named_uint("G2 total virtual WETH", totalVirtual);
    }

    // ===== G.3: one wallet serves three markets =====

    function test_G3_OneWalletServesThreeMarkets() public {
        _sellOneOfEach();
    }

    // ===== G.4: shared backing fails closed when the wallet runs short =====

    function test_G4_WalletShortfall_RevertsFailClosed() public {
        _sellOneOfEach();

        uint256 walletWeth = weth.balanceOf(maker);
        uint256 virtualWeth0 = _aquaBalanceOf(0, address(weth));
        uint256 sellAmount = 6e18;

        // The order itself can price this trade (quote does not move tokens) ...
        (, uint256 quotedOut) = _quote(0, sellAmount);
        emit log_named_uint("G4 remaining wallet WETH", walletWeth);
        emit log_named_uint("G4 strategy 0 virtual WETH", virtualWeth0);
        emit log_named_uint("G4 sell amount (yield token 0)", sellAmount);
        emit log_named_uint("G4 attempted WETH out", quotedOut);
        // ... it needs more WETH than the wallet holds, but no more than the order's virtual balance
        assertGt(quotedOut, walletWeth, "attempt must exceed wallet WETH");
        assertLt(quotedOut, virtualWeth0, "attempt must fit the order's virtual WETH");

        yieldTokens[0].mint(address(taker), sellAmount);
        bytes memory takerData = _takerData(_isAToB(0));
        // Aqua.pull's safeTransferFrom hits ERC20InsufficientBalance in the token and wraps it as SafeTransferFromFailed()
        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        taker.swap(orders[0], sellAmount, takerData);

        // Counter-check: the revert is the wallet shortfall. Topping the wallet up by exactly the
        // shortfall makes the identical swap succeed (state restored afterwards).
        uint256 snap = vm.snapshotState();
        weth.mint(maker, quotedOut - walletWeth);
        (, uint256 out) = taker.swap(orders[0], sellAmount, takerData);
        assertEq(out, quotedOut, "same swap succeeds once the wallet covers it");
        assertEq(weth.balanceOf(maker), 0, "wallet drained exactly");
        vm.revertToState(snap);
        assertEq(weth.balanceOf(maker), walletWeth, "state restored");
    }

    // ===== G.5: rate step on one provider, same order hash, no re-ship =====

    function test_G5_RateStep_SameOrderHash() public {
        _sellOneOfEach();

        bytes32 hashBefore = swapVM.hash(orders[0]);
        (, uint256 outBefore) = _quote(0, SELL);

        uint256 bumped = rates[0] * 10001 / 10000; // +1 bps
        providers[0].setRate(bumped);
        assertEq(swapVM.hash(orders[0]), hashBefore, "order hash must not change");

        (, uint256 outAfter) = _quote(0, SELL);
        (, uint256 swapOut) = _performSwap(0, SELL);

        emit log_named_uint("G5 rate before", rates[0]);
        emit log_named_uint("G5 rate after (+1 bps)", bumped);
        emit log_named_uint("G5 WETH out for 1e18, before", outBefore);
        emit log_named_uint("G5 WETH out for 1e18, after", outAfter);
        assertGt(outAfter, outBefore, "output must rise with the rate");
        assertEq(swapOut, outAfter, "quote == swap after the step");
    }

    // ===== HELPERS =====

    /// @dev Sell 1e18 of each yield token into WETH and check the wallet paid exactly the sum
    function _sellOneOfEach() internal returns (uint256 sumOut) {
        uint256 walletBefore = weth.balanceOf(maker);
        for (uint256 i = 0; i < 3; i++) {
            uint256 implied = SELL * rates[i] / ONE;
            uint256 lowerBound = implied * 99 / 100;
            (uint256 amountIn, uint256 amountOut) = _performSwap(i, SELL);
            assertEq(amountIn, SELL, "exactIn amount");
            assertLt(amountOut, implied, "output below rate-implied value");
            assertGt(amountOut, lowerBound, "output above 0.99 x rate-implied value");
            emit log_named_uint(string.concat("G3 market ", vm.toString(i), " rate-implied WETH"), implied);
            emit log_named_uint(string.concat("G3 market ", vm.toString(i), " 0.99 lower bound"), lowerBound);
            emit log_named_uint(string.concat("G3 market ", vm.toString(i), " WETH out"), amountOut);
            emit log_named_uint(string.concat("G3 market ", vm.toString(i), " out/implied (1e18)"), amountOut * ONE / implied);
            sumOut += amountOut;
        }
        uint256 walletAfter = weth.balanceOf(maker);
        emit log_named_uint("G3 wallet WETH before", walletBefore);
        emit log_named_uint("G3 wallet WETH after", walletAfter);
        emit log_named_uint("G3 sum of outputs", sumOut);
        assertEq(walletBefore - walletAfter, sumOut, "wallet paid exactly the sum of outputs");
    }

    function _sorted(uint256 i) internal view returns (address tokenLt, address tokenGt, bool wethIsLt) {
        wethIsLt = address(weth) < address(yieldTokens[i]);
        (tokenLt, tokenGt) = wethIsLt
            ? (address(weth), address(yieldTokens[i]))
            : (address(yieldTokens[i]), address(weth));
    }

    function _deposits(uint256 i) internal view returns (uint256 depLt, uint256 depGt) {
        (,, bool wethIsLt) = _sorted(i);
        (depLt, depGt) = wethIsLt ? (WETH_WALLET, yieldDeposits[i]) : (yieldDeposits[i], WETH_WALLET);
    }

    function _program(uint256 i) internal returns (bytes memory) {
        (,, bool wethIsLt) = _sorted(i);
        (uint256 depLt, uint256 depGt) = _deposits(i);
        uint256 rateLt = wethIsLt ? ONE : rates[i];
        uint256 rateGt = wethIsLt ? rates[i] : ONE;
        address providerLt = wethIsLt ? address(0) : address(providers[i]);
        address providerGt = wethIsLt ? address(providers[i]) : address(0);

        return bytes.concat(
            MovingPegSwap.build(
                MovingPegSwap.anchorFor(depLt, rateLt),
                MovingPegSwap.anchorFor(depGt, rateGt),
                WIDTH,
                rateLt,
                rateGt,
                providerLt,
                providerGt,
                MAX_DEV_BPS
            ),
            Salt.build(++saltNonce)
        );
    }

    function _createOrder(uint256 i) internal returns (ISwapVM.Order memory) {
        (address tokenLt, address tokenGt,) = _sorted(i);
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: tokenLt,
            tokenB: tokenGt,
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
            program: _program(i)
        }));
    }

    function _ship(uint256 i) internal returns (bytes32 orderHash) {
        orderHash = swapVM.hash(orders[i]);
        (address tokenLt, address tokenGt,) = _sorted(i);
        (uint256 depLt, uint256 depGt) = _deposits(i);

        vm.prank(maker);
        bytes32 strategyHash = aqua.ship(
            address(swapVM),
            abi.encode(orders[i]),
            dynamic([tokenLt, tokenGt]),
            dynamic([depLt, depGt])
        );
        assertEq(strategyHash, orderHash, "strategy hash mismatch");
    }

    /// @dev Selling the yield token: A->B iff the yield token is the lower address
    function _isAToB(uint256 i) internal view returns (bool) {
        return address(yieldTokens[i]) < address(weth);
    }

    function _takerData(bool isAToB) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
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

    function _quote(uint256 i, uint256 amount) internal returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = ISwapVM(address(swapVM)).quote(orders[i], amount, _takerData(_isAToB(i)));
    }

    /// @notice Sell `amount` of yield token i into WETH and assert real ERC20 balance deltas
    function _performSwap(uint256 i, uint256 amount) internal returns (uint256 amountIn, uint256 amountOut) {
        TokenMock tokenIn = yieldTokens[i];
        tokenIn.mint(address(taker), amount);
        uint256 inBefore = tokenIn.balanceOf(address(taker));
        uint256 outBefore = weth.balanceOf(address(taker));
        uint256 makerYieldBefore = tokenIn.balanceOf(maker);

        (amountIn, amountOut) = taker.swap(orders[i], amount, _takerData(_isAToB(i)));

        assertEq(inBefore - tokenIn.balanceOf(address(taker)), amountIn, "taker tokenIn delta");
        assertEq(weth.balanceOf(address(taker)) - outBefore, amountOut, "taker WETH delta");
        assertEq(tokenIn.balanceOf(maker) - makerYieldBefore, amountIn, "maker yield delta");
    }

    function _aquaBalanceOf(uint256 i, address token) internal view returns (uint256) {
        (uint248 bal,) = aqua.rawBalances(maker, address(swapVM), swapVM.hash(orders[i]), token);
        return bal;
    }
}
