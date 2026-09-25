// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "@swap-vm/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@swap-vm/libs/TakerTraits.sol";
import { Salt } from "@swap-vm/instructions/Controls.sol";

import { MockTaker } from "@swap-vm-test/mocks/MockTaker.sol";
import { dynamic } from "@swap-vm-test/utils/Dynamic.sol";

import { RateSpaceAquaRouter } from "../src/routers/RateSpaceAquaRouter.sol";
import { MovingPegSwap } from "../src/instructions/MovingPegSwap.sol";
import { RETHRateProvider } from "../src/rate-providers/RETHRateProvider.sol";
import { IRETH } from "../src/rate-providers/interfaces/IRETH.sol";
import { MockRETH } from "./mocks/MockRETH.sol";

contract RETHRateProviderTest is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant REF_RATE = 1.2e18;
    uint256 internal constant WIDTH = 50e27;   // owner-approved 2026-09-24
    uint16 internal constant MAX_DEV_BPS = 500; // owner-approved 2026-09-24

    Aqua internal aqua = new Aqua();
    RateSpaceAquaRouter internal swapVM;
    MockRETH internal mockRETH;
    RETHRateProvider internal provider;
    MockTaker internal taker;

    address internal maker;
    uint256 internal makerPK = 0x1234;

    TokenMock internal tokenA; // ETH-like, lower address
    TokenMock internal tokenB; // rETH-like, greater address

    function setUp() public {
        maker = vm.addr(makerPK);
        mockRETH = new MockRETH();
        mockRETH.setExchangeRate(REF_RATE);
        provider = new RETHRateProvider(IRETH(address(mockRETH)));

        swapVM = new RateSpaceAquaRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
        taker = new MockTaker(aqua, swapVM, address(this));

        tokenA = new TokenMock("ETH-like", "ETH-like");
        TokenMock b;
        do {
            b = new TokenMock("rETH-like", "rETH-like");
        } while (address(b) <= address(tokenA));
        tokenB = b;
    }

    function test_Constructor_StoresToken() public view {
        assertEq(address(provider.RETH()), address(mockRETH));
    }

    function test_Rate_ReadsGetExchangeRate() public {
        assertEq(provider.rate(), REF_RATE);
        mockRETH.setExchangeRate(1.05e18);
        assertEq(provider.rate(), 1.05e18);
    }

    function test_ZeroRate_RevertsThroughRouter() public {
        ISwapVM.Order memory order = _createOrder();
        _ship(order);

        // Sanity: works at the valid rate
        (, uint256 out) = _quote(order, 1e12);
        assertGt(out, 0);

        // Provider returning 0 must fail closed
        mockRETH.setExchangeRate(0);
        vm.expectRevert(abi.encodeWithSelector(MovingPegSwap.MovingPegSwapZeroRate.selector, address(provider)));
        ISwapVM(address(swapVM)).quote(order, 1e12, _takerData());
    }

    // ===== HELPERS =====

    function _createOrder() internal view returns (ISwapVM.Order memory) {
        bytes memory program = bytes.concat(
            MovingPegSwap.build(
                MovingPegSwap.anchorFor(6e18, ONE),
                MovingPegSwap.anchorFor(5e18, REF_RATE),
                WIDTH,
                ONE,
                REF_RATE,
                address(0),
                address(provider),
                MAX_DEV_BPS
            ),
            Salt.build(uint64(1))
        );

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

    function _ship(ISwapVM.Order memory order) internal {
        bytes32 orderHash = swapVM.hash(order);

        vm.startPrank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        tokenB.approve(address(aqua), type(uint256).max);
        bytes32 strategyHash = aqua.ship(
            address(swapVM),
            abi.encode(order),
            dynamic([address(tokenA), address(tokenB)]),
            dynamic([uint256(6e18), uint256(5e18)])
        );
        vm.stopPrank();
        assertEq(strategyHash, orderHash);
        tokenA.mint(maker, 6e18);
        tokenB.mint(maker, 5e18);
    }

    function _takerData() internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
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

    function _quote(ISwapVM.Order memory order, uint256 amount) internal returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = ISwapVM(address(swapVM)).quote(order, amount, _takerData());
    }
}
