// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAqua} from "@aqua-v1/src/interfaces/IAqua.sol";

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

        for (uint256 k = 0; k < 2; k++) {
            OrderRecord memory r = orders[k];
            assertEq(vm.parseAddress(r.router), router, "order router");
            assertEq(r.hasFee, k == 1, "order hasFee");
            bytes32 h = vm.parseBytes32(r.strategyHash);
            (uint248 depWst,) = IAqua(d.aqua).rawBalances(b, router, h, d.wstEth);
            (uint248 depWeth,) = IAqua(d.aqua).rawBalances(b, router, h, d.weth);

            // Default deposits: 0.05 WETH, wstETH value-balanced at the live rate
            assertEq(depWeth, EXP_DEFAULT_WETH_DEPOSIT, "WETH deposit == default");
            assertEq(depWst, uint256(depWeth) * 1e18 / liveRate, "wstETH deposit == depWeth * 1e18 / rate");

            bytes memory program = vm.parseBytes(r.program);
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
    }

    /// @dev Default path: 1inch's Sepolia AquaSwapVMRouter, MovingPeg args inside Extruction 0x20
    function test_ShipArgs_OneInchRouter() public onFork {
        _shipAndCheck(true, "shipargs-1inch");
    }

    /// @dev Fallback path: RateSpaceAquaRouter, MovingPegSwap 0x59
    function test_ShipArgs_RateSpaceRouter() public onFork {
        _shipAndCheck(false, "shipargs-rs");
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
