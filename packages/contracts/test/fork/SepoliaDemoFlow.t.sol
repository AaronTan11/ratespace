// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAqua } from "@aqua-v1/src/interfaces/IAqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { ISwapVM as ISwapVMV0 } from "@swap-vm/interfaces/ISwapVM.sol";

import { IRateSpaceOrderBuilder } from "../../src/demo/IRateSpaceOrderBuilder.sol";
import { MovingPegExtructionArgs } from "../../src/extruction/MovingPegExtructionArgs.sol";
import { IWstETH } from "../../src/rate-providers/interfaces/IWstETH.sol";
import { WstETHRateProvider } from "../../src/rate-providers/WstETHRateProvider.sol";

import { DeploySepolia } from "../../script/DeploySepolia.s.sol";
import { ShipSepolia } from "../../script/ShipSepolia.s.sol";
import { SepoliaAddresses } from "../../script/SepoliaAddresses.sol";

interface ILidoStETH {
    function submit(address referral) external payable returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWstETHWrap {
    function wrap(uint256 stETHAmount) external returns (uint256);
}

interface IWETH9 {
    function deposit() external payable;
}

/// @notice Sepolia-fork run of the demo flow: DeploySepolia.deploy + ShipSepolia._shipBoth (the scripts' own
///   code, no broadcast), maker and taker funded with REAL Lido wstETH (stETH.submit -> approve -> wstETH.wrap)
///   and real WETH9 (deposit), then quote == swap in both directions on both shipped orders, through the
///   1inch Sepolia router (default path) and through RateSpaceAquaRouter (fallback path).
/// @dev Requires SEPOLIA_RPC_URL; without it every test is SKIPPED. Fork only: nothing is sent to any network.
contract SepoliaDemoFlowTest is Test, ShipSepolia {
    uint256 internal constant SWAP_AMOUNT = 0.01e18;
    uint256 internal constant ETH_PER_TOKEN = 1e18;

    string internal rpcUrl;
    bool internal forkOn;

    address internal maker;
    address internal taker;

    function setUp() public {
        rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        forkOn = bytes(rpcUrl).length > 0;
        maker = vm.addr(uint256(keccak256("sepolia-demo-maker")));
        taker = vm.addr(uint256(keccak256("sepolia-demo-taker")));
    }

    modifier onFork() {
        if (!forkOn) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, SepoliaAddresses.CHAIN_ID, "Sepolia chain id");
        emit log_named_uint("Sepolia fork block", block.number);
        _;
    }

    // ===== Funding along the path the owner will use on real Sepolia =====

    /// @dev ETH -> stETH (Lido submit) -> wstETH (wrap). Returns the wstETH minted.
    function _realWstEth(address to, uint256 ethIn) internal returns (uint256 minted) {
        vm.deal(to, to.balance + ethIn);
        uint256 wstBefore = IERC20(SepoliaAddresses.WSTETH).balanceOf(to);
        vm.startPrank(to);
        ILidoStETH(SepoliaAddresses.STETH).submit{ value: ethIn }(address(0));
        uint256 st = ILidoStETH(SepoliaAddresses.STETH).balanceOf(to);
        assertGt(st, 0, "stETH minted");
        ILidoStETH(SepoliaAddresses.STETH).approve(SepoliaAddresses.WSTETH, st);
        minted = IWstETHWrap(SepoliaAddresses.WSTETH).wrap(st);
        vm.stopPrank();
        assertEq(IERC20(SepoliaAddresses.WSTETH).balanceOf(to) - wstBefore, minted, "wstETH minted");
    }

    function _realWeth(address to, uint256 amount) internal {
        vm.deal(to, to.balance + amount);
        uint256 before = IERC20(SepoliaAddresses.WETH).balanceOf(to);
        vm.prank(to);
        IWETH9(SepoliaAddresses.WETH).deposit{ value: amount }();
        assertEq(IERC20(SepoliaAddresses.WETH).balanceOf(to) - before, amount, "WETH deposit");
    }

    // ===== Deploy + ship with the scripts' code =====

    function _deployAndShip(bool useOneInch)
        internal
        returns (Deployment memory d, ShipParams memory p, OrderRecord[2] memory rec)
    {
        d = new DeploySepolia().deploy(maker);
        assertEq(d.maker, maker);
        assertEq(d.aqua, SepoliaAddresses.AQUA);
        assertEq(d.oneInchRouter, SepoliaAddresses.ONEINCH_ROUTER);
        assertEq(WstETHRateProvider(d.rateProviderWstEth).rate(), IWstETH(SepoliaAddresses.WSTETH).stEthPerToken());

        p = params(d);
        p.useOneInch = useOneInch;
        emit log_named_uint("wstETH rate (stEthPerToken)", p.rate);
        emit log_named_uint("ship WETH deposit per order", p.depWeth);
        emit log_named_uint("ship wstETH deposit per order", p.depWst);

        uint256 mintedWst = _realWstEth(maker, ETH_PER_TOKEN);
        emit log_named_uint("maker wstETH from 1 ETH (submit + wrap)", mintedWst);
        _realWeth(maker, ETH_PER_TOKEN);

        vm.startPrank(maker);
        rec = _shipBoth(d, p, maker);
        vm.stopPrank();

        address router = useOneInch ? d.oneInchRouter : d.rateSpaceRouter;
        for (uint256 i = 0; i < 2; i++) {
            assertEq(vm.parseAddress(rec[i].router), router, "order router");
            assertEq(rec[i].hasFee, i == 1, "order hasFee");
            bytes32 h = vm.parseBytes32(rec[i].strategyHash);
            (uint248 bw,) = IAqua(d.aqua).rawBalances(maker, router, h, d.wstEth);
            (uint248 be,) = IAqua(d.aqua).rawBalances(maker, router, h, d.weth);
            assertEq(bw, p.depWst, "Aqua wstETH after ship");
            assertEq(be, p.depWeth, "Aqua WETH after ship");
        }

        // Taker: real wstETH and WETH, router approvals (push mode pulls tokenIn via the router)
        _realWstEth(taker, ETH_PER_TOKEN);
        _realWeth(taker, ETH_PER_TOKEN);
        vm.startPrank(taker);
        IERC20(d.wstEth).approve(router, type(uint256).max);
        IERC20(d.weth).approve(router, type(uint256).max);
        vm.stopPrank();
    }

    // ===== quote == swap, with wallet deltas =====

    struct Balances {
        uint256 takerIn;
        uint256 takerOut;
        uint256 makerIn;
        uint256 makerOut;
    }

    function _balances(address tIn, address tOut) internal view returns (Balances memory b) {
        b.takerIn = IERC20(tIn).balanceOf(taker);
        b.takerOut = IERC20(tOut).balanceOf(taker);
        b.makerIn = IERC20(tIn).balanceOf(maker);
        b.makerOut = IERC20(tOut).balanceOf(maker);
    }

    function _quoteSwap(Deployment memory d, ShipParams memory p, uint256 idx, bool wstToWeth, string memory label)
        internal
        returns (uint256 aIn, uint256 aOut)
    {
        (address tIn, address tOut) = wstToWeth ? (d.wstEth, d.weth) : (d.weth, d.wstEth);
        (,, bytes memory strategy,,) = buildOrder(d, p, maker, idx == 1, p.salt + uint64(idx));
        uint256 qIn;
        uint256 qOut;
        uint256 gasUsed;
        Balances memory b = _balances(tIn, tOut);

        if (p.useOneInch) {
            ISwapVM.Order memory order = abi.decode(strategy, (ISwapVM.Order));
            bytes memory td = IRateSpaceOrderBuilder(d.builder).buildTakerData(taker, true, true);
            (qIn, qOut,) = ISwapVM(d.oneInchRouter).quote(order, tIn, tOut, SWAP_AMOUNT, td);
            vm.startPrank(taker, taker);
            uint256 g = gasleft();
            (aIn, aOut,) = ISwapVM(d.oneInchRouter).swap(order, tIn, tOut, SWAP_AMOUNT, td);
            gasUsed = g - gasleft();
            vm.stopPrank();
        } else {
            ISwapVMV0.Order memory order = abi.decode(strategy, (ISwapVMV0.Order));
            bytes memory td = takerDataRateSpace(wstToWeth, true);
            (qIn, qOut,) = ISwapVMV0(d.rateSpaceRouter).quote(order, SWAP_AMOUNT, td);
            vm.startPrank(taker, taker);
            uint256 g = gasleft();
            (aIn, aOut,) = ISwapVMV0(d.rateSpaceRouter).swap(order, SWAP_AMOUNT, td);
            gasUsed = g - gasleft();
            vm.stopPrank();
        }

        assertEq(aIn, qIn, string.concat(label, ": quote == swap amountIn"));
        assertEq(aOut, qOut, string.concat(label, ": quote == swap amountOut"));
        assertEq(aIn, SWAP_AMOUNT, string.concat(label, ": exactIn amountIn"));
        assertGt(aOut, 0, string.concat(label, ": amountOut > 0"));

        Balances memory a = _balances(tIn, tOut);
        assertEq(b.takerIn - a.takerIn, aIn, string.concat(label, ": taker tokenIn delta"));
        assertEq(a.takerOut - b.takerOut, aOut, string.concat(label, ": taker tokenOut delta"));
        assertEq(a.makerIn - b.makerIn, aIn, string.concat(label, ": maker tokenIn wallet delta"));
        assertEq(b.makerOut - a.makerOut, aOut, string.concat(label, ": maker tokenOut wallet decreases by the payout"));

        emit log_named_uint(string.concat(label, " amountIn"), aIn);
        emit log_named_uint(string.concat(label, " amountOut"), aOut);
        emit log_named_uint(string.concat(label, " gas (swap call)"), gasUsed);
    }

    function _flow(bool useOneInch, string memory tag) internal {
        (Deployment memory d, ShipParams memory p,) = _deployAndShip(useOneInch);
        uint256 makerWethStart = IERC20(d.weth).balanceOf(maker);
        uint256 paidWeth;
        uint256 receivedWeth;
        for (uint256 i = 0; i < 2; i++) {
            string memory o = i == 0 ? " order1(no fee)" : " order2(fee)";
            (uint256 inW,) = _quoteSwap(d, p, i, false, string.concat(tag, o, " WETH->wstETH"));
            (, uint256 outW) = _quoteSwap(d, p, i, true, string.concat(tag, o, " wstETH->WETH"));
            receivedWeth += inW;
            paidWeth += outW;
        }
        assertEq(makerWethStart + receivedWeth - paidWeth, IERC20(d.weth).balanceOf(maker), "maker WETH net");
        emit log_named_uint(string.concat(tag, " maker WETH paid out (wstETH->WETH, both orders)"), paidWeth);
    }

    // ===== Tests =====

    /// @dev Default path: orders on 1inch's Sepolia AquaSwapVMRouter via Extruction 0x20
    function test_Flow_OneInchRouter() public onFork {
        assertEq(MovingPegExtructionArgs.EXTRUCTION_OPCODE, SepoliaAddresses.EXTRUCTION_OPCODE_SEPOLIA, "builder opcode");
        assertTrue(vm.envOr("USE_ONEINCH_ROUTER", true), "default path is the 1inch router");
        _flow(true, "1inch");
    }

    /// @dev Fallback path: orders on RateSpaceAquaRouter via MovingPegSwap 0x59
    function test_Flow_RateSpaceRouter() public onFork {
        _flow(false, "RateSpace");
    }

    /// @dev Both paths price the same order identically (same anchors, same live rate, same Aqua balances)
    function test_BothRoutersQuoteEqual() public onFork {
        (Deployment memory d, ShipParams memory p,) = _deployAndShip(true);
        vm.startPrank(maker);
        p.useOneInch = false;
        _shipBoth(d, p, maker);
        vm.stopPrank();
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 dir = 0; dir < 2; dir++) {
                bool wstToWeth = dir == 1;
                (address tIn, address tOut) = wstToWeth ? (d.wstEth, d.weth) : (d.weth, d.wstEth);
                p.useOneInch = true;
                (,, bytes memory s1,,) = buildOrder(d, p, maker, i == 1, p.salt + uint64(i));
                p.useOneInch = false;
                (,, bytes memory s0,,) = buildOrder(d, p, maker, i == 1, p.salt + uint64(i));
                (, uint256 q1,) = ISwapVM(d.oneInchRouter).quote(
                    abi.decode(s1, (ISwapVM.Order)), tIn, tOut, SWAP_AMOUNT,
                    IRateSpaceOrderBuilder(d.builder).buildTakerData(taker, true, true)
                );
                (, uint256 q0,) = ISwapVMV0(d.rateSpaceRouter).quote(
                    abi.decode(s0, (ISwapVMV0.Order)), SWAP_AMOUNT, takerDataRateSpace(wstToWeth, true)
                );
                assertEq(q1, q0, "1inch router quote == RateSpaceAquaRouter quote");
                emit log_named_uint(string.concat("quote order", vm.toString(i + 1), wstToWeth ? " wstETH->WETH" : " WETH->wstETH"), q1);
            }
        }
    }

    /// @dev A second ship with the same salt is refused before Aqua (StrategiesMustBeImmutable)
    function test_ReShipSameSaltRefused() public onFork {
        (Deployment memory d, ShipParams memory p,) = _deployAndShip(true);
        vm.startPrank(maker);
        vm.expectRevert(bytes("ShipSepolia: strategy already shipped (or docked); set a new SHIP_SALT"));
        this.shipAgain(d, p);
        vm.stopPrank();
    }

    function shipAgain(Deployment memory d, ShipParams memory p) external {
        _shipBoth(d, p, maker);
    }

    // ===== Offline checks (no fork) =====

    /// @dev The literals script/demo-sepolia-fork.sh passes to RateSpaceAquaRouter
    function test_TakerDataLiterals() public pure {
        assertEq(takerDataRateSpace(true, true), hex"000000000000000000000000000000000000000000c1");
        assertEq(takerDataRateSpace(false, true), hex"00000000000000000000000000000000000000000041");
    }

    /// @dev JSON written by the scripts parses back to the same values (orders re-emitted byte-for-byte)
    function test_JsonRoundTrip() public {
        Deployment memory d = Deployment({
            maker: address(0x1001),
            aqua: SepoliaAddresses.AQUA,
            oneInchRouter: SepoliaAddresses.ONEINCH_ROUTER,
            rateSpaceRouter: address(0x1002),
            extruction: address(0x1003),
            builder: address(0x1004),
            weth: SepoliaAddresses.WETH,
            wstEth: SepoliaAddresses.WSTETH,
            rateProviderWstEth: address(0x1005)
        });
        vm.chainId(SepoliaAddresses.CHAIN_ID);
        // Unique per forge process (gitignored deployments/test-*.json): parallel runs never share the file
        string memory path = string.concat(
            "deployments/test-roundtrip-", vm.toString(vm.unixTime()), "-", vm.toString(vm.randomUint()), ".json"
        );

        _writeDeployment(path, d, new OrderRecord[](0));
        (Deployment memory r0, OrderRecord[] memory o0) = _readDeployment(path);
        assertEq(o0.length, 0);
        assertEq(keccak256(abi.encode(r0)), keccak256(abi.encode(d)), "deployment round trip");

        OrderRecord[] memory two = new OrderRecord[](2);
        two[0] = OrderRecord("0x0000000000000000000000000000000000001001", "123", "0xabcd", "0x20", "0x01", "0x02", "0x03", false, "0x04", "0x05");
        two[1] = OrderRecord("0x0000000000000000000000000000000000001001", "456", "0xef", "0x15", "0x06", "0x07", "0x08", true, "0x09", "0x0a");
        _writeDeployment(path, d, two);
        string memory written = vm.readFile(path);
        (Deployment memory r1, OrderRecord[] memory o1) = _readDeployment(path);
        assertEq(keccak256(abi.encode(r1)), keccak256(abi.encode(d)));
        assertEq(o1.length, 2);
        assertEq(keccak256(abi.encode(o1[0])), keccak256(abi.encode(two[0])), "order 0 round trip");
        assertEq(keccak256(abi.encode(o1[1])), keccak256(abi.encode(two[1])), "order 1 round trip");
        // Re-emitting what was read is byte-identical (ShipSepolia appends without rewriting earlier orders)
        _writeDeployment(path, r1, o1);
        assertEq(vm.readFile(path), written, "re-emit byte-identical");
        vm.removeFile(path);
    }
}
