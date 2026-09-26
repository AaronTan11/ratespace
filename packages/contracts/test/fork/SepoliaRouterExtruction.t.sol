// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { SwapVM } from "@swap-vm-v1/SwapVM.sol";
import { AquaSwapVMRouter } from "@swap-vm-v1/routers/AquaSwapVMRouter.sol";
import { SwapQuery, SwapRegisters } from "@swap-vm-v1/libs/VM.sol";
import { IStaticExtruction } from "@swap-vm-v1/instructions/Extruction.sol";
import { MakerTraitsLib } from "@swap-vm-v1/libs/MakerTraits.sol";
import { MockTaker } from "@swap-vm-v1-test/mocks/MockTaker.sol";

import { MovingPegExtruction } from "../../src/extruction/MovingPegExtruction.sol";
import { MovingPegExtructionArgs } from "../../src/extruction/MovingPegExtructionArgs.sol";
import { MovingPegSwap } from "../../src/instructions/MovingPegSwap.sol";
import { WstETHRateProvider } from "../../src/rate-providers/WstETHRateProvider.sol";
import { IWstETH } from "../../src/rate-providers/interfaces/IWstETH.sol";
import { MockRateProvider } from "../mocks/MockRateProvider.sol";

import { ExtructionTestBase } from "../extruction/ExtructionTestBase.sol";

interface IWETH9Sepolia {
    function deposit() external payable;
}

interface IEip712Sepolia {
    function eip712Domain() external view returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
}

/// @notice Extruction target that reverts with what the router handed it. Used to locate the Extruction
///   opcode on a router whose table is unknown, and to observe the registers / program counter at dispatch.
contract ExtructionProbe is IStaticExtruction {
    error ProbeHit(bool isStaticContext, uint256 nextPC, uint256 amountIn, uint256 amountOut, uint256 argsLength);

    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata
    ) external pure returns (uint256, uint256, SwapRegisters memory) {
        revert ProbeHit(isStaticContext, nextPC, swap.amountIn, swap.amountOut, args.length);
    }
}

/// @notice Sepolia-fork proof: MovingPegSwap pricing on the 1inch AquaSwapVMRouter DEPLOYED ON SEPOLIA
///   (0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de) through its Extruction opcode, against the real Sepolia
///   Aqua, Lido's real Sepolia wstETH and the real WstETHRateProvider, at the latest Sepolia block.
/// @dev Differences from mainnet (test/fork/LiveRouterExtruction.t.sol):
///   - The mainnet router 0x111111338c5091E8440b67B168bAe16a668AC0De has NO code on Sepolia. The Sepolia router is
///     0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de: same eip712Domain ("1inch SwapVM v1.0" / "1.0.2") and the same
///     AQUA(), but different runtime bytecode (20379 bytes vs 20541 on mainnet).
///   - Its opcode table is therefore PROVEN here, not assumed: test_S1 scans all 256 opcodes and asserts that
///     Extruction dispatches only at MovingPegExtructionArgs.EXTRUCTION_OPCODE (0x20); test_S2 proves the
///     [opcode u8][len u8][args] wire format, salt at 0x14 (20) and the flat fee at 0x15 (21) on the 1e9 scale.
///   - The rate is Sepolia's live stEthPerToken() (not mainnet RATE_B), so there are no pinned amounts: the
///     Sepolia router is compared to the wei against RateSpaceAquaRouter and against a v1.0.2 AquaSwapVMRouter
///     built from lib/swap-vm-v1, both deployed on the same fork against the same Sepolia Aqua.
/// @dev Requires SEPOLIA_RPC_URL. When it is unset or empty every test here is SKIPPED (vm.skip), so the
///   default `forge test` keeps working offline. Read-only fork use; nothing is sent to any real network.
contract SepoliaRouterExtructionTest is ExtructionTestBase {
    /// @dev WETH9 on Sepolia ("Wrapped Ether" / "WETH")
    address internal constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    /// @dev Lido wstETH on Sepolia
    address internal constant WSTETH_SEPOLIA = 0xB82381A3fBD3FaFA77B3a7bE693342618240067b;
    /// @dev 1inch Aqua (same canonical address as mainnet)
    address internal constant AQUA_SEPOLIA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    /// @dev 1inch AquaSwapVMRouter deployed on Sepolia
    address internal constant ROUTER_SEPOLIA = 0x1111113Db0e0ef9D0E3A50d5f094a3a57a26C0DE;
    /// @dev The current mainnet router address (checked to have no code on Sepolia)
    address internal constant ROUTER_MAINNET = 0x111111338c5091E8440b67B168bAe16a668AC0De;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant PROBE_GAS = 5_000_000;

    string internal rpcUrl;
    bool internal forkOn;
    /// @dev Sepolia wstETH stEthPerToken() at the fork block
    uint256 internal rate;
    ExtructionProbe internal probe;

    function setUp() public {
        rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        forkOn = bytes(rpcUrl).length > 0;
    }

    modifier onFork() {
        if (!forkOn) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, SEPOLIA_CHAIN_ID, "Sepolia chain id");
        emit log_named_uint("Sepolia fork block", block.number);
        _deploy();
        _;
    }

    function _deploy() internal {
        wst = WSTETH_SEPOLIA;
        weth = WETH_SEPOLIA;
        aqua = Aqua(AQUA_SEPOLIA);
        router = ISwapVM(ROUTER_SEPOLIA);
        assertGt(AQUA_SEPOLIA.code.length, 0, "Sepolia Aqua code");
        assertGt(ROUTER_SEPOLIA.code.length, 0, "Sepolia router code");
        assertGt(WSTETH_SEPOLIA.code.length, 0, "Sepolia wstETH code");
        assertGt(WETH_SEPOLIA.code.length, 0, "Sepolia WETH code");
        assertEq(address(SwapVM(payable(ROUTER_SEPOLIA)).AQUA()), AQUA_SEPOLIA, "router.AQUA == Sepolia Aqua");
        (, string memory name, string memory version,,,,) = IEip712Sepolia(ROUTER_SEPOLIA).eip712Domain();
        assertEq(name, "1inch SwapVM v1.0");
        assertEq(version, "1.0.2");
        rate = IWstETH(WSTETH_SEPOLIA).stEthPerToken();
        wstProvider = address(new WstETHRateProvider(IWstETH(WSTETH_SEPOLIA)));
        assertEq(WstETHRateProvider(wstProvider).rate(), rate, "provider == stEthPerToken");
        emit log_named_uint("Sepolia wstETH stEthPerToken", rate);
        // Sets maker / target / taker and the LOCAL v1.0.2 table indexes (salt, flat fee, extruction);
        // test_S1 / test_S2 prove the same indexes on the Sepolia router itself.
        _initV1();
        probe = new ExtructionProbe();
    }

    /// @dev Real WETH9: ETH via vm.deal, then WETH.deposit from `to`. Adds `amount` to the balance.
    function _fundWeth(address to, uint256 amount) internal override {
        uint256 before = IERC20(WETH_SEPOLIA).balanceOf(to);
        vm.deal(to, amount);
        vm.prank(to);
        IWETH9Sepolia(WETH_SEPOLIA).deposit{ value: amount }();
        assertEq(IERC20(WETH_SEPOLIA).balanceOf(to), before + amount, "WETH deposit");
    }

    /// @dev Real wstETH: forge-std `deal` (stdstore locates wstETH's balance slot). Adds `amount`.
    function _fundWst(address to, uint256 amount) internal override {
        uint256 before = IERC20(WSTETH_SEPOLIA).balanceOf(to);
        deal(WSTETH_SEPOLIA, to, before + amount);
        assertEq(IERC20(WSTETH_SEPOLIA).balanceOf(to), before + amount, "wstETH deal");
    }

    // ===== Probe helpers =====

    /// @dev Signature-mode order (no Aqua lookup) so quote() runs the program without a shipped strategy
    function _probeOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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

    /// @dev quote() the program on the Sepolia router; returns the revert data (empty if it did not revert)
    function _probeQuote(bytes memory program, uint256 amount) internal view returns (bool reverted, bytes memory err) {
        try router.quote{ gas: PROBE_GAS }(_probeOrder(program), WETH_SEPOLIA, WSTETH_SEPOLIA, amount, _tdV1(address(taker), true, false))
        returns (uint256, uint256, bytes32) {
            return (false, "");
        } catch (bytes memory e) {
            return (true, e);
        }
    }

    function _isProbeHit(bytes memory err) internal pure returns (bool) {
        return err.length >= 4 && bytes4(err) == ExtructionProbe.ProbeHit.selector;
    }

    function _decodeHit(bytes memory err)
        internal
        pure
        returns (bool isStatic, uint256 nextPC, uint256 amountIn, uint256 amountOut, uint256 argsLength)
    {
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i = 0; i < body.length; i++) body[i] = err[i + 4];
        (isStatic, nextPC, amountIn, amountOut, argsLength) = abi.decode(body, (bool, uint256, uint256, uint256, uint256));
    }

    // ===== S0: chain facts =====

    function test_S0_SepoliaFacts() public onFork {
        assertEq(ROUTER_MAINNET.code.length, 0, "mainnet router address has no code on Sepolia");
        emit log_named_uint("Sepolia router code size", ROUTER_SEPOLIA.code.length);
        emit log_named_uint("Sepolia Aqua code size", AQUA_SEPOLIA.code.length);
        emit log_named_uint("Sepolia wstETH code size", WSTETH_SEPOLIA.code.length);
        emit log_named_uint("Sepolia WETH code size", WETH_SEPOLIA.code.length);
        assertEq(IERC20Metadata(WETH_SEPOLIA).symbol(), "WETH");
        assertEq(IERC20Metadata(WETH_SEPOLIA).name(), "Wrapped Ether");
        assertEq(IERC20Metadata(WSTETH_SEPOLIA).symbol(), "wstETH");
        assertLt(uint160(WSTETH_SEPOLIA), uint160(WETH_SEPOLIA), "wstETH is Lt");
    }

    // ===== S1: which opcode dispatches Extruction on the Sepolia router =====

    function test_S1_OpcodeScan_ExtructionIndex() public onFork {
        uint256 hits;
        uint256 found = type(uint256).max;
        for (uint256 op = 0; op < 256; op++) {
            (bool reverted, bytes memory err) = _probeQuote(_ins(uint8(op), abi.encodePacked(address(probe))), 1e18);
            if (reverted && _isProbeHit(err)) {
                hits++;
                found = op;
                emit log_named_uint("S1 Extruction dispatches at opcode", op);
            }
        }
        emit log_named_uint("S1 opcodes that dispatch Extruction (of 256)", hits);
        assertEq(hits, 1, "exactly one opcode dispatches Extruction");
        assertEq(found, MovingPegExtructionArgs.EXTRUCTION_OPCODE, "Sepolia Extruction opcode == 0x20");
        assertEq(found, opExtruction, "Sepolia index == local v1.0.2 table index");
    }

    // ===== S2: v1.0.2 wire format, salt (20) and flat fee (21, 1e9 scale) on the Sepolia router =====

    function test_S2_WireFormat_Salt_FlatFee() public onFork {
        assertEq(opSalt, 20, "local v1.0.2 salt index");
        assertEq(opFlatFee, 21, "local v1.0.2 flat fee index");
        bytes memory ext = _ins(opExtruction, abi.encodePacked(address(probe), hex"abcd"));

        // [0x20][22][probe(20) ++ 2 extra bytes]: target sees args.length 2, nextPC = 1 + 1 + 22 = 24
        (bool r0, bytes memory e0) = _probeQuote(ext, 1e18);
        assertTrue(r0 && _isProbeHit(e0), "bare extruction hit");
        (bool st0, uint256 pc0, uint256 in0,, uint256 len0) = _decodeHit(e0);
        assertTrue(st0, "quote runs in static context");
        assertEq(pc0, 24, "nextPC after [op][len u8][22 bytes]");
        assertEq(len0, 2, "args after the 20-byte target");
        assertEq(in0, 1e18, "amountIn untouched");
        emit log_named_uint("S2 bare extruction nextPC", pc0);

        // salt at 20: [0x14][8][nonce] is skipped, then the extruction: nextPC = 10 + 24 = 34
        (bool r1, bytes memory e1) = _probeQuote(bytes.concat(_ins(20, abi.encodePacked(uint64(7))), ext), 1e18);
        assertTrue(r1 && _isProbeHit(e1), "salt then extruction hit");
        (, uint256 pc1, uint256 in1,,) = _decodeHit(e1);
        assertEq(pc1, 34, "salt consumed as [0x14][8][8 bytes]");
        assertEq(in1, 1e18, "salt is a no-op");
        emit log_named_uint("S2 salt(20)+extruction nextPC", pc1);

        // flat fee at 21 with FEE_1E9 = 500000: exactIn amountIn seen by the next instruction is
        // 1e18 - ceil(1e18 * 500000 / 1e9) = 999500000000000000 (0.05% on the 1e9 scale)
        (bool r2, bytes memory e2) = _probeQuote(bytes.concat(_ins(21, abi.encodePacked(FEE_1E9)), ext), 1e18);
        assertTrue(r2 && _isProbeHit(e2), "flat fee then extruction hit");
        (, uint256 pc2, uint256 in2,,) = _decodeHit(e2);
        assertEq(pc2, 30, "flat fee consumed as [0x15][4][4 bytes]");
        assertEq(in2, 999500000000000000, "flat fee on the 1e9 scale");
        emit log_named_uint("S2 flatFee(21)+extruction amountIn seen", in2);
    }

    // ===== Q1: the Sepolia router dispatches opcode 0x20 to MovingPegExtruction in swap() =====

    function test_Q1_SepoliaDispatchViaExtructionOpcode() public onFork {
        uint256 depWst = _depWst(rate);
        ISwapVM.Order memory order = _stdOrderV1(rate, depWst, wstProvider, false);
        _shipV1(order, depWst);
        _fundWeth(address(taker), 1e18);
        vm.expectCall(address(target), abi.encodePacked(MovingPegExtruction.extruction.selector));
        (uint256 aIn, uint256 aOut) = taker.swap(order, WETH_SEPOLIA, WSTETH_SEPOLIA, 0.01e18, _tdV1(address(taker), true, false));
        emit log_named_uint("Q1 Sepolia swap via opcode 0x20: WETH in", aIn);
        emit log_named_uint("Q1 Sepolia swap via opcode 0x20: wstETH out", aOut);
        assertGt(aOut, 0);
    }

    // ===== Q3 + Q4: both directions, exactIn/exactOut, quote == swap, equal to ours and to v1.0.2 source =====

    function test_Q3_Q4_Sequence_SepoliaRouter_EqualsOurs_AndV102Source() public onFork {
        uint256[12] memory v = _sequenceV1(rate, wstProvider);

        // Our RateSpaceAquaRouter on the same fork, same Sepolia Aqua
        _initOurs();
        uint256[12] memory o = _sequenceOurs(rate, wstProvider);
        _assertEq12(v, o, "Sepolia router + MovingPegExtruction vs RateSpaceAquaRouter");

        // v1.0.2 AquaSwapVMRouter built from lib/swap-vm-v1 on the same fork, same Sepolia Aqua
        _useReferenceRouter();
        uint256[12] memory s = _sequenceV1(rate, wstProvider);
        _assertEq12(v, s, "Sepolia router vs v1.0.2 AquaSwapVMRouter from source");
    }

    function _useReferenceRouter() internal {
        router = ISwapVM(address(new AquaSwapVMRouter(AQUA_SEPOLIA, WETH_SEPOLIA, address(this), "1inch SwapVM v1.0", "1.0.2")));
        taker = new MockTaker(aqua, SwapVM(payable(address(router))), address(this));
    }

    /// @dev With the 0.05% flat fee in front: Sepolia router == v1.0.2 source router, all four modes
    function test_Q3b_FeeOrder_SepoliaRouter_EqualsV102Source() public onFork {
        uint256 depWst = _depWst(rate);
        uint256[8] memory live = _feeRun(depWst);
        _useReferenceRouter();
        uint256[8] memory ref = _feeRun(depWst);
        for (uint256 i = 0; i < 8; i++) assertEq(live[i], ref[i], string.concat("fee order [", vm.toString(i), "]"));
    }

    function _feeRun(uint256 depWst) internal returns (uint256[8] memory r) {
        ISwapVM.Order memory order = _stdOrderV1(rate, depWst, wstProvider, true);
        _shipV1(order, depWst);
        (r[0], r[1]) = _qsV1("fee S1 WETH->wstETH exactIn 0.1", order, 0.1e18, true, true);
        (r[2], r[3]) = _qsV1("fee S2 wstETH->WETH exactOut 0.05", order, 0.05e18, false, false);
        (r[4], r[5]) = _qsV1("fee S3 wstETH->WETH exactIn 0.1", order, 0.1e18, false, true);
        (r[6], r[7]) = _qsV1("fee S4 WETH->wstETH exactOut 0.05", order, 0.05e18, true, false);
    }

    // ===== Q5: an arbitrary fresh EOA fills directly (pushMode) =====

    function test_Q5_ArbitraryEoaTaker() public onFork {
        uint256 depWst = _depWst(rate);
        ISwapVM.Order memory order = _stdOrderV1(rate, depWst, wstProvider, false);
        _shipV1(order, depWst);

        address eoa = vm.addr(uint256(keccak256("random-taker-eoa")));
        assertEq(eoa.code.length, 0, "EOA has no code");
        _fundWeth(eoa, 1e18);
        (uint256 qIn, uint256 qOut) = _quoteV1(order, 0.1e18, true, true);
        uint256 wstBefore = IERC20(WSTETH_SEPOLIA).balanceOf(eoa);
        vm.startPrank(eoa, eoa);
        IERC20(WETH_SEPOLIA).approve(ROUTER_SEPOLIA, type(uint256).max);
        (uint256 aIn, uint256 aOut,) = router.swap(order, WETH_SEPOLIA, WSTETH_SEPOLIA, 0.1e18, _tdV1(eoa, true, true));
        vm.stopPrank();
        assertEq(aIn, qIn, "EOA amountIn == quote");
        assertEq(aOut, qOut, "EOA amountOut == quote");
        assertEq(IERC20(WSTETH_SEPOLIA).balanceOf(eoa) - wstBefore, aOut);
        emit log_named_address("Q5 EOA taker", eoa);
        emit log_named_uint("Q5 EOA WETH in", aIn);
        emit log_named_uint("Q5 EOA wstETH out", aOut);
    }

    // ===== Q6: gas (logged, not asserted) =====

    function test_Q6_Gas() public onFork {
        uint256 depWst = _depWst(rate);
        ISwapVM.Order memory fee = _stdOrderV1(rate, depWst, wstProvider, true);
        ISwapVM.Order memory noFee = _stdOrderV1(rate, depWst, wstProvider, false);
        _shipV1(fee, depWst);
        _shipV1(noFee, depWst);
        _fundWeth(address(taker), 10e18);
        bytes memory td = _tdV1(address(taker), true, false);

        // Warm both strategies so the measured swaps are not first-touch
        taker.swap(fee, WETH_SEPOLIA, WSTETH_SEPOLIA, 0.01e18, td);
        taker.swap(noFee, WETH_SEPOLIA, WSTETH_SEPOLIA, 0.01e18, td);

        uint256 g = gasleft();
        (, uint256 outFee) = taker.swap(fee, WETH_SEPOLIA, WSTETH_SEPOLIA, 0.1e18, td);
        uint256 gasFee = g - gasleft();
        g = gasleft();
        (, uint256 outNoFee) = taker.swap(noFee, WETH_SEPOLIA, WSTETH_SEPOLIA, 0.1e18, td);
        uint256 gasNoFee = g - gasleft();
        emit log_named_uint("Q6 gas Sepolia router: flatFee + Extruction(MovingPeg)", gasFee);
        emit log_named_uint("Q6 gas Sepolia router: Extruction(MovingPeg)", gasNoFee);
        emit log_named_uint("Q6 out (fee) wstETH", outFee);
        emit log_named_uint("Q6 out (no fee) wstETH", outNoFee);
        assertLt(outFee, outNoFee, "fee order pays out less");
    }

    // ===== Q7: guards revert with our selectors in both quote and swap =====

    function _expectGuard(ISwapVM.Order memory order, bytes memory err) internal {
        bytes memory td = _tdV1(address(taker), true, false);
        vm.expectRevert(err);
        router.quote(order, WETH_SEPOLIA, WSTETH_SEPOLIA, 0.1e18, td);
        _fundWeth(address(taker), 1e18);
        vm.expectRevert(err);
        taker.swap(order, WETH_SEPOLIA, WSTETH_SEPOLIA, 0.1e18, td);
    }

    function test_Q7_BandGuard() public onFork {
        uint256 farRef = rate * 9 / 10;
        uint256 depWst = _depWst(farRef);
        ISwapVM.Order memory order = _stdOrderV1(farRef, depWst, wstProvider, false);
        _shipV1(order, depWst);
        _expectGuard(order, abi.encodeWithSelector(
            MovingPegExtruction.MovingPegSwapRateOutOfBand.selector, wstProvider, rate, farRef, uint256(BAND)
        ));
    }

    function test_Q7_BandCapAtExec() public onFork {
        uint16[3] memory bands = [uint16(0), uint16(1001), uint16(65535)];
        uint256 depWst = _depWst(rate);
        for (uint256 i = 0; i < bands.length; i++) {
            bytes memory raw = abi.encodePacked(
                MovingPegSwap.anchorFor(depWst, rate), MovingPegSwap.anchorFor(DEP_WETH, ONE), WIDTH, rate, ONE,
                wstProvider, address(0), bands[i]
            );
            ISwapVM.Order memory order = _orderV1(_programV1(_ins(opExtruction, abi.encodePacked(address(target), raw)), false));
            _shipV1(order, depWst);
            _expectGuard(order, abi.encodeWithSelector(MovingPegExtruction.MovingPegSwapInvalidMaxDeviation.selector, uint256(bands[i])));
            emit log_named_uint("Q7 band rejected at exec", bands[i]);
        }
    }

    function test_Q7_ZeroRate() public onFork {
        MockRateProvider zp = new MockRateProvider(); // rate() == 0 until set
        uint256 depWst = _depWst(rate);
        ISwapVM.Order memory order = _stdOrderV1(rate, depWst, address(zp), false);
        _shipV1(order, depWst);
        _expectGuard(order, abi.encodeWithSelector(MovingPegExtruction.MovingPegSwapZeroRate.selector, address(zp)));
    }
}
