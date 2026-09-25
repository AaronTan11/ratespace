// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { SwapVM } from "@swap-vm-v1/SwapVM.sol";

import { MovingPegExtruction } from "../../src/extruction/MovingPegExtruction.sol";
import { MovingPegSwap } from "../../src/instructions/MovingPegSwap.sol";
import { WstETHRateProvider } from "../../src/rate-providers/WstETHRateProvider.sol";
import { IWstETH } from "../../src/rate-providers/interfaces/IWstETH.sol";
import { MockRateProvider } from "../mocks/MockRateProvider.sol";

import { ExtructionTestBase } from "../extruction/ExtructionTestBase.sol";

interface IWETH9 {
    function deposit() external payable;
}

interface IEip712 {
    function eip712Domain() external view returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
}

/// @notice Mainnet-fork proof: MovingPegSwap pricing on 1inch's LIVE AquaSwapVMRouter (v1.0.2) through the
///   Extruction opcode, against the LIVE Aqua, real WETH / wstETH and the real WstETHRateProvider.
/// @dev Requires MAINNET_RPC_URL. When it is unset or empty every test here is SKIPPED (vm.skip), so the
///   default `forge test` keeps working offline.
contract LiveRouterExtructionTest is ExtructionTestBase {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    /// @dev 1inch Aqua, live mainnet deployment
    address internal constant AQUA_LIVE = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    /// @dev 1inch AquaSwapVMRouter, live mainnet deployment (eip712Domain "1inch SwapVM v1.0" / "1.0.2")
    address internal constant ROUTER_LIVE = 0x111111338c5091E8440b67B168bAe16a668AC0De;

    /// @dev First block after the Lido report in MainnetFork.t.sol (BLOCK_B); stEthPerToken() = RATE_B
    uint256 internal constant BLOCK_B = 26047293;

    string internal rpcUrl;
    bool internal forkOn;

    function setUp() public {
        rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        forkOn = bytes(rpcUrl).length > 0;
    }

    modifier onFork() {
        if (!forkOn) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl, BLOCK_B);
        assertEq(block.number, BLOCK_B, "fork block");
        _deploy();
        _;
    }

    function _deploy() internal {
        wst = WSTETH;
        weth = WETH;
        aqua = Aqua(AQUA_LIVE);
        router = ISwapVM(ROUTER_LIVE);
        assertGt(AQUA_LIVE.code.length, 0, "live Aqua code");
        assertGt(ROUTER_LIVE.code.length, 0, "live router code");
        assertEq(address(SwapVM(payable(ROUTER_LIVE)).AQUA()), AQUA_LIVE, "router.AQUA == live Aqua");
        (, string memory name, string memory version,,,,) = IEip712(ROUTER_LIVE).eip712Domain();
        assertEq(name, "1inch SwapVM v1.0");
        assertEq(version, "1.0.2");
        wstProvider = address(new WstETHRateProvider(IWstETH(WSTETH)));
        _initV1();
    }

    /// @dev Real WETH: ETH via vm.deal, then WETH.deposit from `to`. Adds `amount` to the balance.
    function _fundWeth(address to, uint256 amount) internal override {
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

    function _fundWst(address to, uint256 amount) internal override {
        _fundWstEth(to, amount);
    }

    // ===== Q1: the live router dispatches opcode 0x20 to our target =====

    function test_Q1_LiveDispatchViaExtructionOpcode() public onFork {
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory order = _stdOrderV1(RATE_B, depWst, wstProvider, false);
        _shipV1(order, depWst);
        _fundWeth(address(taker), 1e18);
        vm.expectCall(address(target), abi.encodePacked(MovingPegExtruction.extruction.selector));
        (uint256 aIn, uint256 aOut) = taker.swap(order, WETH, WSTETH, 0.01e18, _tdV1(address(taker), true, false));
        emit log_named_uint("Q1 live swap via opcode 0x20: WETH in", aIn);
        emit log_named_uint("Q1 live swap via opcode 0x20: wstETH out", aOut);
        assertGt(aOut, 0);
    }

    // ===== Q3 + Q4: both directions, quote == swap, equal to our router to the wei =====

    function test_Q3_Q4_Sequence_LiveRouter_EqualsOurs() public onFork {
        assertEq(IWstETH(WSTETH).stEthPerToken(), RATE_B, "rate at BLOCK_B");
        assertEq(WstETHRateProvider(wstProvider).rate(), RATE_B);

        uint256[12] memory v = _sequenceV1(RATE_B, wstProvider);
        _assertEq12(v, _pinned(), "LIVE router + MovingPegExtruction vs pinned");

        // Our RateSpaceAquaRouter deployed on the fork against the same LIVE Aqua
        _initOurs();
        uint256[12] memory o = _sequenceOurs(RATE_B, wstProvider);
        _assertEq12(v, o, "LIVE router + MovingPegExtruction vs RateSpaceAquaRouter");
    }

    // ===== Q5: no router-level taker gate: an arbitrary fresh EOA fills directly =====

    function test_Q5_ArbitraryEoaTaker() public onFork {
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory order = _stdOrderV1(RATE_B, depWst, wstProvider, false);
        _shipV1(order, depWst);

        address eoa = vm.addr(uint256(keccak256("random-taker-eoa")));
        assertEq(eoa.code.length, 0, "EOA has no code");
        _fundWeth(eoa, 1e18);
        (uint256 qIn, uint256 qOut) = _quoteV1(order, 0.1e18, true, true);
        uint256 wstBefore = IERC20(WSTETH).balanceOf(eoa);
        vm.startPrank(eoa, eoa);
        IERC20(WETH).approve(ROUTER_LIVE, type(uint256).max);
        (uint256 aIn, uint256 aOut,) = router.swap(order, WETH, WSTETH, 0.1e18, _tdV1(eoa, true, true));
        vm.stopPrank();
        assertEq(aIn, qIn, "EOA amountIn == quote");
        assertEq(aOut, qOut, "EOA amountOut == quote");
        assertEq(IERC20(WSTETH).balanceOf(eoa) - wstBefore, aOut);
        emit log_named_address("Q5 EOA taker", eoa);
        emit log_named_uint("Q5 EOA WETH in", aIn);
        emit log_named_uint("Q5 EOA wstETH out", aOut);
    }

    // ===== Q6: gas (logged, not asserted) =====

    function test_Q6_Gas() public onFork {
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory fee = _stdOrderV1(RATE_B, depWst, wstProvider, true);
        ISwapVM.Order memory noFee = _stdOrderV1(RATE_B, depWst, wstProvider, false);
        _shipV1(fee, depWst);
        _shipV1(noFee, depWst);
        _fundWeth(address(taker), 10e18);
        bytes memory td = _tdV1(address(taker), true, false);

        // Warm both strategies so the measured swaps are not first-touch
        taker.swap(fee, WETH, WSTETH, 0.01e18, td);
        taker.swap(noFee, WETH, WSTETH, 0.01e18, td);

        uint256 g = gasleft();
        (, uint256 outFee) = taker.swap(fee, WETH, WSTETH, 0.1e18, td);
        uint256 gasFee = g - gasleft();
        g = gasleft();
        (, uint256 outNoFee) = taker.swap(noFee, WETH, WSTETH, 0.1e18, td);
        uint256 gasNoFee = g - gasleft();
        emit log_named_uint("Q6 gas LIVE router: flatFee + Extruction(MovingPeg)", gasFee);
        emit log_named_uint("Q6 gas LIVE router: Extruction(MovingPeg)", gasNoFee);
        emit log_named_uint("Q6 out (fee) wstETH", outFee);
        emit log_named_uint("Q6 out (no fee) wstETH", outNoFee);
    }

    // ===== Q7: guards revert with our selectors in both quote and swap =====

    function _expectGuard(ISwapVM.Order memory order, bytes memory err) internal {
        bytes memory td = _tdV1(address(taker), true, false);
        vm.expectRevert(err);
        router.quote(order, WETH, WSTETH, 0.1e18, td);
        _fundWeth(address(taker), 1e18);
        vm.expectRevert(err);
        taker.swap(order, WETH, WSTETH, 0.1e18, td);
    }

    function test_Q7_BandGuard() public onFork {
        uint256 farRef = RATE_B * 9 / 10;
        uint256 depWst = _depWst(farRef);
        ISwapVM.Order memory order = _stdOrderV1(farRef, depWst, wstProvider, false);
        _shipV1(order, depWst);
        _expectGuard(order, abi.encodeWithSelector(
            MovingPegExtruction.MovingPegSwapRateOutOfBand.selector, wstProvider, RATE_B, farRef, uint256(BAND)
        ));
    }

    function test_Q7_BandCapAtExec() public onFork {
        uint256 depWst = _depWst(RATE_B);
        bytes memory raw = abi.encodePacked(
            MovingPegSwap.anchorFor(depWst, RATE_B), MovingPegSwap.anchorFor(DEP_WETH, ONE), WIDTH, RATE_B, ONE,
            wstProvider, address(0), uint16(1001)
        );
        ISwapVM.Order memory order = _orderV1(_programV1(_ins(opExtruction, abi.encodePacked(address(target), raw)), false));
        _shipV1(order, depWst);
        _expectGuard(order, abi.encodeWithSelector(MovingPegExtruction.MovingPegSwapInvalidMaxDeviation.selector, uint256(1001)));
    }

    function test_Q7_ZeroRate() public onFork {
        MockRateProvider zp = new MockRateProvider(); // rate() == 0 until set
        uint256 depWst = _depWst(RATE_B);
        ISwapVM.Order memory order = _stdOrderV1(RATE_B, depWst, address(zp), false);
        _shipV1(order, depWst);
        _expectGuard(order, abi.encodeWithSelector(MovingPegExtruction.MovingPegSwapZeroRate.selector, address(zp)));
    }
}
