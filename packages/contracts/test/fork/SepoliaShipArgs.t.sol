// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAqua} from "@aqua-v1/src/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@swap-vm-v1/interfaces/ISwapVM.sol";
import {MakerTraits} from "@swap-vm-v1/libs/MakerTraits.sol";
import {ISwapVM as ISwapVMV0} from "@swap-vm/interfaces/ISwapVM.sol";
import {MakerTraits as MakerTraitsV0} from "@swap-vm/libs/MakerTraits.sol";

import {IRateSpaceOrderBuilder} from "../../src/demo/IRateSpaceOrderBuilder.sol";
import {IRateProvider} from "../../src/rate-providers/IRateProvider.sol";
import {IWstETH} from "../../src/rate-providers/interfaces/IWstETH.sol";

import {ShipSepolia} from "../../script/ShipSepolia.s.sol";
import {SepoliaAddresses} from "../../script/SepoliaAddresses.sol";

import {SepoliaScriptBase} from "./SepoliaScriptBase.sol";

/// @notice DeploySepolia.run() + ShipSepolia.run() on a Sepolia fork, then every shipped order's MovingPeg args
///   decoded from the program in the JSON the script wrote, checked against independent values: the live wstETH
///   rate, the owner's WIDTH / BAND, the default deposits, and the maker's Aqua balances for that strategy.
///   Both router paths: 1inch AquaSwapVMRouter (Extruction 0x20) and RateSpaceAquaRouter (MovingPegSwap 0x59).
contract SepoliaShipArgsTest is SepoliaScriptBase {
    // Independent literals (not read from the script)
    uint256 internal constant EXP_WIDTH = 50e27;
    uint16 internal constant EXP_BAND = 500;
    uint256 internal constant EXP_DEFAULT_WETH_DEPOSIT = 0.05e18;
    uint8 internal constant OP_EXTRUCTION = 0x20;
    uint8 internal constant OP_MOVING_PEG_SWAP = 0x59;
    uint256 internal constant MPS_LEN = 202;
    // 1inch router (swap-vm v1.0.2 AquaOpcodes indexes, as RateSpaceOrderBuilder's SALT_OPCODE = 20 and
    // FLAT_FEE_AMOUNT_IN_OPCODE = 21): Salt 0x14, FlatFeeAmountIn 0x15 (uint32 fee on 1e9)
    uint8 internal constant OP_SALT_V1 = 0x14;
    uint8 internal constant OP_FEE_V1 = 0x15;
    uint256 internal constant EXP_FEE_1E9 = 500000;
    // RateSpaceAquaRouter (swap-vm 3b3da7d OpcodeList: /* 02 */ Salt, /* 70 */ FeeFlatIn, uint24 fee on 1e7)
    uint8 internal constant OP_SALT_V0 = 0x02;
    uint8 internal constant OP_FEE_V0 = 0x70;
    uint256 internal constant EXP_FEE_1E7 = 5000;

    struct Mps {
        uint256 x0;
        uint256 y0;
        uint256 width;
        uint256 refRateLt;
        uint256 refRateGt;
        address providerLt;
        address providerGt;
        uint16 band;
    }

    function _word(bytes memory b, uint256 off) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(add(b, 32), off))
        }
    }

    function _addrAt(bytes memory b, uint256 off) internal pure returns (address) {
        return address(uint160(_word(b, off) >> 96));
    }

    /// @dev Walks the program's [opcode][len][args] instructions and returns the offset of the MovingPeg args:
    ///   inside Extruction (0x20, len 222, after the 20-byte target) or MovingPegSwap (0x59, len 202)
    function _mpsOffset(bytes memory program, bool oneInch, address extruction) internal pure returns (uint256) {
        uint256 i;
        while (i + 2 <= program.length) {
            uint8 op = uint8(program[i]);
            uint256 len = uint8(program[i + 1]);
            if (oneInch && op == OP_EXTRUCTION && len == 20 + MPS_LEN) {
                require(_addrAt(program, i + 2) == extruction, "Extruction target != MovingPegExtruction");
                return i + 2 + 20;
            }
            if (!oneInch && op == OP_MOVING_PEG_SWAP && len == MPS_LEN) return i + 2;
            i += 2 + len;
        }
        revert("MovingPeg args not found in program");
    }

    function _decode(bytes memory program, uint256 o) internal pure returns (Mps memory m) {
        m.x0 = _word(program, o);
        m.y0 = _word(program, o + 32);
        m.width = _word(program, o + 64);
        m.refRateLt = _word(program, o + 96);
        m.refRateGt = _word(program, o + 128);
        m.providerLt = _addrAt(program, o + 160);
        m.providerGt = _addrAt(program, o + 180);
        m.band = uint16(_word(program, o + 200) >> 240);
    }

    /// @dev The program's opcodes in order; the [opcode][len][args] walk must end exactly at program.length
    function _opcodes(bytes memory program) internal pure returns (uint8[] memory ops) {
        uint8[] memory tmp = new uint8[](program.length / 2 + 1);
        uint256 n;
        uint256 i;
        while (i < program.length) {
            require(i + 2 <= program.length, "truncated instruction header");
            tmp[n++] = uint8(program[i]);
            i += 2 + uint8(program[i + 1]);
        }
        require(i == program.length, "instruction overruns program");
        ops = new uint8[](n);
        for (uint256 k = 0; k < n; k++) {
            ops[k] = tmp[k];
        }
    }

    /// @dev Fee binding: order 1 (no fee) = [curve, salt]; order 2 (fee) = [flat fee in, curve, salt] with the
    ///   owner's fee (500000 on 1e9 for the 1inch router, 5000 on 1e7 for RateSpaceAquaRouter)
    function _checkFee(bytes memory program, bool oneInch, bool withFee, string memory tag)
        internal
        pure
        returns (bool feeDecoded)
    {
        uint8 curve = oneInch ? OP_EXTRUCTION : OP_MOVING_PEG_SWAP;
        uint8 salt = oneInch ? OP_SALT_V1 : OP_SALT_V0;
        uint8 fee = oneInch ? OP_FEE_V1 : OP_FEE_V0;
        uint8[] memory ops = _opcodes(program);
        uint256 feeCount;
        for (uint256 k = 0; k < ops.length; k++) {
            if (ops[k] == fee) feeCount++;
        }
        assertEq(feeCount, withFee ? 1 : 0, string.concat(tag, ": fee instruction count"));
        feeDecoded = feeCount == 1;
        assertEq(ops.length, withFee ? 3 : 2, string.concat(tag, ": instruction count"));
        uint256 o = withFee ? 1 : 0;
        assertEq(ops[o], curve, string.concat(tag, ": curve instruction"));
        assertEq(ops[o + 1], salt, string.concat(tag, ": salt instruction last"));
        if (!withFee) return feeDecoded;
        assertEq(ops[0], fee, string.concat(tag, ": fee instruction first"));
        uint256 argLen = uint8(program[1]);
        assertEq(argLen, oneInch ? 4 : 3, string.concat(tag, ": fee args length"));
        uint256 feeBps = _word(program, 2) >> (256 - 8 * argLen);
        assertEq(feeBps, oneInch ? EXP_FEE_1E9 : EXP_FEE_1E7, string.concat(tag, ": feeBps"));
    }

    /// @dev Record binding: the order the app rebuilds from the JSON {maker, traits, data} hashes, on its own
    ///   router, to the JSON strategyHash; that strategy is live in Aqua with both tokens; `data` carries exactly
    ///   the JSON program (v1.0.2 hook-less data == program; 3b3da7d data == tokenA ++ tokenB ++ program)
    function _checkRecord(OrderRecord memory r, Deployment memory d, address router, bool oneInch, address maker)
        internal
        view
    {
        address m = vm.parseAddress(r.maker);
        assertEq(m, maker, "JSON maker == broadcaster");
        uint256 traits = vm.parseUint(r.traits);
        bytes memory data = vm.parseBytes(r.data);
        bytes memory program = vm.parseBytes(r.program);
        bytes32 h = vm.parseBytes32(r.strategyHash);
        bytes32 rebuilt;
        if (oneInch) {
            ISwapVM.Order memory order = ISwapVM.Order(m, MakerTraits.wrap(traits), data);
            rebuilt = ISwapVM(router).hash(order);
            assertEq(rebuilt, h, "router.hash(JSON order) == JSON strategyHash");
            assertEq(keccak256(abi.encode(order)), h, "keccak(abi.encode(JSON order)) == strategyHash");
            assertEq(data, program, "JSON data == JSON program (v1.0.2, no hooks)");
        } else {
            ISwapVMV0.Order memory order = ISwapVMV0.Order(m, MakerTraitsV0.wrap(traits), data);
            rebuilt = ISwapVMV0(router).hash(order);
            assertEq(rebuilt, h, "router.hash(JSON order) == JSON strategyHash");
            assertEq(keccak256(abi.encode(order)), h, "keccak(abi.encode(JSON order)) == strategyHash");
            assertEq(data, abi.encodePacked(d.wstEth, d.weth, program), "JSON data == wstETH ++ WETH ++ JSON program");
        }
        (, uint8 nWst) = IAqua(d.aqua).rawBalances(m, router, h, d.wstEth);
        (, uint8 nWeth) = IAqua(d.aqua).rawBalances(m, router, h, d.weth);
        assertEq(nWst, 2, "Aqua strategy live (wstETH side, 2 tokens)");
        assertEq(nWeth, 2, "Aqua strategy live (WETH side, 2 tokens)");
    }

    /// @dev The salt: the program's last instruction, [Salt opcode][8][uint64 salt] (1inch Salt 0x14 via
    ///   ControlsArgsBuilder.buildSalt(uint64) = abi.encodePacked(salt); 3b3da7d Salt 0x02 pushes 8 bytes)
    function _salt(bytes memory program, bool oneInch) internal pure returns (uint64) {
        uint256 n = program.length;
        require(n >= 10, "program too short for a salt");
        assertEq(uint8(program[n - 10]), oneInch ? OP_SALT_V1 : OP_SALT_V0, "salt opcode");
        assertEq(uint8(program[n - 9]), 8, "salt args length");
        return uint64(_word(program, n - 8) >> 192);
    }

    function _shipAndCheck(bool oneInch, string memory name) internal {
        string memory path = _testPath(name);
        address b = _broadcaster();
        _deployRun(path);
        _fund(b);
        _shipScript(path, oneInch).run();

        (Deployment memory d, OrderRecord[] memory orders) = _readDeployment(path);
        vm.removeFile(path);
        assertEq(orders.length, 2, "two orders shipped");

        uint256 liveRate = IRateProvider(d.rateProviderWstEth).rate();
        assertEq(liveRate, IWstETH(SepoliaAddresses.WSTETH).stEthPerToken(), "provider == live stEthPerToken");
        emit log_named_uint("live wstETH rate at fork block", liveRate);
        address router = oneInch ? d.oneInchRouter : d.rateSpaceRouter;
        uint64[2] memory salts;

        for (uint256 k = 0; k < 2; k++) {
            OrderRecord memory r = orders[k];
            assertEq(vm.parseAddress(r.router), router, "order router");
            assertEq(r.hasFee, k == 1, "order hasFee");
            // The fields the app selects and trades the market by (apps/web deployments.ts)
            assertEq(vm.parseAddress(r.tokenYield), d.wstEth, "JSON tokenYield == WstETH");
            assertEq(vm.parseAddress(r.tokenWeth), d.weth, "JSON tokenWeth == WETH");
            assertEq(vm.parseAddress(r.rateFeed), d.rateProviderWstEth, "JSON rateFeed == RateProviderWstETH");
            bytes32 h = vm.parseBytes32(r.strategyHash);
            (uint248 depWst,) = IAqua(d.aqua).rawBalances(b, router, h, d.wstEth);
            (uint248 depWeth,) = IAqua(d.aqua).rawBalances(b, router, h, d.weth);

            // Default deposits: 0.05 WETH, wstETH value-balanced at the live rate
            assertEq(depWeth, EXP_DEFAULT_WETH_DEPOSIT, "WETH deposit == default");
            assertEq(depWst, uint256(depWeth) * 1e18 / liveRate, "wstETH deposit == depWeth * 1e18 / rate");

            bytes memory program = vm.parseBytes(r.program);
            bool feeDecoded = _checkFee(program, oneInch, k == 1, k == 0 ? "order 1" : "order 2");
            assertEq(r.hasFee, feeDecoded, "JSON hasFee == decoded fee instruction");
            salts[k] = _salt(program, oneInch);
            _checkRecord(r, d, router, oneInch, b);
            Mps memory m = _decode(program, _mpsOffset(program, oneInch, d.extruction));
            assertEq(m.refRateLt, liveRate, "refRateLt == live wstETH rate");
            assertEq(m.refRateGt, 1e18, "refRateGt == 1e18 (WETH)");
            assertEq(m.providerLt, d.rateProviderWstEth, "providerLt == RateProviderWstETH");
            assertEq(m.providerGt, address(0), "providerGt == 0");
            assertEq(m.width, EXP_WIDTH, "width == 50e27");
            assertEq(m.band, EXP_BAND, "band == 500");
            assertEq(
                m.x0, IRateSpaceOrderBuilder(d.builder).anchorFor(depWst, liveRate), "x0 == anchorFor(depWst, rate)"
            );
            assertEq(m.y0, depWeth, "y0 == depWeth");
        }
        assertEq(uint256(salts[1]), uint256(salts[0]) + 1, "order 2 salt == order 1 salt + 1");
    }

    /// @dev Default path: 1inch's Sepolia AquaSwapVMRouter, MovingPeg args inside Extruction 0x20
    function test_ShipArgs_OneInchRouter() public onFork {
        _shipAndCheck(true, "shipargs-1inch");
    }

    /// @dev Fallback path: RateSpaceAquaRouter, MovingPegSwap 0x59
    function test_ShipArgs_RateSpaceRouter() public onFork {
        _shipAndCheck(false, "shipargs-rs");
    }

    /// @dev The maker-balance guards: a maker with neither token makes ShipSepolia.run() revert on WETH; a maker with
    ///   WETH but no wstETH reverts on wstETH (nothing shipped, file keeps orders: [])
    function test_ShipArgs_MakerBalanceGuards() public onFork {
        string memory path = _testPath("shipargs-balance");
        address b = _broadcaster();
        _deployRun(path);
        (Deployment memory d,) = _readDeployment(path);
        // The default broadcaster holds real Sepolia WETH at the fork block: zero both balances first
        deal(d.weth, b, 0);
        deal(d.wstEth, b, 0);
        assertEq(IERC20(d.weth).balanceOf(b), 0, "maker starts without WETH");
        assertEq(IERC20(d.wstEth).balanceOf(b), 0, "maker starts without wstETH");

        ShipSepolia s = _shipScript(path, true);
        vm.expectRevert(bytes("ShipSepolia: maker WETH balance < SHIP_WETH_DEPOSIT"));
        s.run();

        // run() reverted between its startBroadcast and stopBroadcast: the cheatcode broadcast is still on
        vm.stopBroadcast();
        deal(d.weth, b, FUND_ETH);
        vm.expectRevert(bytes("ShipSepolia: maker wstETH balance < SHIP_WSTETH_DEPOSIT"));
        s.run();

        (, OrderRecord[] memory orders) = _readDeployment(path);
        assertEq(orders.length, 0, "nothing recorded");
        vm.removeFile(path);
    }

    /// @dev The builder-opcode guard: a builder whose EXTRUCTION_OPCODE() differs from the Sepolia router's
    ///   Extruction index makes ShipSepolia.run() revert before anything is shipped
    function test_ShipArgs_BuilderOpcodeMismatchReverts() public onFork {
        string memory path = _testPath("shipargs-opcode");
        address b = _broadcaster();
        _deployRun(path);
        _fund(b);
        (Deployment memory d,) = _readDeployment(path);
        vm.mockCall(
            d.builder,
            abi.encodeWithSignature("EXTRUCTION_OPCODE()"),
            abi.encode(uint8(SepoliaAddresses.EXTRUCTION_OPCODE_SEPOLIA + 1))
        );
        ShipSepolia s = _shipScript(path, true);
        vm.expectRevert(bytes("ShipSepolia: builder Extruction opcode != Sepolia router's"));
        s.run();
        vm.removeFile(path);
    }
}
