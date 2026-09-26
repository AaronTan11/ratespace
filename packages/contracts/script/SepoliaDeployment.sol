// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { VmSafe } from "forge-std/Vm.sol";

import { SepoliaAddresses } from "./SepoliaAddresses.sol";

/// @notice Reads and writes deployments/11155111.json (or DEPLOYMENTS_PATH) for DeploySepolia and ShipSepolia.
/// @dev Frozen shape (the app codes against it; same key order as below):
///   { chainId, maker, Aqua, AquaSwapVMRouter, RateSpaceAquaRouter, MovingPegExtruction, RateSpaceOrderBuilder,
///     WETH, WstETH, RateProviderWstETH,
///     orders: [{ maker, traits (uint256 decimal string), data, program, strategyHash, tokenYield, tokenWeth,
///                hasFee, rateFeed, router }] }
abstract contract SepoliaDeployment is Script {
    string internal constant DEFAULT_DEPLOYMENTS_PATH = "deployments/11155111.json";

    /// @dev Set by tests through setDeploymentsPath (process-global vm.setEnv would race between parallel tests)
    string internal deploymentsPathOverride;

    /// @notice Test hook: read/write `path` instead of DEPLOYMENTS_PATH / the default
    function setDeploymentsPath(string calldata path) external {
        deploymentsPathOverride = path;
    }

    /// @dev setDeploymentsPath's path, else env DEPLOYMENTS_PATH, else deployments/11155111.json
    function _deploymentsPath() internal view returns (string memory) {
        if (bytes(deploymentsPathOverride).length > 0) return deploymentsPathOverride;
        return vm.envOr("DEPLOYMENTS_PATH", DEFAULT_DEPLOYMENTS_PATH);
    }

    struct Deployment {
        address maker;
        address aqua;
        address oneInchRouter;
        address rateSpaceRouter;
        address extruction;
        address builder;
        address weth;
        address wstEth;
        address rateProviderWstEth;
    }

    /// @dev Kept as the JSON strings so earlier orders are re-emitted byte-for-byte
    struct OrderRecord {
        string maker;
        string traits;
        string data;
        string program;
        string strategyHash;
        string tokenYield;
        string tokenWeth;
        bool hasFee;
        string rateFeed;
        string router;
    }

    function _readDeployment(string memory path) internal view returns (Deployment memory d, OrderRecord[] memory orders) {
        string memory json = vm.readFile(path);
        require(vm.parseJsonUint(json, ".chainId") == SepoliaAddresses.CHAIN_ID, "SepoliaDeployment: chainId != 11155111");
        d.maker = vm.parseJsonAddress(json, ".maker");
        d.aqua = vm.parseJsonAddress(json, ".Aqua");
        d.oneInchRouter = vm.parseJsonAddress(json, ".AquaSwapVMRouter");
        d.rateSpaceRouter = vm.parseJsonAddress(json, ".RateSpaceAquaRouter");
        d.extruction = vm.parseJsonAddress(json, ".MovingPegExtruction");
        d.builder = vm.parseJsonAddress(json, ".RateSpaceOrderBuilder");
        d.weth = vm.parseJsonAddress(json, ".WETH");
        d.wstEth = vm.parseJsonAddress(json, ".WstETH");
        d.rateProviderWstEth = vm.parseJsonAddress(json, ".RateProviderWstETH");

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".orders[", vm.toString(n), "]"))) n++;
        orders = new OrderRecord[](n);
        for (uint256 i = 0; i < n; i++) {
            string memory p = string.concat(".orders[", vm.toString(i), "]");
            orders[i].maker = vm.parseJsonString(json, string.concat(p, ".maker"));
            orders[i].traits = vm.parseJsonString(json, string.concat(p, ".traits"));
            orders[i].data = vm.parseJsonString(json, string.concat(p, ".data"));
            orders[i].program = vm.parseJsonString(json, string.concat(p, ".program"));
            orders[i].strategyHash = vm.parseJsonString(json, string.concat(p, ".strategyHash"));
            orders[i].tokenYield = vm.parseJsonString(json, string.concat(p, ".tokenYield"));
            orders[i].tokenWeth = vm.parseJsonString(json, string.concat(p, ".tokenWeth"));
            orders[i].hasFee = vm.parseJsonBool(json, string.concat(p, ".hasFee"));
            orders[i].rateFeed = vm.parseJsonString(json, string.concat(p, ".rateFeed"));
            orders[i].router = vm.parseJsonString(json, string.concat(p, ".router"));
        }
    }

    /// @dev `forge script` without --broadcast (ScriptDryRun) writes nothing: a dry run of DeploySepolia or
    ///   ShipSepolia must not record contracts or orders that were never sent. --broadcast / --resume and
    ///   forge test (the fork tests) write.
    function _writeDeployment(string memory path, Deployment memory d, OrderRecord[] memory orders) internal {
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console.log("dry run: deployments file NOT written");
            return;
        }
        vm.writeFile(path, _deploymentJson(d, orders));
    }

    function _deploymentJson(Deployment memory d, OrderRecord[] memory orders) internal view returns (string memory json) {
        json = string.concat(
            "{\n  ",
            _kv("chainId", vm.toString(block.chainid)), ",\n  ",
            _addr("maker", d.maker), ",\n  ",
            _addr("Aqua", d.aqua), ",\n  ",
            _addr("AquaSwapVMRouter", d.oneInchRouter), ",\n  ",
            _addr("RateSpaceAquaRouter", d.rateSpaceRouter), ",\n  "
        );
        json = string.concat(
            json,
            _addr("MovingPegExtruction", d.extruction), ",\n  ",
            _addr("RateSpaceOrderBuilder", d.builder), ",\n  ",
            _addr("WETH", d.weth), ",\n  ",
            _addr("WstETH", d.wstEth), ",\n  ",
            _addr("RateProviderWstETH", d.rateProviderWstEth), ",\n  "
        );
        if (orders.length == 0) return string.concat(json, _q("orders"), ": []\n}\n");
        json = string.concat(json, _q("orders"), ": [\n");
        for (uint256 i = 0; i < orders.length; i++) {
            json = string.concat(json, _orderJson(orders[i]), i + 1 < orders.length ? ",\n" : "\n");
        }
        json = string.concat(json, "  ]\n}\n");
    }

    function _orderJson(OrderRecord memory o) internal pure returns (string memory) {
        string memory s = string.concat(
            "    {\n      ",
            _kv("maker", _q(o.maker)), ",\n      ",
            _kv("traits", _q(o.traits)), ",\n      ",
            _kv("data", _q(o.data)), ",\n      ",
            _kv("program", _q(o.program)), ",\n      ",
            _kv("strategyHash", _q(o.strategyHash)), ",\n      "
        );
        return string.concat(
            s,
            _kv("tokenYield", _q(o.tokenYield)), ",\n      ",
            _kv("tokenWeth", _q(o.tokenWeth)), ",\n      ",
            _kv("hasFee", o.hasFee ? "true" : "false"), ",\n      ",
            _kv("rateFeed", _q(o.rateFeed)), ",\n      ",
            _kv("router", _q(o.router)),
            "\n    }"
        );
    }

    function _q(string memory s) internal pure returns (string memory) {
        return string.concat("\"", s, "\"");
    }

    function _kv(string memory k, string memory v) internal pure returns (string memory) {
        return string.concat(_q(k), ": ", v);
    }

    function _addr(string memory k, address a) internal pure returns (string memory) {
        return _kv(k, _q(vm.toString(a)));
    }
}
