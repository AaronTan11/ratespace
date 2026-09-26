// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeploySepolia} from "../../script/DeploySepolia.s.sol";
import {ShipSepolia} from "../../script/ShipSepolia.s.sol";
import {SepoliaAddresses} from "../../script/SepoliaAddresses.sol";
import {SepoliaDeployment} from "../../script/SepoliaDeployment.sol";

interface ILidoStETHSubmit {
    function submit(address referral) external payable returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWstETHWrapOnly {
    function wrap(uint256 stETHAmount) external returns (uint256);
}

interface IWETH9Deposit {
    function deposit() external payable;
}

/// @notice Shared setup for the Sepolia-fork tests that call DeploySepolia.run() / ShipSepolia.run() themselves
///   (the scripts' real entry points, broadcast included; forge test never sends anything). Each test passes its
///   own throw-away deployments path through the scripts' setDeploymentsPath hook, so parallel tests never share
///   a file and deployments/11155111.json is never touched.
/// @dev Requires SEPOLIA_RPC_URL; without it every test is SKIPPED. Pinned fork block.
abstract contract SepoliaScriptBase is Test, SepoliaDeployment {
    uint256 internal constant FORK_BLOCK = 11786347;
    uint256 internal constant FUND_ETH = 1e18;

    string internal rpcUrl;
    bool internal forkOn;

    function setUp() public virtual {
        rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        forkOn = bytes(rpcUrl).length > 0;
    }

    modifier onFork() {
        if (!forkOn) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        assertEq(block.chainid, SepoliaAddresses.CHAIN_ID, "Sepolia chain id");
        _;
    }

    /// @dev The address a no-argument vm.startBroadcast() (as in both scripts' run()) broadcasts from
    function _broadcaster() internal returns (address b) {
        vm.startBroadcast();
        (, b,) = vm.readCallers();
        vm.stopBroadcast();
    }

    /// @dev Throw-away deployments file for one test (gitignored deployments/test-*.json), unique per test AND
    ///   per forge process (unixTime ms + random), so two `forge test` runs at once never share a file
    function _testPath(string memory name) internal returns (string memory path) {
        path = string.concat(
            "deployments/test-", name, "-", vm.toString(vm.unixTime()), "-", vm.toString(vm.randomUint()), ".json"
        );
        if (vm.exists(path)) vm.removeFile(path);
    }

    function _deployRun(string memory path) internal {
        DeploySepolia s = new DeploySepolia();
        s.setDeploymentsPath(path);
        s.run();
    }

    function _shipScript(string memory path, bool useOneInch) internal returns (ShipSepolia s) {
        s = new ShipSepolia();
        s.setDeploymentsPath(path);
        s.setUseOneInchRouter(useOneInch);
    }

    /// @dev Real Sepolia path: ETH -> stETH (Lido submit) -> wstETH (wrap); ETH -> WETH (deposit)
    function _fund(address who) internal {
        vm.deal(who, who.balance + 2 * FUND_ETH);
        vm.startPrank(who);
        ILidoStETHSubmit(SepoliaAddresses.STETH).submit{value: FUND_ETH}(address(0));
        uint256 st = ILidoStETHSubmit(SepoliaAddresses.STETH).balanceOf(who);
        ILidoStETHSubmit(SepoliaAddresses.STETH).approve(SepoliaAddresses.WSTETH, st);
        IWstETHWrapOnly(SepoliaAddresses.WSTETH).wrap(st);
        IWETH9Deposit(SepoliaAddresses.WETH).deposit{value: FUND_ETH}();
        vm.stopPrank();
        assertGt(IERC20(SepoliaAddresses.WSTETH).balanceOf(who), 0, "funded wstETH");
        assertGe(IERC20(SepoliaAddresses.WETH).balanceOf(who), FUND_ETH, "funded WETH");
    }
}
