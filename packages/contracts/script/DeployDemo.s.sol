// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";

import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { MakerTraits } from "@swap-vm-v1/libs/MakerTraits.sol";
import { AquaSwapVMRouter } from "@swap-vm-v1/routers/AquaSwapVMRouter.sol";

import { MovingPegExtruction } from "../src/extruction/MovingPegExtruction.sol";
import { RateSpaceOrderBuilder } from "../src/demo/RateSpaceOrderBuilder.sol";
import { DemoWETH } from "../src/demo/mocks/DemoWETH.sol";
import { DemoYieldToken } from "../src/demo/mocks/DemoYieldToken.sol";
import { DemoRateFeed } from "../src/demo/mocks/DemoRateFeed.sol";

/// @notice LOCAL DEMO ONLY: deploys 1inch Aqua 0.1.0 + AquaSwapVMRouter v1.0.2 (from lib/swap-vm-v1), the
///   MovingPegExtruction target, the order builder and demo tokens/feeds to anvil (chain 31337), seeds the
///   maker (anvil account #0) with four shipped orders and the taker (anvil account #1) with balances +
///   router approvals, and writes deployments/31337.json (or DEPLOYMENTS_PATH).
/// @dev Keys: DEMO_MAKER_PK / DEMO_TAKER_PK, defaulting to anvil's public default test keys #0 / #1
///   (printed by `anvil` at startup; they are not secrets).
contract DeployDemo is Script {
    // anvil default test keys (0) and (1), copied from anvil 1.8.1 startup output
    uint256 internal constant ANVIL_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ANVIL_KEY_1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    // ===== Owner-approved settings =====
    uint256 internal constant WIDTH = 50e27;
    uint16 internal constant BAND = 500;
    /// @dev Owner fee 0.05% on v1.0.2's flat-fee 1e9 scale: 0.05% = 5e5 / 1e9
    uint32 internal constant FEE_1E9 = 500000;

    // ===== Brief-specified seed values =====
    uint256 internal constant ONE = 1e18;
    uint256 internal constant MAKER_WETH = 10e18;
    uint256 internal constant TAKER_WETH = 5e18;
    uint256 internal constant TAKER_YIELD = 2e18;
    uint256 internal constant RATE_WSTETH = 1244787728742679575;
    uint256 internal constant RATE_RETH = 1172468133468041111;
    uint256 internal constant RATE_WEETH = 1104406989873418608;

    struct Deployed {
        Aqua aqua;
        AquaSwapVMRouter router;
        MovingPegExtruction target;
        RateSpaceOrderBuilder builder;
        DemoWETH weth;
        DemoYieldToken[3] tokens;
        DemoRateFeed[3] feeds;
    }

    struct ShippedOrder {
        ISwapVM.Order order;
        bytes program;
        bytes32 strategyHash;
        address tokenYield;
        address feed;
        bool hasFee;
    }

    /// @dev Set by tests through setDeploymentsPath (process-global vm.setEnv would race between parallel tests)
    string internal deploymentsPathOverride;

    /// @notice Test hook: write `path` instead of DEPLOYMENTS_PATH / deployments/31337.json
    function setDeploymentsPath(string calldata path) external {
        deploymentsPathOverride = path;
    }

    /// @dev setDeploymentsPath's path, else env DEPLOYMENTS_PATH, else deployments/31337.json
    function _deploymentsPath() internal view returns (string memory) {
        if (bytes(deploymentsPathOverride).length > 0) return deploymentsPathOverride;
        return vm.envOr("DEPLOYMENTS_PATH", string("deployments/31337.json"));
    }

    function run() external {
        require(block.chainid == 31337, "DeployDemo: local anvil (chain 31337) only");
        uint256 makerPk = vm.envOr("DEMO_MAKER_PK", ANVIL_KEY_0);
        uint256 takerPk = vm.envOr("DEMO_TAKER_PK", ANVIL_KEY_1);
        address maker = vm.addr(makerPk);
        address taker = vm.addr(takerPk);

        Deployed memory d;
        ShippedOrder[4] memory orders;
        uint256[3] memory deposits;

        vm.startBroadcast(makerPk);
        d.aqua = new Aqua();
        // DemoWETH is deployed before the router because the router's constructor takes the WETH address
        d.weth = new DemoWETH();
        d.router = new AquaSwapVMRouter(address(d.aqua), address(d.weth), maker, "1inch SwapVM v1.0", "1.0.2");
        d.target = new MovingPegExtruction();
        d.builder = new RateSpaceOrderBuilder();
        d.tokens[0] = new DemoYieldToken("Demo wstETH", "wstETH");
        d.tokens[1] = new DemoYieldToken("Demo rETH", "rETH");
        d.tokens[2] = new DemoYieldToken("Demo weETH", "weETH");
        d.feeds[0] = new DemoRateFeed(RATE_WSTETH);
        d.feeds[1] = new DemoRateFeed(RATE_RETH);
        d.feeds[2] = new DemoRateFeed(RATE_WEETH);

        // Maker: 10e18 WETH shared as virtual backing by every order; per yield token, 10e18 WETH worth of it
        d.weth.mint(maker, MAKER_WETH);
        d.weth.approve(address(d.aqua), type(uint256).max);
        for (uint256 i = 0; i < 3; i++) {
            deposits[i] = MAKER_WETH * ONE / d.feeds[i].rate();
            d.tokens[i].mint(maker, deposits[i]);
            d.tokens[i].approve(address(d.aqua), type(uint256).max);
        }

        // Orders 1..3: one per yield token, no fee, salts 1..3. Order 4: wstETH with the 0.05% fee, salt 4
        // (the salt only makes the strategy hash unique; it is not a pricing parameter).
        for (uint256 i = 0; i < 4; i++) {
            uint256 k = i < 3 ? i : 0;
            orders[i] = _ship(d, maker, k, deposits[k], i == 3 ? FEE_1E9 : 0, uint64(i + 1));
        }
        vm.stopBroadcast();

        // Taker: balances + router approvals (pushMode swaps pull tokenIn from the taker via the router)
        vm.startBroadcast(takerPk);
        d.weth.mint(taker, TAKER_WETH);
        d.weth.approve(address(d.router), type(uint256).max);
        for (uint256 i = 0; i < 3; i++) {
            d.tokens[i].mint(taker, TAKER_YIELD);
            d.tokens[i].approve(address(d.router), type(uint256).max);
        }
        vm.stopBroadcast();

        _write(d, maker, taker, orders);
    }

    function _ship(Deployed memory d, address maker, uint256 k, uint256 yieldDeposit, uint32 fee, uint64 salt)
        internal
        returns (ShippedOrder memory s)
    {
        address yieldToken = address(d.tokens[k]);
        address feed = address(d.feeds[k]);
        uint256 rate = d.feeds[k].rate();
        uint256 yieldAnchor = d.builder.anchorFor(yieldDeposit, rate);
        uint256 wethAnchor = d.builder.anchorFor(MAKER_WETH, ONE);

        // Lt / Gt = lower / greater token address (MovingPegSwap convention); x0 is the Lt side's anchor
        bytes memory mps = yieldToken < address(d.weth)
            ? d.builder.buildMovingPegArgs(yieldAnchor, wethAnchor, WIDTH, rate, ONE, feed, address(0), BAND)
            : d.builder.buildMovingPegArgs(wethAnchor, yieldAnchor, WIDTH, ONE, rate, address(0), feed, BAND);

        s.program = d.builder.buildProgram(address(d.target), mps, fee, salt);
        s.order = d.builder.buildOrder(maker, s.program);
        s.tokenYield = yieldToken;
        s.feed = feed;
        s.hasFee = fee != 0;

        address[] memory tokens = new address[](2);
        tokens[0] = yieldToken;
        tokens[1] = address(d.weth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = yieldDeposit;
        amounts[1] = MAKER_WETH;
        s.strategyHash = d.aqua.ship(address(d.router), d.builder.encodeOrder(s.order), tokens, amounts);
        require(s.strategyHash == d.router.hash(s.order), "DeployDemo: strategyHash != router.hash");
        require(s.strategyHash == d.builder.orderHash(s.order), "DeployDemo: strategyHash != builder.orderHash");
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

    function _orderJson(ShippedOrder memory s, address weth) internal pure returns (string memory) {
        return string.concat(
            "    {\n      ",
            _addr("maker", s.order.maker), ",\n      ",
            _kv("traits", _q(vm.toString(MakerTraits.unwrap(s.order.traits)))), ",\n      ",
            _kv("data", _q(vm.toString(s.order.data))), ",\n      ",
            _kv("program", _q(vm.toString(s.program))), ",\n      ",
            _kv("strategyHash", _q(vm.toString(s.strategyHash))), ",\n      ",
            _addr("tokenYield", s.tokenYield), ",\n      ",
            _addr("tokenWeth", weth), ",\n      ",
            _kv("hasFee", s.hasFee ? "true" : "false"), ",\n      ",
            _addr("rateFeed", s.feed),
            "\n    }"
        );
    }

    function _write(Deployed memory d, address maker, address taker, ShippedOrder[4] memory orders) internal {
        address w = address(d.weth);
        string memory json = string.concat(
            "{\n  ",
            _kv("chainId", vm.toString(block.chainid)), ",\n  ",
            _addr("maker", maker), ",\n  ",
            _addr("taker", taker), ",\n  ",
            _addr("Aqua", address(d.aqua)), ",\n  ",
            _addr("AquaSwapVMRouter", address(d.router)), ",\n  ",
            _addr("MovingPegExtruction", address(d.target)), ",\n  ",
            _addr("RateSpaceOrderBuilder", address(d.builder)), ",\n  ",
            _addr("DemoWETH", w), ",\n  "
        );
        json = string.concat(
            json,
            _addr("DemoWstETH", address(d.tokens[0])), ",\n  ",
            _addr("DemoRETH", address(d.tokens[1])), ",\n  ",
            _addr("DemoWeETH", address(d.tokens[2])), ",\n  ",
            _addr("RateFeedWstETH", address(d.feeds[0])), ",\n  ",
            _addr("RateFeedRETH", address(d.feeds[1])), ",\n  ",
            _addr("RateFeedWeETH", address(d.feeds[2])), ",\n  "
        );
        json = string.concat(
            json,
            _q("orders"), ": [\n",
            _orderJson(orders[0], w), ",\n",
            _orderJson(orders[1], w), ",\n",
            _orderJson(orders[2], w), ",\n",
            _orderJson(orders[3], w),
            "\n  ]\n}\n"
        );
        vm.writeFile(_deploymentsPath(), json);
    }
}
