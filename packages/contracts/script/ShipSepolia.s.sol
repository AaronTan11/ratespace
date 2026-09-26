// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// 1inch swap-vm v1.0.2: the Sepolia AquaSwapVMRouter's ABI (orders built by RateSpaceOrderBuilder)
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { MakerTraits } from "@swap-vm-v1/libs/MakerTraits.sol";

// 1inch swap-vm 3b3da7d: RateSpaceAquaRouter's ABI (fallback path, MovingPegSwap opcode 0x59)
import { ISwapVM as ISwapVMV0 } from "@swap-vm/interfaces/ISwapVM.sol";
import { MakerTraits as MakerTraitsV0, MakerTraitsLib as MakerTraitsLibV0 } from "@swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib as TakerTraitsLibV0 } from "@swap-vm/libs/TakerTraits.sol";
import { Salt as SaltV0 } from "@swap-vm/instructions/Controls.sol";
import { FeeFlatIn } from "@swap-vm/instructions/FeeFlat.sol";

import { IAqua } from "@aqua-v1/src/interfaces/IAqua.sol";

import { IRateSpaceOrderBuilder } from "../src/demo/IRateSpaceOrderBuilder.sol";
import { RateSpaceOrderBuilder } from "../src/demo/RateSpaceOrderBuilder.sol";
import { MovingPegSwap } from "../src/instructions/MovingPegSwap.sol";
import { IRateProvider } from "../src/rate-providers/IRateProvider.sol";

import { SepoliaAddresses } from "./SepoliaAddresses.sol";
import { SepoliaDeployment } from "./SepoliaDeployment.sol";

/// @notice Run by the MAKER on Sepolia after DeploySepolia: ships two wstETH/WETH MovingPeg orders through Aqua
///   (order 1 without fee, order 2 with the 0.05% flat fee) and appends them to deployments/11155111.json
///   (or DEPLOYMENTS_PATH).
/// @dev The maker's wallet must already hold the deposits (stETH.submit -> wstETH.wrap, WETH.deposit); Aqua is
///   virtual, so ship moves no tokens, and both orders are backed by the same wallet balances.
/// @dev Env (all optional):
///   SHIP_WETH_DEPOSIT    WETH per order, wei                      default 0.05e18                 TODO-OWNER
///   SHIP_WSTETH_DEPOSIT  wstETH per order, wei                    default value-balanced at the live rate
///                                                                 (SHIP_WETH_DEPOSIT * 1e18 / rate) TODO-OWNER
///   SHIP_SALT            salt of order 1 (order 2 = SHIP_SALT + 1) default 1. Aqua refuses to ship the same
///                                                                 strategy twice: re-running needs a new salt.
///   USE_ONEINCH_ROUTER   true: 1inch AquaSwapVMRouter (Extruction 0x20)   default true
///                        false: RateSpaceAquaRouter (MovingPegSwap 0x59, fallback)
contract ShipSepolia is SepoliaDeployment {
    // ===== Owner-approved settings =====
    uint256 internal constant WIDTH = 50e27;
    uint16 internal constant BAND = 500;
    /// @dev 0.05% on v1.0.2's flat-fee 1e9 scale (1inch router)
    uint32 internal constant FEE_1E9 = 500000;
    /// @dev 0.05% on swap-vm 3b3da7d's FeeFlatIn 1e7 scale (RateSpaceAquaRouter)
    uint24 internal constant FEE_1E7 = 5000;

    uint256 internal constant ONE = 1e18;
    /// @dev TODO-OWNER: deposit size is NOT owner-approved; small placeholder (0.05 WETH per order)
    uint256 internal constant DEFAULT_WETH_DEPOSIT = 0.05e18;

    struct ShipParams {
        uint256 depWeth;
        uint256 depWst;
        uint64 salt;
        bool useOneInch;
        uint256 rate;
    }

    function run() external {
        require(block.chainid == SepoliaAddresses.CHAIN_ID, "ShipSepolia: Sepolia (chain 11155111) only");
        string memory path = _deploymentsPath();
        (Deployment memory d, OrderRecord[] memory prev) = _readDeployment(path);
        ShipParams memory p = params(d);

        vm.startBroadcast();
        (, address maker,) = vm.readCallers();
        OrderRecord[2] memory shipped = _shipBoth(d, p, maker);
        vm.stopBroadcast();

        OrderRecord[] memory all = new OrderRecord[](prev.length + 2);
        for (uint256 i = 0; i < prev.length; i++) all[i] = prev[i];
        all[prev.length] = shipped[0];
        all[prev.length + 1] = shipped[1];
        d.maker = maker;
        _writeDeployment(path, d, all);
    }

    /// @dev Test hooks set by setSalt / setUseOneInchRouter (vm.setEnv is process-global and races between
    ///   parallel tests). 0 = not set (use env / default).
    uint256 internal saltOverride;
    uint8 internal routerOverride;

    /// @notice Test hook: use `salt` instead of SHIP_SALT
    function setSalt(uint64 salt) external {
        saltOverride = uint256(salt) + 1;
    }

    /// @notice Test hook: use `useOneInch` instead of USE_ONEINCH_ROUTER
    function setUseOneInchRouter(bool useOneInch) external {
        routerOverride = useOneInch ? 1 : 2;
    }

    /// @notice Ship parameters from env, with the defaults documented on the contract
    function params(Deployment memory d) public view returns (ShipParams memory p) {
        p.rate = IRateProvider(d.rateProviderWstEth).rate();
        p.depWeth = vm.envOr("SHIP_WETH_DEPOSIT", DEFAULT_WETH_DEPOSIT); // TODO-OWNER
        p.depWst = vm.envOr("SHIP_WSTETH_DEPOSIT", p.depWeth * ONE / p.rate); // TODO-OWNER
        p.salt = saltOverride > 0 ? uint64(saltOverride - 1) : uint64(vm.envOr("SHIP_SALT", uint256(1)));
        p.useOneInch = routerOverride > 0 ? routerOverride == 1 : vm.envOr("USE_ONEINCH_ROUTER", true);
    }

    /// @dev Approves Aqua for both tokens and ships order 1 (no fee, salt) and order 2 (fee, salt + 1).
    ///   Every external call is made by this contract's caller context (the broadcaster in run(); the pranked
    ///   maker in the fork test), which Aqua records as the maker.
    function _shipBoth(Deployment memory d, ShipParams memory p, address maker)
        internal
        returns (OrderRecord[2] memory shipped)
    {
        // wstETH is Lt (lower address), so x0 / refRateLt / providerLt are the wstETH side
        require(d.wstEth < d.weth, "ShipSepolia: expected wstETH < WETH");
        require(p.depWeth > 0 && p.depWst > 0, "ShipSepolia: zero deposit");
        require(IERC20(d.weth).balanceOf(maker) >= p.depWeth, "ShipSepolia: maker WETH balance < SHIP_WETH_DEPOSIT");
        require(IERC20(d.wstEth).balanceOf(maker) >= p.depWst, "ShipSepolia: maker wstETH balance < SHIP_WSTETH_DEPOSIT");

        if (p.useOneInch) {
            require(
                RateSpaceOrderBuilder(d.builder).EXTRUCTION_OPCODE() == SepoliaAddresses.EXTRUCTION_OPCODE_SEPOLIA,
                "ShipSepolia: builder Extruction opcode != Sepolia router's"
            );
        }

        IERC20(d.wstEth).approve(d.aqua, type(uint256).max);
        IERC20(d.weth).approve(d.aqua, type(uint256).max);

        shipped[0] = _shipOne(d, p, maker, false, p.salt);
        shipped[1] = _shipOne(d, p, maker, true, p.salt + 1);
    }

    function _shipOne(Deployment memory d, ShipParams memory p, address maker, bool withFee, uint64 salt)
        internal
        returns (OrderRecord memory r)
    {
        // Both routers' Order structs are (address maker, uint256-typed traits, bytes data): one ABI encoding
        (address router, bytes memory program, bytes memory strategy, bytes32 routerHash, uint256 traits) =
            buildOrder(d, p, maker, withFee, salt);
        bytes32 h = keccak256(strategy);
        require(h == routerHash, "ShipSepolia: keccak(strategy) != router.hash(order)");
        (, uint8 tokensCount) = IAqua(d.aqua).rawBalances(maker, router, h, d.wstEth);
        require(tokensCount == 0, "ShipSepolia: strategy already shipped (or docked); set a new SHIP_SALT");

        address[] memory tokens = new address[](2);
        tokens[0] = d.wstEth;
        tokens[1] = d.weth;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = p.depWst;
        amounts[1] = p.depWeth;
        bytes32 sh = IAqua(d.aqua).ship(router, strategy, tokens, amounts);
        require(sh == h, "ShipSepolia: Aqua strategyHash mismatch");

        bytes memory data = abi.decode(strategy, (ISwapVM.Order)).data;
        r.maker = vm.toString(maker);
        r.traits = vm.toString(traits);
        r.data = vm.toString(data);
        r.program = vm.toString(program);
        r.strategyHash = vm.toString(sh);
        r.tokenYield = vm.toString(d.wstEth);
        r.tokenWeth = vm.toString(d.weth);
        r.hasFee = withFee;
        r.rateFeed = vm.toString(d.rateProviderWstEth);
        r.router = vm.toString(router);
    }

    /// @notice Builds one order without shipping it
    /// @return router the router the order is for
    /// @return program the SwapVM program bytes
    /// @return strategy abi.encode(order), the bytes passed to Aqua.ship
    /// @return routerHash router.hash(order) (== keccak256(strategy) for Aqua orders)
    /// @return traits the order's MakerTraits as uint256
    function buildOrder(Deployment memory d, ShipParams memory p, address maker, bool withFee, uint64 salt)
        public
        view
        returns (address router, bytes memory program, bytes memory strategy, bytes32 routerHash, uint256 traits)
    {
        uint256 x0 = MovingPegSwap.anchorFor(p.depWst, p.rate);
        uint256 y0 = MovingPegSwap.anchorFor(p.depWeth, ONE);
        if (p.useOneInch) {
            IRateSpaceOrderBuilder b = IRateSpaceOrderBuilder(d.builder);
            require(b.anchorFor(p.depWst, p.rate) == x0 && b.anchorFor(p.depWeth, ONE) == y0, "ShipSepolia: anchorFor");
            bytes memory mps = b.buildMovingPegArgs(x0, y0, WIDTH, p.rate, ONE, d.rateProviderWstEth, address(0), BAND);
            router = d.oneInchRouter;
            program = b.buildProgram(d.extruction, mps, withFee ? FEE_1E9 : 0, salt);
            ISwapVM.Order memory order = b.buildOrder(maker, program);
            strategy = b.encodeOrder(order);
            routerHash = ISwapVM(router).hash(order);
            traits = MakerTraits.unwrap(order.traits);
        } else {
            bytes memory mps = MovingPegSwap.build(x0, y0, WIDTH, p.rate, ONE, d.rateProviderWstEth, address(0), BAND);
            router = d.rateSpaceRouter;
            program = withFee
                ? bytes.concat(FeeFlatIn.build(FEE_1E7), mps, SaltV0.build(salt))
                : bytes.concat(mps, SaltV0.build(salt));
            ISwapVMV0.Order memory order = _orderV0(maker, d.wstEth, d.weth, program);
            strategy = abi.encode(order);
            routerHash = ISwapVMV0(router).hash(order);
            traits = MakerTraitsV0.unwrap(order.traits);
        }
    }

    /// @notice RateSpaceAquaRouter taker traits for an EOA taker in push mode (transferFrom + Aqua push), no
    ///   threshold / deadline / hooks. tokenA = wstETH, so wstETH -> WETH is A-to-B.
    /// @dev The 1inch-router equivalent is RateSpaceOrderBuilder.buildTakerData(taker, isExactIn, true).
    function takerDataRateSpace(bool wstToWeth, bool isExactIn) public pure returns (bytes memory) {
        return TakerTraitsLibV0.build(TakerTraitsLibV0.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            isAToB: wstToWeth,
            allowPartialFill: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    function _orderV0(address maker, address tokenA, address tokenB, bytes memory program)
        internal
        pure
        returns (ISwapVMV0.Order memory)
    {
        return MakerTraitsLibV0.build(MakerTraitsLibV0.Args({
            maker: maker,
            tokenA: tokenA,
            tokenB: tokenB,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program
        }));
    }
}
