// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "@swap-vm/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@swap-vm/routers/AquaSwapVMRouter.sol";
import { MakerTraitsLib } from "@swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@swap-vm/libs/TakerTraits.sol";
import { PeggedSwap } from "@swap-vm/instructions/PeggedSwap.sol";
import { Salt } from "@swap-vm/instructions/Controls.sol";

import { MockTaker } from "@swap-vm-test/mocks/MockTaker.sol";
import { dynamic } from "@swap-vm-test/utils/Dynamic.sol";

/// @notice Baseline: upstream PeggedSwap through the upstream Aqua router, with a frozen peg.
///   Establishes the "before" picture for the stale-peg loss the MovingPegSwap demo removes.
contract PeggedSwapBaseline is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BAL_A = 6e18;   // stETH-like deposit (tokenA, lower address)
    uint256 internal constant BAL_B = 5e18;   // wstETH-like deposit (tokenB, greater address)
    uint256 internal constant WIDTH = 50e27;  // owner-approved 2026-09-24
    uint256 internal constant WORLD_RATE = 1.25e18; // world rate after ship (1 wstETH = 1.25 stETH)

    Aqua public immutable aqua = new Aqua();
    AquaSwapVMRouter public swapVM;

    TokenMock public tokenA; // stETH-like, lower address
    TokenMock public tokenB; // wstETH-like, greater address

    address public maker;
    uint256 public makerPK = 0x1234;
    MockTaker public taker;

    uint64 internal saltNonce;

    function setUp() public {
        maker = vm.addr(makerPK);

        tokenA = new TokenMock("stETH-like", "stETH-like");
        TokenMock w;
        do {
            w = new TokenMock("wstETH-like", "wstETH-like");
        } while (address(w) <= address(tokenA));
        tokenB = w;
        assertTrue(address(tokenA) < address(tokenB), "tokenA must be lower");

        swapVM = new AquaSwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
        taker = new MockTaker(aqua, swapVM, address(this));
    }

    // ===== HELPERS =====

    function _salt() internal returns (bytes memory) {
        return Salt.build(++saltNonce);
    }

    function _createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
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

    function _ship(ISwapVM.Order memory order) internal returns (bytes32) {
        bytes32 orderHash = swapVM.hash(order);

        vm.startPrank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        tokenB.approve(address(aqua), type(uint256).max);
        bytes32 strategyHash = aqua.ship(
            address(swapVM),
            abi.encode(order),
            dynamic([address(tokenA), address(tokenB)]),
            dynamic([BAL_A, BAL_B])
        );
        vm.stopPrank();
        tokenA.mint(maker, BAL_A);
        tokenB.mint(maker, BAL_B);

        assertEq(strategyHash, orderHash, "strategy hash mismatch");
        return strategyHash;
    }

    function _takerData(bool isAToB, bool isExactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: isExactIn,
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

    /// @notice Perform a swap and assert real ERC20 balance deltas on the taker side
    function _performSwap(
        ISwapVM.Order memory order,
        uint256 amount,
        bool zeroForOne,
        bool isExactIn
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        (address tokenIn, address tokenOut) = zeroForOne
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));

        TokenMock(tokenIn).mint(address(taker), amount * 2 + 10e18);
        uint256 inBefore = TokenMock(tokenIn).balanceOf(address(taker));
        uint256 outBefore = TokenMock(tokenOut).balanceOf(address(taker));

        (amountIn, amountOut) = taker.swap(order, amount, _takerData(zeroForOne, isExactIn));

        assertEq(inBefore - TokenMock(tokenIn).balanceOf(address(taker)), amountIn, "taker tokenIn delta");
        assertEq(TokenMock(tokenOut).balanceOf(address(taker)) - outBefore, amountOut, "taker tokenOut delta");
    }

    function _aquaBalances(bytes32 orderHash) internal view returns (uint256 balA, uint256 balB) {
        return aqua.safeBalances(maker, address(swapVM), orderHash, address(tokenA), address(tokenB));
    }

    // ===== B1: both directions, exactIn and exactOut, move real balances =====

    function test_B1_ExactIn_AToB() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(PeggedSwap.build(BAL_A, BAL_B, WIDTH, 1, 1), _salt()));
        bytes32 h = _ship(order);
        (uint256 balA0, uint256 balB0) = _aquaBalances(h);

        (uint256 amountIn, uint256 amountOut) = _performSwap(order, 0.5e18, true, true);

        assertGt(amountIn, 0);
        assertGt(amountOut, 0);
        (uint256 balA1, uint256 balB1) = _aquaBalances(h);
        assertEq(balA1 - balA0, amountIn, "aqua balanceIn delta");
        assertEq(balB0 - balB1, amountOut, "aqua balanceOut delta");
    }

    function test_B1_ExactOut_AToB() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(PeggedSwap.build(BAL_A, BAL_B, WIDTH, 1, 1), _salt()));
        bytes32 h = _ship(order);
        (uint256 balA0, uint256 balB0) = _aquaBalances(h);

        (uint256 amountIn, uint256 amountOut) = _performSwap(order, 0.5e18, true, false);

        assertEq(amountOut, 0.5e18, "exactOut returns requested");
        assertGt(amountIn, 0);
        (uint256 balA1, uint256 balB1) = _aquaBalances(h);
        assertEq(balA1 - balA0, amountIn, "aqua balanceIn delta");
        assertEq(balB0 - balB1, amountOut, "aqua balanceOut delta");
    }

    function test_B1_ExactIn_BToA() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(PeggedSwap.build(BAL_A, BAL_B, WIDTH, 1, 1), _salt()));
        bytes32 h = _ship(order);
        (uint256 balA0, uint256 balB0) = _aquaBalances(h);

        (uint256 amountIn, uint256 amountOut) = _performSwap(order, 0.5e18, false, true);

        assertGt(amountIn, 0);
        assertGt(amountOut, 0);
        (uint256 balA1, uint256 balB1) = _aquaBalances(h);
        assertEq(balB1 - balB0, amountIn, "aqua balanceIn delta");
        assertEq(balA0 - balA1, amountOut, "aqua balanceOut delta");
    }

    function test_B1_ExactOut_BToA() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(PeggedSwap.build(BAL_A, BAL_B, WIDTH, 1, 1), _salt()));
        bytes32 h = _ship(order);
        (uint256 balA0, uint256 balB0) = _aquaBalances(h);

        (uint256 amountIn, uint256 amountOut) = _performSwap(order, 0.5e18, false, false);

        assertEq(amountOut, 0.5e18, "exactOut returns requested");
        assertGt(amountIn, 0);
        (uint256 balA1, uint256 balB1) = _aquaBalances(h);
        assertEq(balB1 - balB0, amountIn, "aqua balanceIn delta");
        assertEq(balA0 - balA1, amountOut, "aqua balanceOut delta");
    }

    // ===== B2: stale-peg loss =====

    /// @notice Pool at rest, world rate 1.25. ExactIn 0.125 tokenA; the frozen 1.2 peg hands
    ///   the taker tokenB worth more than they paid.
    function test_B2_StalePeg_ExactIn_TakerGain() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(PeggedSwap.build(BAL_A, BAL_B, WIDTH, 1, 1), _salt()));
        _ship(order);

        (uint256 amountIn, uint256 amountOut) = _performSwap(order, 0.125e18, true, true);

        assertEq(amountIn, 0.125e18);
        uint256 worldValue = amountOut * WORLD_RATE / ONE;
        require(worldValue > amountIn, "baseline must show a taker gain");
        uint256 takerGain = worldValue - amountIn;

        emit log_named_uint("B2 amountOut tokenB", amountOut);
        emit log_named_uint("B2 takerGain (wei tokenA-value)", takerGain);
        assertGt(takerGain, 0, "stale peg must hand taker a gain");
    }

    /// @notice Pool at rest, world rate 1.25. ExactOut all 5 tokenB; the frozen 1.2 peg costs
    ///   less than fair value (5 * 1.25 = 6.25 tokenA).
    function test_B2_StalePeg_ExactOut_Shortfall() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(PeggedSwap.build(BAL_A, BAL_B, WIDTH, 1, 1), _salt()));
        _ship(order);

        (uint256 amountIn, uint256 amountOut) = _performSwap(order, BAL_B, true, false);

        assertEq(amountOut, BAL_B, "drained all tokenB");
        uint256 fairValue = BAL_B * WORLD_RATE / ONE;
        assertLt(amountIn, fairValue, "baseline cost must be below fair value");
        uint256 shortfall = fairValue - amountIn;

        emit log_named_uint("B2 exactOut amountIn tokenA", amountIn);
        emit log_named_uint("B2 shortfall (wei tokenA-value)", shortfall);
    }
}
