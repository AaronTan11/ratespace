// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MovingPegExtruction } from "../src/extruction/MovingPegExtruction.sol";
import { RateSpaceOrderBuilder } from "../src/demo/RateSpaceOrderBuilder.sol";
import { RateSpaceAquaRouter } from "../src/routers/RateSpaceAquaRouter.sol";
import { WstETHRateProvider } from "../src/rate-providers/WstETHRateProvider.sol";
import { IWstETH } from "../src/rate-providers/interfaces/IWstETH.sol";

import { SepoliaAddresses } from "./SepoliaAddresses.sol";
import { SepoliaDeployment } from "./SepoliaDeployment.sol";

/// @notice Sepolia (chain 11155111): deploys WstETHRateProvider (Lido Sepolia wstETH), MovingPegExtruction,
///   RateSpaceOrderBuilder and RateSpaceAquaRouter (our fallback router, on the canonical Aqua), and writes
///   deployments/11155111.json (or DEPLOYMENTS_PATH) with `orders: []`. Refuses to replace a file that already
///   has shipped orders unless DEPLOY_OVERWRITE=1. Uses 1inch's existing Aqua and AquaSwapVMRouter; deploys neither.
/// @dev No key is baked in: the broadcaster comes from the CLI (`--interactive`, `--account`, or on a local fork
///   `--private-key` with an anvil public test key). The broadcaster becomes the RateSpaceAquaRouter owner and
///   the JSON's top-level `maker`.
contract DeploySepolia is SepoliaDeployment {
    function run() external {
        require(block.chainid == SepoliaAddresses.CHAIN_ID, "DeploySepolia: Sepolia (chain 11155111) only");
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        Deployment memory d = deploy(sender);
        vm.stopBroadcast();
        string memory path = _deploymentsPath();
        require(
            !_hasShippedOrders(path) || vm.envOr("DEPLOY_OVERWRITE", false),
            "DeploySepolia: deployments file already has shipped orders; set DEPLOY_OVERWRITE=1 to replace it"
        );
        _writeDeployment(path, d, new OrderRecord[](0));
    }

    /// @dev True when `path` exists and parses as JSON with a non-empty `orders` array (a real deployment
    ///   record that a re-run would otherwise replace with `orders: []`)
    function _hasShippedOrders(string memory path) internal view returns (bool) {
        if (!vm.exists(path)) return false;
        string memory json = vm.readFile(path);
        try vm.keyExistsJson(json, ".orders[0]") returns (bool has) {
            return has;
        } catch {
            return false;
        }
    }

    /// @notice Deploys the four RateSpace contracts; `owner` owns RateSpaceAquaRouter (rescue-funds only)
    function deploy(address owner) public returns (Deployment memory d) {
        require(SepoliaAddresses.AQUA.code.length > 0, "DeploySepolia: no code at Aqua");
        require(SepoliaAddresses.ONEINCH_ROUTER.code.length > 0, "DeploySepolia: no code at 1inch router");
        require(SepoliaAddresses.WSTETH.code.length > 0, "DeploySepolia: no code at wstETH");
        require(SepoliaAddresses.WETH.code.length > 0, "DeploySepolia: no code at WETH");

        d.maker = owner;
        d.aqua = SepoliaAddresses.AQUA;
        d.oneInchRouter = SepoliaAddresses.ONEINCH_ROUTER;
        d.weth = SepoliaAddresses.WETH;
        d.wstEth = SepoliaAddresses.WSTETH;
        d.rateProviderWstEth = address(new WstETHRateProvider(IWstETH(SepoliaAddresses.WSTETH)));
        d.extruction = address(new MovingPegExtruction());
        d.builder = address(new RateSpaceOrderBuilder());
        d.rateSpaceRouter = address(new RateSpaceAquaRouter(SepoliaAddresses.AQUA, SepoliaAddresses.WETH, owner, "RateSpace", "1"));

        // The provider must read the live Lido rate (fails loudly on a wrong wstETH address)
        require(WstETHRateProvider(d.rateProviderWstEth).rate() == IWstETH(SepoliaAddresses.WSTETH).stEthPerToken(), "DeploySepolia: provider rate");
    }
}
