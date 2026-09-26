// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ShipSepolia} from "../../script/ShipSepolia.s.sol";

import {SepoliaScriptBase} from "./SepoliaScriptBase.sol";

/// @notice Re-running the Sepolia scripts against one deployments file: a second ShipSepolia.run() appends and
///   keeps the earlier orders byte-identical; DeploySepolia.run() refuses to replace a file that already has
///   shipped orders unless DEPLOY_OVERWRITE is set; the broadcaster owns RateSpaceAquaRouter.
contract SepoliaScriptsRerunTest is SepoliaScriptBase {
    string internal constant CLOBBER_MSG =
        "DeploySepolia: deployments file already has shipped orders; set DEPLOY_OVERWRITE=1 to replace it";
    string internal constant UNPARSABLE_MSG =
        "DeploySepolia: deployments file exists but cannot be parsed; fix or remove it (or set DEPLOY_OVERWRITE=1)";
    /// @dev A real record corrupted by a trailing comma
    string internal constant CORRUPT_JSON = '{"orders":[{"a":1},]}';

    function _orderCount(string memory path) internal view returns (uint256) {
        (, OrderRecord[] memory o) = _readDeployment(path);
        return o.length;
    }

    /// @dev Deploy -> 0 orders (re-deploy over an order-less file is allowed) -> Ship -> 2 -> Ship (new salt) -> 4,
    ///   the first two records unchanged field for field and in the file's bytes
    function test_Rerun_ShipAppendsKeepsEarlierOrders() public onFork {
        string memory path = _testPath("rerun-append");
        address b = _broadcaster();

        _deployRun(path);
        assertEq(_orderCount(path), 0, "deploy: 0 orders");
        _deployRun(path);
        assertEq(_orderCount(path), 0, "re-deploy over orders: [] is allowed");

        (Deployment memory d,) = _readDeployment(path);
        assertEq(d.maker, b, "JSON maker == broadcaster");
        assertEq(Ownable(d.rateSpaceRouter).owner(), b, "RateSpaceAquaRouter owner == broadcaster");

        _fund(b);
        _shipScript(path, true).run();
        (, OrderRecord[] memory first) = _readDeployment(path);
        assertEq(first.length, 2, "ship 1: 2 orders");
        string memory json1 = vm.readFile(path);

        ShipSepolia s2 = _shipScript(path, true);
        s2.setSalt(3);
        s2.run();
        (Deployment memory d2, OrderRecord[] memory all) = _readDeployment(path);
        assertEq(all.length, 4, "ship 2: 4 orders");
        assertEq(keccak256(abi.encode(d2)), keccak256(abi.encode(d)), "deployment addresses unchanged");
        for (uint256 i = 0; i < 2; i++) {
            assertEq(keccak256(abi.encode(all[i])), keccak256(abi.encode(first[i])), "earlier order unchanged");
            assertTrue(
                keccak256(bytes(all[i + 2].strategyHash)) != keccak256(bytes(first[i].strategyHash)),
                "new salt -> new strategy"
            );
        }
        // Byte level: the first two records serialize exactly as they did in the first ship's file
        OrderRecord[] memory head = new OrderRecord[](2);
        head[0] = all[0];
        head[1] = all[1];
        assertEq(_deploymentJson(d2, head), json1, "first two records byte-identical");
        vm.removeFile(path);
    }

    /// @dev DeploySepolia.run() over a file with shipped orders reverts; with DEPLOY_OVERWRITE=1 it replaces it.
    ///   Same for a file that exists but does not parse (fail closed): reverts, file untouched; with
    ///   DEPLOY_OVERWRITE=1 it is replaced by `orders: []`.
    /// @dev The only test that sets DEPLOY_OVERWRITE (process-global env, which races between parallel tests),
    ///   so every expectation that depends on it lives here; it sets it back to false at the end
    function test_Rerun_DeployRefusesToClobberOrders() public onFork {
        string memory path = _testPath("rerun-clobber");
        address b = _broadcaster();
        _deployRun(path);
        _fund(b);
        _shipScript(path, true).run();
        assertEq(_orderCount(path), 2, "shipped");
        string memory before = vm.readFile(path);

        vm.expectRevert(bytes(CLOBBER_MSG));
        this.deployRunExternal(path);
        assertEq(vm.readFile(path), before, "refused deploy left the file untouched");

        vm.setEnv("DEPLOY_OVERWRITE", "1");
        _deployRun(path);
        vm.setEnv("DEPLOY_OVERWRITE", "false");
        assertEq(_orderCount(path), 0, "DEPLOY_OVERWRITE=1 replaced the file");
        vm.removeFile(path);

        // Unparsable file: fail closed, then DEPLOY_OVERWRITE=1 replaces it
        string memory bad = _testPath("rerun-unparsable");
        vm.writeFile(bad, CORRUPT_JSON);
        vm.expectRevert(bytes(UNPARSABLE_MSG));
        this.deployRunExternal(bad);
        assertEq(vm.readFile(bad), CORRUPT_JSON, "refused deploy left the corrupt file untouched");

        vm.setEnv("DEPLOY_OVERWRITE", "1");
        _deployRun(bad);
        vm.setEnv("DEPLOY_OVERWRITE", "false");
        assertEq(_orderCount(bad), 0, "DEPLOY_OVERWRITE=1 replaced the corrupt file with orders: []");
        assertFalse(vm.keyExistsJson(vm.readFile(bad), ".orders[0]"), "orders: []");
        vm.removeFile(bad);
    }

    function deployRunExternal(string memory path) external {
        _deployRun(path);
    }
}
