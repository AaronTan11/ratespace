// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "@swap-vm/interfaces/ISwapVM.sol";
import { SwapVM } from "@swap-vm/SwapVM.sol";
import { RateSpaceRouter } from "../src/routers/RateSpaceRouter.sol";
import { MakerTraitsLib } from "@swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@swap-vm/libs/TakerTraits.sol";
import { DynamicBalances } from "@swap-vm/instructions/Balances.sol";
import { MovingPegSwap } from "../src/instructions/MovingPegSwap.sol";
import { MockRateProvider } from "./mocks/MockRateProvider.sol";

import { CoreInvariants } from "@swap-vm-test/invariants/CoreInvariants.t.sol";

/// @notice Full invariant battery for MovingPegSwap through the non-Aqua RateSpaceRouter
///   (FULL opcode set, DynamicBalances), mirroring the upstream PeggedSwap invariant harness.
///   Runs in BOTH directions: A→B (stETH-like live-rate token as output) and B→A (live-rate
///   token as input, where the amountIn ceilDiv differs from floor).
contract MovingPegSwapInvariants is Test, CoreInvariants {
    uint256 internal constant ONE = 1e18;
    uint16 internal constant MAX_DEV_BPS = 500; // owner-approved 2026-09-24

    Aqua public immutable aqua = new Aqua();
    RateSpaceRouter public swapVM;
    MockRateProvider public rateProvider;

    TokenMock public tokenA; // stETH-like, lower address
    TokenMock public tokenB; // wstETH-like, greater address

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);

        rateProvider = new MockRateProvider();
        rateProvider.setRate(1.2e18);
        swapVM = new RateSpaceRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("stETH-like", "stETH-like");
        TokenMock b;
        do {
            b = new TokenMock("wstETH-like", "wstETH-like");
        } while (address(b) <= address(tokenA));
        tokenB = b;

        tokenA.mint(maker, 1000000e18);
        tokenB.mint(maker, 1000000e18);
        tokenA.mint(taker, 1000000e18);
        tokenB.mint(taker, 1000000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ===== HARNESS =====

    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address /* tokenOut */,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        TokenMock(tokenIn).mint(taker, amount * 10);
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(order, amount, takerData);
        return (actualIn, actualOut);
    }

    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
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

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold,
        bool isAToB
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            allowPartialFill: false,
            threshold: thresholdData,
            to: address(this),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));

        return abi.encodePacked(takerTraits);
    }

    function _program(uint256 balanceA, uint256 balanceB, uint256 width, uint256 refRate) private view returns (bytes memory) {
        return bytes.concat(
            DynamicBalances.build(balanceA, balanceB),
            MovingPegSwap.build(
                MovingPegSwap.anchorFor(balanceA, ONE),
                MovingPegSwap.anchorFor(balanceB, refRate),
                width,
                ONE,
                refRate,
                address(0),
                address(rateProvider),
                MAX_DEV_BPS
            )
        );
    }

    function _configFor(
        ISwapVM.Order memory order,
        uint256[] memory testAmounts,
        uint256[] memory testAmountsExactOut,
        bool isAToB
    ) private view returns (InvariantConfig memory config) {
        config = createInvariantConfig(testAmounts, 1e15);
        if (testAmountsExactOut.length > 0) {
            config.testAmountsExactOut = testAmountsExactOut;
        }
        config.exactInTakerData = _signAndPackTakerData(order, true, 0, isAToB);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max, isAToB);
    }

    function _runConfig(ISwapVM.Order memory order, InvariantConfig memory config, bool isAToB) private {
        (address tokenIn, address tokenOut) = isAToB
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));
        assertAllInvariantsWithConfig(swapVM, order, tokenIn, tokenOut, config);
    }

    // ===== SCENARIOS =====

    function _emptyAmounts() private pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    /// @dev Scenario 1 (upstream test_PeggedSwap_Invariants): balanced 10000e18 pool.
    ///   `refRate` is baked into the order; `liveRate` is what the provider returns at test
    ///   time (equal for the round-rate matrix, different for off-reference probes).
    function _runScenario1(uint256 refRate, uint256 liveRate, uint256 width, bool isAToB) private {
        rateProvider.setRate(liveRate);
        uint256 balanceA = 10000e18;
        uint256 balanceB = 10000e18;

        ISwapVM.Order memory order = _createOrder(_program(balanceA, balanceB, width, refRate));

        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 100e18;
        testAmounts[1] = 500e18;
        testAmounts[2] = 1000e18;

        InvariantConfig memory config = _configFor(order, testAmounts, _emptyAmounts(), isAToB);
        _runConfig(order, config, isAToB);
    }

    /// @dev Scenario 2 (upstream test_PeggedSwap_ReverseDirection_Invariants): asymmetric pool
    function _runScenario2(uint256 refRate, uint256 liveRate, uint256 width, bool isAToB) private {
        rateProvider.setRate(liveRate);
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000000e18;
        (uint256 balanceIn, uint256 balanceOut) = isAToB ? (balanceA, balanceB) : (balanceB, balanceA);

        ISwapVM.Order memory order = _createOrder(_program(balanceA, balanceB, width, refRate));

        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = balanceIn / 100;
        testAmounts[1] = balanceIn / 20;
        testAmounts[2] = balanceIn / 10;

        uint256[] memory testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = balanceOut / 100;
        testAmountsExactOut[1] = balanceOut / 20;
        testAmountsExactOut[2] = balanceOut / 10;

        InvariantConfig memory config = _configFor(order, testAmounts, testAmountsExactOut, isAToB);
        _runConfig(order, config, isAToB);
    }

    /// @dev Scenario 3 (upstream test_PeggedSwap_ReverseDirection_Linear_Invariants): A = 0
    function _runScenario3(uint256 refRate, uint256 liveRate, bool isAToB) private {
        _runScenario2(refRate, liveRate, 0, isAToB);
    }

    function _rates() private pure returns (uint256[4] memory rates) {
        rates[0] = 1.0e18;
        rates[1] = 1.2e18;
        rates[2] = 1.25e18;
        rates[3] = 1.5e18;
    }

    function _widths() private pure returns (uint256[5] memory widths) {
        widths[0] = 0;
        widths[1] = 20e27;
        widths[2] = 50e27;
        widths[3] = 100e27;
        widths[4] = 300e27;
    }

    // ===== TESTS =====

    function test_MovingPegSwap_Invariants() public {
        uint256[4] memory rates = _rates();
        uint256[5] memory widths = _widths();
        for (uint256 r = 0; r < rates.length; r++) {
            for (uint256 w = 0; w < widths.length; w++) {
                _runScenario1(rates[r], rates[r], widths[w], true);
                _runScenario1(rates[r], rates[r], widths[w], false);
            }
        }
    }

    function test_MovingPegSwap_ReverseDirection_Invariants() public {
        uint256[4] memory rates = _rates();
        uint256[5] memory widths = _widths();
        for (uint256 r = 0; r < rates.length; r++) {
            for (uint256 w = 0; w < widths.length; w++) {
                _runScenario2(rates[r], rates[r], widths[w], true);
                _runScenario2(rates[r], rates[r], widths[w], false);
            }
        }
    }

    function test_MovingPegSwap_ReverseDirection_Linear_Invariants() public {
        uint256[4] memory rates = _rates();
        for (uint256 r = 0; r < rates.length; r++) {
            _runScenario3(rates[r], rates[r], true);
            _runScenario3(rates[r], rates[r], false);
        }
    }

    /// @notice B→A battery at a fractional, non-round reference rate (and off-reference live
    ///   rates inside the band). This is the direction where the exactOut amountIn ceilDiv is
    ///   distinguishable from floor, so a floor mutant is caught by the upstream rounding check.
    function test_MovingPegSwap_BtoA_FractionalRates_Invariants() public {
        uint256 fractional = 1_183_746_519_283_746_519; // non-round, in band of itself
        uint256[5] memory widths = _widths();
        for (uint256 w = 0; w < widths.length; w++) {
            _runScenario1(fractional, fractional, widths[w], false);
            _runScenario2(fractional, fractional, widths[w], false);
        }

        // off-reference live rates inside the 500 bps band around refRate 1.2e18
        uint256 refRate = 1.2e18;
        uint256[2] memory lives = [uint256(1_151_234_567_890_123_457), 1_243_210_987_654_321_987];
        for (uint256 i = 0; i < lives.length; i++) {
            for (uint256 w = 0; w < widths.length; w++) {
                _runScenario1(refRate, lives[i], widths[w], false);
            }
        }
    }

    /// @notice Ship at 1.20e18, run the battery, then move the live rate to 1.25e18 (in band)
    ///   and run the battery AGAIN on the same order, in both directions.
    function test_MovingPegSwap_RateMoves_Invariants() public {
        rateProvider.setRate(1.2e18);
        uint256 balanceA = 10000e18;
        uint256 balanceB = 10000e18;
        uint256 width = 50e27; // owner-approved 2026-09-24

        ISwapVM.Order memory order = _createOrder(_program(balanceA, balanceB, width, 1.2e18));

        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 100e18;
        testAmounts[1] = 500e18;
        testAmounts[2] = 1000e18;

        _runConfig(order, _configFor(order, testAmounts, _emptyAmounts(), true), true);
        _runConfig(order, _configFor(order, testAmounts, _emptyAmounts(), false), false);

        rateProvider.setRate(1.25e18);
        _runConfig(order, _configFor(order, testAmounts, _emptyAmounts(), true), true);
        _runConfig(order, _configFor(order, testAmounts, _emptyAmounts(), false), false);
    }
}
