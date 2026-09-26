// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";

import {IAqua} from "@aqua-v1/src/interfaces/IAqua.sol";

import {SepoliaAddresses} from "./SepoliaAddresses.sol";
import {SepoliaDeployment} from "./SepoliaDeployment.sol";

/// @notice View-only check of deployments/11155111.json (or DEPLOYMENTS_PATH) against the chain; sends nothing.
///   Prints `CONTRACT_MISSING <name>` for every recorded contract without code, and `OK <i> <strategyHash>` /
///   `PHANTOM <i> <strategyHash>` for every order: an order is live when Aqua's rawBalances(maker, router,
///   strategyHash, token) reports tokensCount == 2 for both its tokenYield and its tokenWeth.
/// @dev A PHANTOM is an order the file lists but Aqua never shipped: ShipSepolia writes the file during forge's
///   local simulation, so a broadcast that fails afterwards (e.g. insufficient funds) leaves such records.
///   Reverts (non-zero exit) when a contract is missing, or when a phantom is found and PRUNE_PHANTOMS is not
///   "1". With PRUNE_PHANTOMS=1 the file is rewritten without the phantoms (the other records keep their order
///   and bytes), then the run succeeds. Run: `forge script script/VerifySepolia.s.sol --rpc-url $SEPOLIA_RPC_URL`
contract VerifySepolia is SepoliaDeployment {
    string internal constant PHANTOM_MSG =
        "VerifySepolia: PHANTOM orders in the deployments file (never shipped); re-run with PRUNE_PHANTOMS=1";
    string internal constant MISSING_MSG = "VerifySepolia: CONTRACT_MISSING (a recorded contract has no code)";

    function run() external {
        require(block.chainid == SepoliaAddresses.CHAIN_ID, "VerifySepolia: Sepolia (chain 11155111) only");
        string memory path = _deploymentsPath();
        (Deployment memory d, OrderRecord[] memory orders) = _readDeployment(path);

        uint256 missing = missingContracts(d);
        bool[] memory live = liveOrders(d, orders);

        uint256 nLive;
        for (uint256 i = 0; i < live.length; i++) {
            if (live[i]) nLive++;
        }
        if (nLive < orders.length) {
            require(_pruneRequested(), PHANTOM_MSG);
            OrderRecord[] memory kept = new OrderRecord[](nLive);
            uint256 k;
            for (uint256 i = 0; i < orders.length; i++) {
                if (live[i]) kept[k++] = orders[i];
            }
            // Direct write: this script is run without --broadcast (a dry run), where _writeDeployment writes nothing
            vm.writeFile(path, _deploymentJson(d, kept));
            console.log("PRUNED phantoms:", orders.length - nLive);
        }
        require(missing == 0, MISSING_MSG);
    }

    /// @notice Number of recorded contracts without code; logs `CONTRACT_MISSING <name>` for each
    function missingContracts(Deployment memory d) public view returns (uint256 n) {
        n += _missing("Aqua", d.aqua);
        n += _missing("AquaSwapVMRouter", d.oneInchRouter);
        n += _missing("RateSpaceAquaRouter", d.rateSpaceRouter);
        n += _missing("MovingPegExtruction", d.extruction);
        n += _missing("RateSpaceOrderBuilder", d.builder);
        n += _missing("WETH", d.weth);
        n += _missing("WstETH", d.wstEth);
        n += _missing("RateProviderWstETH", d.rateProviderWstEth);
    }

    /// @notice live[i] == order i is shipped in Aqua with 2 tokens on both sides; logs OK / PHANTOM per order
    function liveOrders(Deployment memory d, OrderRecord[] memory orders) public view returns (bool[] memory live) {
        live = new bool[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            OrderRecord memory o = orders[i];
            address maker = vm.parseAddress(o.maker);
            address router = vm.parseAddress(o.router);
            bytes32 h = vm.parseBytes32(o.strategyHash);
            (, uint8 nYield) = IAqua(d.aqua).rawBalances(maker, router, h, vm.parseAddress(o.tokenYield));
            (, uint8 nWeth) = IAqua(d.aqua).rawBalances(maker, router, h, vm.parseAddress(o.tokenWeth));
            live[i] = nYield == 2 && nWeth == 2;
            console.log(string.concat(live[i] ? "OK " : "PHANTOM ", vm.toString(i), " ", o.strategyHash));
        }
    }

    function _missing(string memory name, address a) internal view returns (uint256) {
        if (a.code.length > 0) return 0;
        console.log(string.concat("CONTRACT_MISSING ", name));
        return 1;
    }

    /// @dev PRUNE_PHANTOMS must be exactly "1" (unset or "" = no prune)
    function _pruneRequested() internal view returns (bool) {
        return keccak256(bytes(vm.envOr("PRUNE_PHANTOMS", string("")))) == keccak256("1");
    }
}
