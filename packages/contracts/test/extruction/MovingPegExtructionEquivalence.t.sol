// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@swap-vm-v1/routers/AquaSwapVMRouter.sol";

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
}
