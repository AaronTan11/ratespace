// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@swap-vm-v1/routers/AquaSwapVMRouter.sol";

import { MovingPegExtruction } from "../../src/extruction/MovingPegExtruction.sol";
import { MovingPegSwap } from "../../src/instructions/MovingPegSwap.sol";
import { RateSpaceOrderBuilder } from "../../src/demo/RateSpaceOrderBuilder.sol";
import { DemoWETH } from "../../src/demo/mocks/DemoWETH.sol";
import { DemoYieldToken } from "../../src/demo/mocks/DemoYieldToken.sol";
import { DemoRateFeed } from "../../src/demo/mocks/DemoRateFeed.sol";

import { DeployDemo } from "../../script/DeployDemo.s.sol";

/// @dev Inherits the demo script and exposes its internal `_ship` and constants. The harness itself is the
///   maker: `_ship` calls `aqua.ship` from the harness, exactly as the script does from the broadcast key.
contract DeployDemoHarness is DeployDemo {
    function fee1e9() external pure returns (uint32) { return FEE_1E9; }
    function makerWeth() external pure returns (uint256) { return MAKER_WETH; }
    function rateWstEth() external pure returns (uint256) { return RATE_WSTETH; }
    function width() external pure returns (uint256) { return WIDTH; }
    function band() external pure returns (uint16) { return BAND; }

    function approveAqua(Deployed memory d) external {
        d.weth.approve(address(d.aqua), type(uint256).max);
        d.tokens[0].approve(address(d.aqua), type(uint256).max);
    }

    function ship(Deployed memory d, uint256 k, uint256 yieldDeposit, uint32 fee, uint64 salt)
        external
        returns (ShippedOrder memory)
    {
        return _ship(d, address(this), k, yieldDeposit, fee, salt);
    }
}

/// @notice LOCAL (no network): DeployDemo's `_ship` + constants, on the v1.0.2 router, in BOTH token address
///   orderings (yield token = Lt and yield token = Gt).
contract DeployDemoTest is Test {
    uint256 internal constant ONE = 1e18;
    /// @dev From test/SharedLiquidity.t.sol G3 market 0 (0x59 router): 1e18 wstETH-like sold into 10e18 WETH /
    ///   8033498217483780461 wstETH-like at 1244787728742679575
    uint256 internal constant SHARED_LIQ_OUT = 1244017430410107798;
    uint256 internal constant DEPOSIT = 8033498217483780461;
    uint256 internal constant SELL = 1e18;

    address internal constant LOW = address(uint160(0x100000));
    address internal constant HIGH = address(uint160(0x200000));

    struct Case {
        DeployDemoHarness h;
        DeployDemo.Deployed d;
        DeployDemo.ShippedOrder plain;
        DeployDemo.ShippedOrder fee;
    }

    function _deploy(bool yieldIsLt) internal returns (Case memory c) {
        (address wethAt, address yieldAt) = yieldIsLt ? (HIGH, LOW) : (LOW, HIGH);
        deployCodeTo("DemoWETH.sol:DemoWETH", "", wethAt);
        deployCodeTo("DemoYieldToken.sol:DemoYieldToken", abi.encode("Demo wstETH", "wstETH"), yieldAt);

        c.h = new DeployDemoHarness();
        c.d.aqua = new Aqua();
        c.d.weth = DemoWETH(payable(wethAt));
        c.d.router = new AquaSwapVMRouter(address(c.d.aqua), wethAt, address(this), "1inch SwapVM v1.0", "1.0.2");
        c.d.target = new MovingPegExtruction();
        c.d.builder = new RateSpaceOrderBuilder();
        c.d.tokens[0] = DemoYieldToken(yieldAt);
        c.d.feeds[0] = new DemoRateFeed(c.h.rateWstEth());

        assertEq(c.d.tokens[0].symbol(), "wstETH", "yield token deployed");
        assertEq(c.d.weth.symbol(), "WETH", "DemoWETH deployed");
        assertEq(address(c.d.tokens[0]) < address(c.d.weth), yieldIsLt, "address ordering");
        emit log_named_address(yieldIsLt ? "[yield=Lt] yield token" : "[yield=Gt] yield token", yieldAt);
        emit log_named_address(yieldIsLt ? "[yield=Lt] DemoWETH" : "[yield=Gt] DemoWETH", wethAt);

        // Maker (the harness) funding, as in DeployDemo.run()
        uint256 rate = c.d.feeds[0].rate();
        assertEq(rate, 1244787728742679575, "RATE_WSTETH");
        uint256 deposit = c.h.makerWeth() * ONE / rate;
        assertEq(c.h.makerWeth(), 10e18, "MAKER_WETH");
        assertEq(deposit, DEPOSIT, "yield deposit = MAKER_WETH * 1e18 / rate");
        c.d.weth.mint(address(c.h), c.h.makerWeth());
        c.d.tokens[0].mint(address(c.h), deposit);
        c.h.approveAqua(c.d);

        c.plain = c.h.ship(c.d, 0, deposit, 0, 1);
        c.fee = c.h.ship(c.d, 0, deposit, c.h.fee1e9(), 4);
        assertFalse(c.plain.hasFee, "order 1 no fee");
        assertTrue(c.fee.hasFee, "order 4 fee");
    }

    function _word(bytes memory b, uint256 off) internal pure returns (uint256 w) {
        require(b.length >= off + 32, "short program");
        assembly ("memory-safe") { w := mload(add(add(b, 32), off)) }
    }

    function _addrAt(bytes memory b, uint256 off) internal pure returns (address) {
        return address(uint160(_word(b, off) >> 96));
    }

    /// @dev Parses the Extruction instruction at `p` and checks every MovingPegSwap field against the
    ///   script's intent: yield anchor = anchorFor(deposit, rate), WETH anchor = 10e18, Lt/Gt placement
    function _assertProgram(Case memory c, bytes memory program, uint256 p, bool yieldIsLt) internal view {
        assertEq(uint8(program[p]), 0x20, "Extruction opcode");
        assertEq(uint8(program[p + 1]), 222, "Extruction args length = 20 + 202");
        assertEq(_addrAt(program, p + 2), address(c.d.target), "target");
        uint256 a = p + 22;
        uint256 x0 = _word(program, a);
        uint256 y0 = _word(program, a + 32);
        uint256 rLt = _word(program, a + 96);
        uint256 rGt = _word(program, a + 128);
        address pLt = _addrAt(program, a + 160);
        address pGt = _addrAt(program, a + 180);
        uint16 band = (uint16(uint8(program[a + 200])) << 8) | uint16(uint8(program[a + 201]));

        uint256 rate = c.d.feeds[0].rate();
        uint256 yieldAnchor = MovingPegSwap.anchorFor(DEPOSIT, rate);
        (uint256 yA, uint256 wA) = yieldIsLt ? (x0, y0) : (y0, x0);
        assertEq(yA, yieldAnchor, "yield anchor = anchorFor(yieldDeposit, rate)");
        assertEq(wA, 10e18, "WETH anchor = 10e18");
        assertEq(MovingPegSwap.anchorFor(10e18, ONE), 10e18, "anchorFor(10e18, 1e18)");
        assertEq(_word(program, a + 64), c.h.width(), "width");
        assertEq(band, c.h.band(), "band");
        if (yieldIsLt) {
            assertEq(rLt, rate, "refRateLt = yield rate");
            assertEq(rGt, ONE, "refRateGt = 1e18");
            assertEq(pLt, address(c.d.feeds[0]), "providerLt = feed");
            assertEq(pGt, address(0), "providerGt = none");
        } else {
            assertEq(rLt, ONE, "refRateLt = 1e18");
            assertEq(rGt, rate, "refRateGt = yield rate");
            assertEq(pLt, address(0), "providerLt = none");
            assertEq(pGt, address(c.d.feeds[0]), "providerGt = feed");
        }
    }

    /// @dev EOA taker, pushMode (the app's path): sell `amount` yield token exactIn; asserts quote == swap
    function _sell(Case memory c, ISwapVM.Order memory order, uint256 amount, string memory seed) internal returns (uint256 aOut) {
        address eoa = vm.addr(uint256(keccak256(bytes(seed))));
        c.d.tokens[0].mint(eoa, amount);
        bytes memory td = c.d.builder.buildTakerData(eoa, true, true);
        vm.startPrank(eoa, eoa);
        c.d.tokens[0].approve(address(c.d.router), type(uint256).max);
        (, uint256 qOut,) = c.d.router.quote(order, address(c.d.tokens[0]), address(c.d.weth), amount, td);
        uint256 aIn;
        (aIn, aOut,) = c.d.router.swap(order, address(c.d.tokens[0]), address(c.d.weth), amount, td);
        vm.stopPrank();
        assertEq(aIn, amount, "exactIn amountIn");
        assertEq(aOut, qOut, "quote == swap");
        assertEq(c.d.weth.balanceOf(eoa), aOut, "EOA WETH delta");
    }

    function _run(bool yieldIsLt) internal returns (uint256 outPlain, uint256 outFee, uint256 outNoFeeReduced) {
        Case memory c = _deploy(yieldIsLt);
        _assertProgram(c, c.plain.program, 0, yieldIsLt);
        // Fee program: [21][4][feeBps u32] then the same Extruction instruction
        assertEq(uint8(c.fee.program[0]), 21, "flat fee opcode");
        assertEq(uint8(c.fee.program[1]), 4, "flat fee args length");
        assertEq(uint32(_word(c.fee.program, 2) >> 224), 500000, "fee bytes = 500000");
        _assertProgram(c, c.fee.program, 6, yieldIsLt);

        // v1.0.2 _flatFeeAmountInXD, exactIn: the swap instruction sees amountIn - ceil(amountIn * fee / 1e9)
        // (Fee.sol BPS = 1e9). Owner fee is the literal 500000 here, independent of the script's constant.
        uint256 reducedIn = SELL - Math.ceilDiv(SELL * 500000, 1e9);
        (, outNoFeeReduced,) = c.d.router.quote(
            c.plain.order, address(c.d.tokens[0]), address(c.d.weth), reducedIn,
            c.d.builder.buildTakerData(address(this), true, true)
        );

        outPlain = _sell(c, c.plain.order, SELL, "demo-taker-plain");
        outFee = _sell(c, c.fee.order, SELL, "demo-taker-fee");
        string memory tag = yieldIsLt ? "[yield=Lt]" : "[yield=Gt]";
        emit log_named_uint(string.concat(tag, " no-fee out for 1e18"), outPlain);
        emit log_named_uint(string.concat(tag, " fee out for 1e18"), outFee);
        emit log_named_uint(string.concat(tag, " no-fee quote for 1e18 - ceil(1e18 * 500000 / 1e9)"), outNoFeeReduced);
    }

    function test_DeployDemo_FeeConstant() public {
        DeployDemoHarness h = new DeployDemoHarness();
        assertEq(h.fee1e9(), 500000, "FEE_1E9 = 0.05% on the 1e9 scale");
        assertEq(uint256(h.fee1e9()) * 10000 / 1e9, 5, "5 bps");
    }

    function test_DeployDemo_BothOrderings() public {
        (uint256 pLt, uint256 fLt, uint256 rLt) = _run(true);
        (uint256 pGt, uint256 fGt, uint256 rGt) = _run(false);

        // (a) same amount both ways, equal to the SharedLiquidity number
        assertEq(pLt, pGt, "no-fee out: yield=Lt == yield=Gt");
        assertEq(pLt, SHARED_LIQ_OUT, "no-fee out = SharedLiquidity G3 market 0");
        // (b) fee order == no-fee order fed amountIn net of the v1.0.2 flat fee
        assertEq(fLt, rLt, "yield=Lt: fee out == no-fee out at the net amountIn");
        assertEq(fGt, rGt, "yield=Gt: fee out == no-fee out at the net amountIn");
        assertEq(fLt, fGt, "fee out: yield=Lt == yield=Gt");
        assertLt(fLt, pLt, "fee out < no-fee out");
        assertEq(fLt, FEE_OUT, "fee out pinned");
    }

    /// @dev Measured by test_DeployDemo_BothOrderings (fee order, 1e18 yield sold exactIn)
    uint256 internal constant FEE_OUT = 1243395810130833463;
}
