// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IAqua} from "@aqua-v1/src/interfaces/IAqua.sol";

import {SepoliaAddresses} from "../../script/SepoliaAddresses.sol";
import {ShipSepolia} from "../../script/ShipSepolia.s.sol";
import {VerifySepolia} from "../../script/VerifySepolia.s.sol";

import {SepoliaScriptBase} from "./SepoliaScriptBase.sol";

/// @notice Re-running the Sepolia scripts against one deployments file: a second ShipSepolia.run() appends and
///   keeps the earlier orders byte-identical; DeploySepolia.run() refuses to replace a file that already has
///   shipped orders unless DEPLOY_OVERWRITE is set; the broadcaster owns RateSpaceAquaRouter.
contract SepoliaScriptsRerunTest is SepoliaScriptBase {
    string internal constant CLOBBER_MSG =
        "DeploySepolia: deployments file already has shipped orders; set DEPLOY_OVERWRITE=1 to replace it";
    string internal constant UNPARSABLE_MSG =
        "DeploySepolia: deployments file exists but cannot be parsed; fix or remove it (or set DEPLOY_OVERWRITE=1)";
    string internal constant PHANTOM_MSG =
        "VerifySepolia: PHANTOM orders in the deployments file (never shipped); re-run with PRUNE_PHANTOMS=1";
    string internal constant DOCKED_MSG =
        "VerifySepolia: DOCKED orders in the deployments file; re-run with PRUNE_PHANTOMS=1 to remove them";
    string internal constant MISSING_MSG = "VerifySepolia: CONTRACT_MISSING (a recorded contract has no code)";
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

    function _verifyScript(string memory path) internal returns (VerifySepolia v) {
        v = new VerifySepolia();
        v.setDeploymentsPath(path);
    }

    /// @dev Deploy + Ship -> VerifySepolia: both orders live (OK), every contract has code, run() succeeds and
    ///   leaves the file byte-identical
    function test_Verify_OkAfterShip() public onFork {
        string memory path = _testPath("verify-ok");
        address b = _broadcaster();
        _deployRun(path);
        _fund(b);
        _shipScript(path, true).run();
        string memory before = vm.readFile(path);
        (Deployment memory d, OrderRecord[] memory orders) = _readDeployment(path);

        VerifySepolia v = _verifyScript(path);
        VerifySepolia.Status[] memory st = v.liveness(d, orders);
        assertEq(st.length, 2, "two orders checked");
        _assertStatus(st[0], VerifySepolia.Status.OK, "order 0 OK");
        _assertStatus(st[1], VerifySepolia.Status.OK, "order 1 OK");
        assertEq(v.missingContracts(d), 0, "every recorded contract has code");
        v.run();
        assertEq(vm.readFile(path), before, "verify without phantoms leaves the file untouched");
        vm.removeFile(path);
    }

    /// @dev A record the chain never saw (order 0 copied with strategyHash keccak256("phantom")) appended to the
    ///   file: VerifySepolia flags it PHANTOM and reverts; with PRUNE_PHANTOMS=1 it rewrites the file with exactly
    ///   the 2 real orders, byte-identical to the file before the append.
    /// @dev The only test that sets PRUNE_PHANTOMS (process-global env), so every run() expectation that depends
    ///   on it lives here: PHANTOM (appended record, and a live hash with a wrong token field), PRUNE_PHANTOMS "0" /
    ///   "true" (no prune), a missing contract with PRUNE_PHANTOMS=1 (reverts before any write), and DOCKED.
    ///   It sets the variable back to "" before the asserts that follow each prune.
    function test_Verify_PhantomRevertsThenPrunes() public onFork {
        string memory path = _testPath("verify-phantom");
        address b = _broadcaster();
        _deployRun(path);
        _fund(b);
        _shipScript(path, true).run();
        string memory real = vm.readFile(path);
        (Deployment memory d, OrderRecord[] memory orders) = _readDeployment(path);
        assertEq(orders.length, 2, "shipped");

        OrderRecord[] memory withPhantom = new OrderRecord[](3);
        withPhantom[0] = orders[0];
        withPhantom[1] = orders[1];
        // A fresh copy: `= orders[0]` would alias the memory struct and change order 0 too
        withPhantom[2] = _copy(orders[0]);
        withPhantom[2].strategyHash = vm.toString(keccak256("phantom"));
        vm.writeFile(path, _deploymentJson(d, withPhantom));
        string memory tampered = vm.readFile(path);

        VerifySepolia v = _verifyScript(path);
        VerifySepolia.Status[] memory st = v.liveness(d, withPhantom);
        _assertStatus(st[0], VerifySepolia.Status.OK, "order 0 OK");
        _assertStatus(st[1], VerifySepolia.Status.OK, "order 1 OK");
        _assertStatus(st[2], VerifySepolia.Status.PHANTOM, "appended record PHANTOM");

        vm.expectRevert(bytes(PHANTOM_MSG));
        v.run();
        assertEq(vm.readFile(path), tampered, "refused verify left the file untouched");

        // A: live hash, wrong tokenWeth -> PHANTOM, run() reverts
        string memory wrongPath = _testPath("verify-wrongtoken");
        OrderRecord[] memory wrong = new OrderRecord[](1);
        wrong[0] = _copy(orders[0]);
        wrong[0].tokenWeth = vm.toString(SepoliaAddresses.STETH);
        vm.writeFile(wrongPath, _deploymentJson(d, wrong));
        VerifySepolia vWrong = _verifyScript(wrongPath);
        vm.expectRevert(bytes(PHANTOM_MSG));
        vWrong.run();
        vm.removeFile(wrongPath);

        // D: PRUNE_PHANTOMS must be exactly "1"
        vm.setEnv("PRUNE_PHANTOMS", "0");
        vm.expectRevert(bytes(PHANTOM_MSG));
        v.run();
        vm.setEnv("PRUNE_PHANTOMS", "true");
        vm.expectRevert(bytes(PHANTOM_MSG));
        v.run();
        vm.setEnv("PRUNE_PHANTOMS", "");
        assertEq(vm.readFile(path), tampered, "PRUNE_PHANTOMS 0 / true: file untouched");

        // C ordering: a missing contract reverts before any prune write, even with PRUNE_PHANTOMS=1
        string memory missPath = _testPath("verify-missing-prune");
        Deployment memory dMiss = abi.decode(abi.encode(d), (Deployment));
        dMiss.rateProviderWstEth = makeAddr("no-code");
        vm.writeFile(missPath, _deploymentJson(dMiss, withPhantom));
        string memory missBefore = vm.readFile(missPath);
        VerifySepolia vMiss = _verifyScript(missPath);
        vm.setEnv("PRUNE_PHANTOMS", "1");
        vm.expectRevert(bytes(MISSING_MSG));
        vMiss.run();
        vm.setEnv("PRUNE_PHANTOMS", "");
        assertEq(keccak256(bytes(vm.readFile(missPath))), keccak256(bytes(missBefore)), "missing: file untouched");
        vm.removeFile(missPath);

        vm.setEnv("PRUNE_PHANTOMS", "1");
        v.run();
        vm.setEnv("PRUNE_PHANTOMS", "");
        assertEq(vm.readFile(path), real, "pruned file == the 2 real orders, byte-identical");
        assertEq(_orderCount(path), 2, "pruned: 2 orders");

        // DOCKED: order 0 closed by the maker -> DOCKED (order 1 OK); reverts without prune, pruned with it
        _dock(d, orders[0]);
        st = v.liveness(d, orders);
        _assertStatus(st[0], VerifySepolia.Status.DOCKED, "docked order 0 DOCKED");
        _assertStatus(st[1], VerifySepolia.Status.OK, "order 1 OK");
        // M1: docked, but the record's tokenYield is wrong (reads 0): the WETH side alone (0xff) makes it DOCKED
        OrderRecord[] memory dockedWrongYield = new OrderRecord[](1);
        dockedWrongYield[0] = _copy(orders[0]);
        dockedWrongYield[0].tokenYield = vm.toString(SepoliaAddresses.STETH);
        _assertStatus(
            v.liveness(d, dockedWrongYield)[0], VerifySepolia.Status.DOCKED, "docked, wrong tokenYield: DOCKED"
        );
        vm.expectRevert(bytes(DOCKED_MSG));
        v.run();
        assertEq(vm.readFile(path), real, "refused verify (docked) left the file untouched");

        vm.setEnv("PRUNE_PHANTOMS", "1");
        v.run();
        vm.setEnv("PRUNE_PHANTOMS", "");
        OrderRecord[] memory only1 = new OrderRecord[](1);
        only1[0] = orders[1];
        assertEq(vm.readFile(path), _deploymentJson(d, only1), "pruned docked: file == order 1, byte-identical");
        vm.removeFile(path);
    }

    /// @dev L: orders shipped through RateSpaceAquaRouter (USE_ONEINCH_ROUTER=false) are read at their own
    ///   router: both OK, run() succeeds, file untouched
    function test_Verify_RateSpaceRouterOrdersOk() public onFork {
        string memory path = _testPath("verify-rsrouter");
        address b = _broadcaster();
        _deployRun(path);
        _fund(b);
        _shipScript(path, false).run();
        string memory before = vm.readFile(path);
        (Deployment memory d, OrderRecord[] memory orders) = _readDeployment(path);
        assertEq(orders.length, 2, "shipped");
        assertEq(vm.parseAddress(orders[0].router), d.rateSpaceRouter, "order 0 on RateSpaceAquaRouter");
        assertEq(vm.parseAddress(orders[1].router), d.rateSpaceRouter, "order 1 on RateSpaceAquaRouter");

        VerifySepolia v = _verifyScript(path);
        VerifySepolia.Status[] memory st = v.liveness(d, orders);
        _assertStatus(st[0], VerifySepolia.Status.OK, "RateSpaceAquaRouter order 0 OK");
        _assertStatus(st[1], VerifySepolia.Status.OK, "RateSpaceAquaRouter order 1 OK");
        v.run();
        assertEq(vm.readFile(path), before, "verify left the file untouched");
        vm.removeFile(path);
    }

    /// @dev A: a live strategyHash with a wrong token field on either side is PHANTOM (the run() revert is in
    ///   test_Verify_PhantomRevertsThenPrunes, which owns PRUNE_PHANTOMS)
    function test_Verify_WrongTokenIsPhantom() public onFork {
        string memory path = _testPath("verify-wrongtoken-view");
        address b = _broadcaster();
        _deployRun(path);
        _fund(b);
        _shipScript(path, true).run();
        (Deployment memory d, OrderRecord[] memory orders) = _readDeployment(path);

        OrderRecord[] memory wrong = new OrderRecord[](2);
        wrong[0] = _copy(orders[0]);
        wrong[0].tokenWeth = vm.toString(SepoliaAddresses.STETH);
        wrong[1] = _copy(orders[1]);
        wrong[1].tokenYield = vm.toString(SepoliaAddresses.STETH);
        VerifySepolia.Status[] memory st = _verifyScript(path).liveness(d, wrong);
        _assertStatus(st[0], VerifySepolia.Status.PHANTOM, "wrong tokenWeth -> PHANTOM");
        _assertStatus(st[1], VerifySepolia.Status.PHANTOM, "wrong tokenYield -> PHANTOM");
        vm.removeFile(path);
    }

    /// @dev C: a recorded contract without code -> run() reverts with MISSING_MSG, file untouched (the missing
    ///   check runs before the prune check, so this does not depend on PRUNE_PHANTOMS)
    function test_Verify_MissingContractReverts() public onFork {
        string memory path = _testPath("verify-missing");
        address b = _broadcaster();
        _deployRun(path);
        _fund(b);
        _shipScript(path, true).run();
        (Deployment memory d, OrderRecord[] memory orders) = _readDeployment(path);
        d.rateProviderWstEth = makeAddr("no-code");
        vm.writeFile(path, _deploymentJson(d, orders));
        string memory before = vm.readFile(path);

        VerifySepolia v = _verifyScript(path);
        assertEq(v.missingContracts(d), 1, "one recorded contract without code");
        vm.expectRevert(bytes(MISSING_MSG));
        v.run();
        assertEq(vm.readFile(path), before, "refused verify left the file untouched");
        vm.removeFile(path);
    }

    /// @dev M10: a second ShipSepolia.run() broadcast from another wallet overwrites the top-level maker
    ///   (ShipSepolia.s.sol:76 `d.maker = maker`); Verify must read each
    ///   order at its own record's maker: all four OK, run() succeeds, file untouched
    function test_Verify_TwoMakersBothOk() public onFork {
        string memory path = _testPath("verify-twomakers");
        address b = _broadcaster();
        _deployRun(path);
        _fund(b);
        _shipScript(path, true).run();

        (address m2, uint256 m2Key) = makeAddrAndKey("second-maker");
        assertTrue(m2 != b, "second maker != broadcaster");
        _fund(m2);
        ShipSepolia s2 = _shipScript(path, true);
        s2.setSalt(7);
        // A no-argument vm.startBroadcast() (ShipSepolia.run) broadcasts from the single wallet the cheatcode state
        // knows, else tx.origin; a prank cannot be used ("you have an active prank; broadcasting and pranks are not
        // compatible"). rememberKey makes m2 that single wallet, as `forge script --private-key` would.
        vm.rememberKey(m2Key);
        s2.run();

        (Deployment memory d, OrderRecord[] memory orders) = _readDeployment(path);
        assertEq(orders.length, 4, "4 orders");
        assertEq(d.maker, m2, "top-level maker == second maker (last ship)");
        assertEq(vm.parseAddress(orders[0].maker), b, "order 0 maker == broadcaster");
        assertEq(vm.parseAddress(orders[1].maker), b, "order 1 maker == broadcaster");
        assertEq(vm.parseAddress(orders[2].maker), m2, "order 2 maker == second maker");
        assertEq(vm.parseAddress(orders[3].maker), m2, "order 3 maker == second maker");
        for (uint256 i = 0; i < 4; i++) {
            (, uint8 n) = IAqua(d.aqua)
                .rawBalances(
                    vm.parseAddress(orders[i].maker),
                    vm.parseAddress(orders[i].router),
                    vm.parseBytes32(orders[i].strategyHash),
                    d.wstEth
                );
            assertEq(n, 2, "Aqua: shipped by the record's maker");
        }
        string memory before = vm.readFile(path);

        VerifySepolia v = _verifyScript(path);
        VerifySepolia.Status[] memory st = v.liveness(d, orders);
        for (uint256 i = 0; i < 4; i++) {
            _assertStatus(st[i], VerifySepolia.Status.OK, "every order OK at its own maker");
        }
        v.run();
        assertEq(vm.readFile(path), before, "verify left the file untouched");
        vm.removeFile(path);
    }

    /// @dev M9: the same strategy bytes as a real order (fresh salt) shipped by hand with THREE tokens
    ///   (wstETH, WETH, stETH): Aqua stores tokensCount 3 for both recorded tokens -> PHANTOM, not OK
    function test_Verify_ThreeTokenShipIsPhantom() public onFork {
        string memory path = _testPath("verify-threetoken");
        address b = _broadcaster();
        _deployRun(path);
        _fund(b);
        ShipSepolia s = _shipScript(path, true);
        s.run();
        (Deployment memory d, OrderRecord[] memory orders) = _readDeployment(path);

        ShipSepolia.ShipParams memory p = s.params(d);
        (address router,, bytes memory strategy,,) = s.buildOrder(d, p, b, false, 11);
        address[] memory tokens = new address[](3);
        tokens[0] = d.wstEth;
        tokens[1] = d.weth;
        tokens[2] = SepoliaAddresses.STETH;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = p.depWst;
        amounts[1] = p.depWeth;
        vm.prank(b);
        bytes32 h = IAqua(d.aqua).ship(router, strategy, tokens, amounts);
        (, uint8 nYield) = IAqua(d.aqua).rawBalances(b, router, h, d.wstEth);
        (, uint8 nWeth) = IAqua(d.aqua).rawBalances(b, router, h, d.weth);
        assertEq(nYield, 3, "Aqua: tokensCount 3 (wstETH)");
        assertEq(nWeth, 3, "Aqua: tokensCount 3 (WETH)");

        OrderRecord[] memory all = new OrderRecord[](3);
        all[0] = orders[0];
        all[1] = orders[1];
        all[2] = _copy(orders[0]);
        all[2].strategyHash = vm.toString(h);
        VerifySepolia.Status[] memory st = _verifyScript(path).liveness(d, all);
        _assertStatus(st[0], VerifySepolia.Status.OK, "order 0 OK");
        _assertStatus(st[1], VerifySepolia.Status.OK, "order 1 OK");
        _assertStatus(st[2], VerifySepolia.Status.PHANTOM, "3-token ship PHANTOM");
        vm.removeFile(path);
    }

    function _copy(OrderRecord memory o) internal pure returns (OrderRecord memory) {
        return abi.decode(abi.encode(o), (OrderRecord));
    }

    /// @dev Closes order `o` in Aqua as its maker (Aqua.dock over both tokens)
    function _dock(Deployment memory d, OrderRecord memory o) internal {
        address[] memory tokens = new address[](2);
        tokens[0] = vm.parseAddress(o.tokenYield);
        tokens[1] = vm.parseAddress(o.tokenWeth);
        vm.prank(vm.parseAddress(o.maker));
        IAqua(d.aqua).dock(vm.parseAddress(o.router), vm.parseBytes32(o.strategyHash), tokens);
    }

    function _assertStatus(VerifySepolia.Status got, VerifySepolia.Status want, string memory err) internal pure {
        assertEq(uint256(got), uint256(want), err);
    }

    /// @dev M10 helper: the write gate is open in a forge test (not ScriptDryRun). The dry-run branch itself can
    ///   only be exercised by `forge script` without --broadcast (a by-hand fork run), not from a Test context.
    function test_ShouldWrite_TrueOutsideDryRun() public view {
        assertFalse(vm.isContext(VmSafe.ForgeContext.ScriptDryRun), "forge test is not a script dry run");
        assertTrue(_shouldWrite(), "write gate open in test context");
    }

    function deployRunExternal(string memory path) external {
        _deployRun(path);
    }
}
