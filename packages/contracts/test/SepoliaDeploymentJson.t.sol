// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {SepoliaDeployment} from "../script/SepoliaDeployment.sol";

/// @notice Local (no RPC): the deployments-file shape the app codes against (apps/web/src/lib/chain/deployments.ts)
///   and the reader's chain guard. Keys are independent literals, not read from the script.
contract SepoliaDeploymentJsonTest is Test, SepoliaDeployment {
    uint256 internal constant SEPOLIA = 11155111;

    function _dummy() internal pure returns (Deployment memory d, OrderRecord[] memory orders) {
        d = Deployment({
            maker: address(0x1001),
            aqua: address(0x1002),
            oneInchRouter: address(0x1003),
            rateSpaceRouter: address(0x1004),
            extruction: address(0x1005),
            builder: address(0x1006),
            weth: address(0x1007),
            wstEth: address(0x1008),
            rateProviderWstEth: address(0x1009)
        });
        orders = new OrderRecord[](1);
        orders[0] = OrderRecord({
            maker: "0x0000000000000000000000000000000000001001",
            traits: "123",
            data: "0x01",
            program: "0x01",
            strategyHash: "0x1111111111111111111111111111111111111111111111111111111111111111",
            tokenYield: "0x0000000000000000000000000000000000001008",
            tokenWeth: "0x0000000000000000000000000000000000001007",
            hasFee: true,
            rateFeed: "0x0000000000000000000000000000000000001009",
            router: "0x0000000000000000000000000000000000001003"
        });
    }

    function _assertKeys(string[] memory got, string[] memory exp, string memory tag) internal pure {
        assertEq(got.length, exp.length, string.concat(tag, ": key count"));
        for (uint256 i = 0; i < exp.length; i++) {
            assertEq(got[i], exp[i], string.concat(tag, ": key ", vm.toString(i)));
        }
    }

    /// @dev Top-level and order keys, exactly and in order; chainId written as Sepolia's
    function test_Json_ShapePinned() public {
        vm.chainId(SEPOLIA);
        (Deployment memory d, OrderRecord[] memory orders) = _dummy();
        string memory json = _deploymentJson(d, orders);

        string[] memory top = new string[](11);
        top[0] = "chainId";
        top[1] = "maker";
        top[2] = "Aqua";
        top[3] = "AquaSwapVMRouter";
        top[4] = "RateSpaceAquaRouter";
        top[5] = "MovingPegExtruction";
        top[6] = "RateSpaceOrderBuilder";
        top[7] = "WETH";
        top[8] = "WstETH";
        top[9] = "RateProviderWstETH";
        top[10] = "orders";
        _assertKeys(vm.parseJsonKeys(json, "$"), top, "top level");

        string[] memory ord = new string[](10);
        ord[0] = "maker";
        ord[1] = "traits";
        ord[2] = "data";
        ord[3] = "program";
        ord[4] = "strategyHash";
        ord[5] = "tokenYield";
        ord[6] = "tokenWeth";
        ord[7] = "hasFee";
        ord[8] = "rateFeed";
        ord[9] = "router";
        _assertKeys(vm.parseJsonKeys(json, ".orders[0]"), ord, "order");

        assertEq(vm.parseJsonUint(json, ".chainId"), SEPOLIA, "chainId == 11155111");
        assertEq(vm.parseJsonAddress(json, ".RateProviderWstETH"), d.rateProviderWstEth, "RateProviderWstETH value");
        assertEq(vm.parseJsonAddress(json, ".orders[0].tokenYield"), d.wstEth, "tokenYield value");
        assertTrue(vm.parseJsonBool(json, ".orders[0].hasFee"), "hasFee value");
    }

    /// @dev A file whose chainId is not Sepolia's is refused by the reader
    function test_Json_ReadRefusesWrongChainId() public {
        vm.chainId(1);
        (Deployment memory d, OrderRecord[] memory orders) = _dummy();
        string memory path = string.concat(
            "deployments/test-json-chainid-", vm.toString(vm.unixTime()), "-", vm.toString(vm.randomUint()), ".json"
        );
        vm.writeFile(path, _deploymentJson(d, orders));
        assertEq(vm.parseJsonUint(vm.readFile(path), ".chainId"), 1, "file says chainId 1");
        vm.expectRevert(bytes("SepoliaDeployment: chainId != 11155111"));
        this.readExternal(path);
        vm.removeFile(path);
    }

    function readExternal(string memory path) external view {
        _readDeployment(path);
    }
}
