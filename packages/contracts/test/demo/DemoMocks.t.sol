// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DemoWETH } from "../../src/demo/mocks/DemoWETH.sol";
import { DemoYieldToken } from "../../src/demo/mocks/DemoYieldToken.sol";
import { DemoRateFeed } from "../../src/demo/mocks/DemoRateFeed.sol";

contract DemoMocksTest is Test {
    event RateSet(uint256 oldRate, uint256 newRate);

    function test_WETH_DepositWithdrawMint() public {
        DemoWETH w = new DemoWETH();
        assertEq(w.name(), "Wrapped Ether");
        assertEq(w.decimals(), 18);
        address u = address(0xB0B);
        vm.deal(u, 2 ether);
        vm.prank(u);
        w.deposit{ value: 1 ether }();
        assertEq(w.balanceOf(u), 1 ether);
        vm.prank(u);
        w.withdraw(0.4 ether);
        assertEq(w.balanceOf(u), 0.6 ether);
        assertEq(u.balance, 1.4 ether);
        w.mint(u, 5e18);
        assertEq(w.balanceOf(u), 5.6e18);
    }

    function test_YieldToken() public {
        DemoYieldToken t = new DemoYieldToken("Demo wstETH", "wstETH");
        assertEq(t.name(), "Demo wstETH");
        assertEq(t.symbol(), "wstETH");
        assertEq(t.decimals(), 18);
        t.mint(address(1), 7);
        assertEq(t.balanceOf(address(1)), 7);
    }

    function test_RateFeed_SetEmits() public {
        DemoRateFeed f = new DemoRateFeed(1244787728742679575);
        assertEq(f.rate(), 1244787728742679575);
        vm.expectEmit(address(f));
        emit RateSet(1244787728742679575, 1244912207515553843);
        f.set(1244912207515553843);
        assertEq(f.rate(), 1244912207515553843);
    }
}
