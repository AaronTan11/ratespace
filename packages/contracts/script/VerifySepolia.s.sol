// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";

import {IAqua} from "@aqua-v1/src/interfaces/IAqua.sol";

import {SepoliaAddresses} from "./SepoliaAddresses.sol";
import {SepoliaDeployment} from "./SepoliaDeployment.sol";

/// @notice View-only check of deployments/11155111.json (or DEPLOYMENTS_PATH) against the chain; sends nothing.
///   Prints `CONTRACT_MISSING <name>` for every recorded contract without code, and `OK <i> <strategyHash>` /
///   `DOCKED <i> <strategyHash>` / `PHANTOM <i> <strategyHash>` for every order, from Aqua's rawBalances(maker,
///   router, strategyHash, token) tokensCount for its tokenYield and its tokenWeth: OK when both are 2; DOCKED when
///   either is Aqua's docked marker (closed with Aqua.dock); PHANTOM otherwise (e.g. 0: never shipped).
/// @dev A PHANTOM is an order the file lists but Aqua never shipped: ShipSepolia writes the file during forge's
///   local simulation, so a broadcast that fails afterwards (e.g. insufficient funds) leaves such records.
///   Reverts (non-zero exit) when a contract is missing (checked first, before any write), or when a PHANTOM or
///   DOCKED order is found and PRUNE_PHANTOMS is not "1". With PRUNE_PHANTOMS=1 the file is rewritten without the
///   PHANTOM and DOCKED orders (the other records keep their order and bytes), then the run succeeds.
///   Run: `forge script script/VerifySepolia.s.sol --rpc-url $SEPOLIA_RPC_URL`
contract VerifySepolia is SepoliaDeployment {
    string internal constant PHANTOM_MSG =
        "VerifySepolia: PHANTOM orders in the deployments file (never shipped); re-run with PRUNE_PHANTOMS=1";
    string internal constant DOCKED_MSG =
        "VerifySepolia: DOCKED orders in the deployments file; re-run with PRUNE_PHANTOMS=1 to remove them";
    string internal constant MISSING_MSG = "VerifySepolia: CONTRACT_MISSING (a recorded contract has no code)";

    /// @dev Mirror of Aqua's private marker, lib/swap-vm-v1/node_modules/@1inch/aqua/src/Aqua.sol:19
    ///   `uint8 private constant _DOCKED = 0xff;` (dock stores it as every token's tokensCount, Aqua.sol:58)
    uint8 internal constant AQUA_DOCKED = 0xff;

    /// @notice Per-order status; PHANTOM and DOCKED are both "not live"
    enum Status {
        PHANTOM,
        OK,
        DOCKED
    }

    function run() external {
        require(block.chainid == SepoliaAddresses.CHAIN_ID, "VerifySepolia: Sepolia (chain 11155111) only");
        string memory path = _deploymentsPath();
        (Deployment memory d, OrderRecord[] memory orders) = _readDeployment(path);

        uint256 missing = missingContracts(d);
        require(missing == 0, MISSING_MSG);
        Status[] memory status = liveness(d, orders);

        uint256 nLive;
        uint256 nPhantom;
        for (uint256 i = 0; i < status.length; i++) {
            if (status[i] == Status.OK) nLive++;
            else if (status[i] == Status.PHANTOM) nPhantom++;
        }
        if (nLive < orders.length) {
            if (!_pruneRequested()) {
                require(nPhantom == 0, PHANTOM_MSG);
                revert(DOCKED_MSG);
            }
            OrderRecord[] memory kept = new OrderRecord[](nLive);
            uint256 k;
            for (uint256 i = 0; i < orders.length; i++) {
                if (status[i] == Status.OK) kept[k++] = orders[i];
            }
            // Direct write: this script is run without --broadcast (a dry run), where _writeDeployment writes nothing
            vm.writeFile(path, _deploymentJson(d, kept));
            console.log("PRUNED phantoms:", nPhantom);
            console.log("PRUNED docked:", orders.length - nLive - nPhantom);
        }
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

    /// @notice status[i] of order i in Aqua (see the contract notice); logs OK / DOCKED / PHANTOM per order
    function liveness(Deployment memory d, OrderRecord[] memory orders) public view returns (Status[] memory status) {
        status = new Status[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            OrderRecord memory o = orders[i];
            address maker = vm.parseAddress(o.maker);
            address router = vm.parseAddress(o.router);
            bytes32 h = vm.parseBytes32(o.strategyHash);
            (, uint8 nYield) = IAqua(d.aqua).rawBalances(maker, router, h, vm.parseAddress(o.tokenYield));
            (, uint8 nWeth) = IAqua(d.aqua).rawBalances(maker, router, h, vm.parseAddress(o.tokenWeth));
            if (nYield == AQUA_DOCKED || nWeth == AQUA_DOCKED) status[i] = Status.DOCKED;
            else if (nYield == 2 && nWeth == 2) status[i] = Status.OK;
            else status[i] = Status.PHANTOM;
            string memory tag = status[i] == Status.OK ? "OK " : status[i] == Status.DOCKED ? "DOCKED " : "PHANTOM ";
            console.log(string.concat(tag, vm.toString(i), " ", o.strategyHash));
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
