// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@aqua-v1/src/Aqua.sol";
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@swap-vm-v1/routers/AquaSwapVMRouter.sol";

import { MovingPegExtruction } from "../../src/extruction/MovingPegExtruction.sol";
import { MovingPegSwap } from "../../src/instructions/MovingPegSwap.sol";
import { RateSpaceOrderBuilder } from "../../src/demo/RateSpaceOrderBuilder.sol";
import { DemoWETH } from "../../src/demo/mocks/DemoWETH.sol";
import { DemoYieldToken } from "../../src/demo/mocks/DemoYieldToken.sol";
import { DemoRateFeed } from "../../src/demo/mocks/DemoRateFeed.sol";

// ===== swap-vm 3b3da7d (lib/swap-vm): our RateSpaceAquaRouter (MovingPegSwap opcode 0x59), for the reference fill =====
import { Aqua as AquaV0 } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM as ISwapVMV0 } from "@swap-vm/interfaces/ISwapVM.sol";
import { MakerTraitsLib as MakerTraitsLibV0 } from "@swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib as TakerTraitsLibV0 } from "@swap-vm/libs/TakerTraits.sol";
import { Salt as SaltV0 } from "@swap-vm/instructions/Controls.sol";
import { MockTaker as MockTakerV0 } from "@swap-vm-test/mocks/MockTaker.sol";
import { RateSpaceAquaRouter } from "../../src/routers/RateSpaceAquaRouter.sol";

import { DeployDemo } from "../../script/DeployDemo.s.sol";

/// @dev Inherits the demo script and exposes its internal `_ship` and constants. The harness itself is the
///   maker: `_ship` calls `aqua.ship` from the harness, exactly as the script does from the broadcast key.
contract DeployDemoHarness is DeployDemo {
    function fee1e9() external pure returns (uint32) { return FEE_1E9; }
    function makerWeth() external pure returns (uint256) { return MAKER_WETH; }
    function rateWstEth() external pure returns (uint256) { return RATE_WSTETH; }
    function width() external pure returns (uint256) { return WIDTH; }
    function band() external pure returns (uint16) { return BAND; }

    function approveAqua(Deployed memory d) external {
        d.weth.approve(address(d.aqua), type(uint256).max);
        d.tokens[0].approve(address(d.aqua), type(uint256).max);
    }

    function ship(Deployed memory d, uint256 k, uint256 yieldDeposit, uint32 fee, uint64 salt)
        external
        returns (ShippedOrder memory)
    {
        return _ship(d, address(this), k, yieldDeposit, fee, salt);
    }
}

/// @notice LOCAL (no network): DeployDemo's `_ship` + constants, on the v1.0.2 router, in BOTH token address
///   orderings (yield token = Lt and yield token = Gt).
contract DeployDemoTest is Test {
    uint256 internal constant ONE = 1e18;
    /// @dev SECONDARY check only: the "G3 market 0 WETH out" logged by test/SharedLiquidity.t.sol
    ///   test_G3_OneWalletServesThreeMarkets (0x59 router, 1e18 wstETH-like sold into 10e18 WETH /
    ///   8033498217483780461 wstETH-like at 1244787728742679575). The primary check is the reference fill
    ///   computed in this file by _refOurs on RateSpaceAquaRouter.
    uint256 internal constant SHARED_LIQ_OUT = 1244017430410107798;
    uint256 internal constant DEPOSIT = 8033498217483780461;
    uint256 internal constant SELL = 1e18;

    /// @dev Each ordering run gets its OWN pair of addresses, so no token storage survives between runs
    address internal constant LOW = address(uint160(0x100000));
    address internal constant HIGH = address(uint160(0x200000));
    address internal constant LOW2 = address(uint160(0x300000));
    address internal constant HIGH2 = address(uint160(0x400000));

    struct Case {
        DeployDemoHarness h;
        DeployDemo.Deployed d;
        DeployDemo.ShippedOrder plain;
        DeployDemo.ShippedOrder fee;
    }

    function _deploy(bool yieldIsLt, address lowAt, address highAt) internal returns (Case memory c) {
        (address wethAt, address yieldAt) = yieldIsLt ? (highAt, lowAt) : (lowAt, highAt);
        assertEq(wethAt.code.length, 0, "fresh WETH address");
        assertEq(yieldAt.code.length, 0, "fresh yield token address");
        deployCodeTo("DemoWETH.sol:DemoWETH", "", wethAt);
        deployCodeTo("DemoYieldToken.sol:DemoYieldToken", abi.encode("Demo wstETH", "wstETH"), yieldAt);

        c.h = new DeployDemoHarness();
        c.d.aqua = new Aqua();
        c.d.weth = DemoWETH(payable(wethAt));
        c.d.router = new AquaSwapVMRouter(address(c.d.aqua), wethAt, address(this), "1inch SwapVM v1.0", "1.0.2");
        c.d.target = new MovingPegExtruction();
        c.d.builder = new RateSpaceOrderBuilder();
        c.d.tokens[0] = DemoYieldToken(yieldAt);
        c.d.feeds[0] = new DemoRateFeed(c.h.rateWstEth());

        assertEq(c.d.tokens[0].symbol(), "wstETH", "yield token deployed");
        assertEq(c.d.weth.symbol(), "WETH", "DemoWETH deployed");
        assertEq(address(c.d.tokens[0]) < address(c.d.weth), yieldIsLt, "address ordering");
        emit log_named_address(yieldIsLt ? "[yield=Lt] yield token" : "[yield=Gt] yield token", yieldAt);
        emit log_named_address(yieldIsLt ? "[yield=Lt] DemoWETH" : "[yield=Gt] DemoWETH", wethAt);

        // Maker (the harness) funding, as in DeployDemo.run()
        uint256 rate = c.d.feeds[0].rate();
        assertEq(rate, 1244787728742679575, "RATE_WSTETH");
        uint256 deposit = c.h.makerWeth() * ONE / rate;
        assertEq(c.h.makerWeth(), 10e18, "MAKER_WETH");
        assertEq(deposit, DEPOSIT, "yield deposit = MAKER_WETH * 1e18 / rate");
        c.d.weth.mint(address(c.h), c.h.makerWeth());
        c.d.tokens[0].mint(address(c.h), deposit);
        c.h.approveAqua(c.d);

        c.plain = c.h.ship(c.d, 0, deposit, 0, 1);
        c.fee = c.h.ship(c.d, 0, deposit, c.h.fee1e9(), 4);
        assertFalse(c.plain.hasFee, "order 1 no fee");
        assertTrue(c.fee.hasFee, "order 4 fee");
    }

    function _word(bytes memory b, uint256 off) internal pure returns (uint256 w) {
        require(b.length >= off + 32, "short program");
        assembly ("memory-safe") { w := mload(add(add(b, 32), off)) }
    }

    function _addrAt(bytes memory b, uint256 off) internal pure returns (address) {
        return address(uint160(_word(b, off) >> 96));
    }

    /// @dev Parses the Extruction instruction at `p` and checks every MovingPegSwap field against the
    ///   script's intent: yield anchor = anchorFor(deposit, rate), WETH anchor = 10e18, Lt/Gt placement
    function _assertProgram(Case memory c, bytes memory program, uint256 p, bool yieldIsLt) internal view {
        assertEq(uint8(program[p]), 0x20, "Extruction opcode");
        assertEq(uint8(program[p + 1]), 222, "Extruction args length = 20 + 202");
        assertEq(_addrAt(program, p + 2), address(c.d.target), "target");
        uint256 a = p + 22;
        uint256 x0 = _word(program, a);
        uint256 y0 = _word(program, a + 32);
        uint256 rLt = _word(program, a + 96);
        uint256 rGt = _word(program, a + 128);
        address pLt = _addrAt(program, a + 160);
        address pGt = _addrAt(program, a + 180);
        uint16 band = (uint16(uint8(program[a + 200])) << 8) | uint16(uint8(program[a + 201]));

        uint256 rate = c.d.feeds[0].rate();
        uint256 yieldAnchor = MovingPegSwap.anchorFor(DEPOSIT, rate);
        (uint256 yA, uint256 wA) = yieldIsLt ? (x0, y0) : (y0, x0);
        assertEq(yA, yieldAnchor, "yield anchor = anchorFor(yieldDeposit, rate)");
        assertEq(wA, 10e18, "WETH anchor = 10e18");
        assertEq(MovingPegSwap.anchorFor(10e18, ONE), 10e18, "anchorFor(10e18, 1e18)");
        assertEq(_word(program, a + 64), c.h.width(), "width");
        assertEq(band, c.h.band(), "band");
        if (yieldIsLt) {
            assertEq(rLt, rate, "refRateLt = yield rate");
            assertEq(rGt, ONE, "refRateGt = 1e18");
            assertEq(pLt, address(c.d.feeds[0]), "providerLt = feed");
            assertEq(pGt, address(0), "providerGt = none");
        } else {
            assertEq(rLt, ONE, "refRateLt = 1e18");
            assertEq(rGt, rate, "refRateGt = yield rate");
            assertEq(pLt, address(0), "providerLt = none");
            assertEq(pGt, address(c.d.feeds[0]), "providerGt = feed");
        }
    }

    /// @dev EOA taker, pushMode (the app's path): sell `amount` yield token exactIn; asserts quote == swap and
    ///   before/after balance DELTAS for the taker and the maker (the harness)
    function _sell(Case memory c, ISwapVM.Order memory order, uint256 amount, string memory seed) internal returns (uint256 aOut) {
        address eoa = vm.addr(uint256(keccak256(bytes(seed))));
        c.d.tokens[0].mint(eoa, amount);
        bytes memory td = c.d.builder.buildTakerData(eoa, true, true);
        uint256[4] memory b = [
            c.d.tokens[0].balanceOf(eoa),
            c.d.weth.balanceOf(eoa),
            c.d.tokens[0].balanceOf(address(c.h)),
            c.d.weth.balanceOf(address(c.h))
        ];
        vm.startPrank(eoa, eoa);
        c.d.tokens[0].approve(address(c.d.router), type(uint256).max);
        (, uint256 qOut,) = c.d.router.quote(order, address(c.d.tokens[0]), address(c.d.weth), amount, td);
        uint256 aIn;
        (aIn, aOut,) = c.d.router.swap(order, address(c.d.tokens[0]), address(c.d.weth), amount, td);
        vm.stopPrank();
        assertEq(aIn, amount, "exactIn amountIn");
        assertEq(aOut, qOut, "quote == swap");
        assertEq(b[0] - c.d.tokens[0].balanceOf(eoa), aIn, "EOA yield delta");
        assertEq(c.d.weth.balanceOf(eoa) - b[1], aOut, "EOA WETH delta");
        assertEq(c.d.tokens[0].balanceOf(address(c.h)) - b[2], aIn, "maker yield delta");
        assertEq(b[3] - c.d.weth.balanceOf(address(c.h)), aOut, "maker WETH delta");
    }

    /// @dev Reference fill on OUR RateSpaceAquaRouter (swap-vm 3b3da7d, MovingPegSwap 0x59) on a fresh Aqua, with
    ///   the same tokens, the same feed, the same deposits (10e18 WETH / DEPOSIT yield) and the owner's
    ///   WIDTH 50e27 / BAND 500: sell SELL yield token exactIn and return the WETH out (quote == swap, deltas)
    function _refOurs(Case memory c, string memory seed) internal returns (uint256 aOut) {
        address y = address(c.d.tokens[0]);
        address w = address(c.d.weth);
        bool yieldIsLt = y < w;
        address feed = address(c.d.feeds[0]);
        uint256 rate = c.d.feeds[0].rate();
        uint256 yA = MovingPegSwap.anchorFor(DEPOSIT, rate);
        uint256 wA = MovingPegSwap.anchorFor(10e18, ONE);

        AquaV0 aq = new AquaV0();
        RateSpaceAquaRouter ours = new RateSpaceAquaRouter(address(aq), w, address(this), "SwapVM", "1.0.0");
        MockTakerV0 tk = new MockTakerV0(aq, ours, address(this));
        address mk = vm.addr(uint256(keccak256(bytes(string.concat(seed, "-maker")))));

        bytes memory program = bytes.concat(
            yieldIsLt
                ? MovingPegSwap.build(yA, wA, 50e27, rate, ONE, feed, address(0), 500)
                : MovingPegSwap.build(wA, yA, 50e27, ONE, rate, address(0), feed, 500),
            SaltV0.build(1)
        );
        (address tLt, address tGt) = yieldIsLt ? (y, w) : (w, y);
        ISwapVMV0.Order memory order = MakerTraitsLibV0.build(MakerTraitsLibV0.Args({
            maker: mk,
            tokenA: tLt,
            tokenB: tGt,
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

        c.d.weth.mint(mk, 10e18);
        c.d.tokens[0].mint(mk, DEPOSIT);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (tLt, tGt);
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = yieldIsLt ? (DEPOSIT, uint256(10e18)) : (uint256(10e18), DEPOSIT);
        vm.startPrank(mk);
        c.d.weth.approve(address(aq), type(uint256).max);
        c.d.tokens[0].approve(address(aq), type(uint256).max);
        bytes32 sh = aq.ship(address(ours), abi.encode(order), tokens, amounts);
        vm.stopPrank();
        assertEq(sh, ours.hash(order), "ref strategy hash");

        bytes memory td = TakerTraitsLibV0.build(TakerTraitsLibV0.Args({
            taker: address(tk),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: yieldIsLt,
            allowPartialFill: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: true,
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
        (uint256 qIn, uint256 qOut,) = ISwapVMV0(address(ours)).quote(order, SELL, td);
        c.d.tokens[0].mint(address(tk), SELL);
        uint256 inBefore = c.d.tokens[0].balanceOf(address(tk));
        uint256 outBefore = c.d.weth.balanceOf(address(tk));
        uint256 aIn;
        (aIn, aOut) = tk.swap(order, SELL, td);
        assertEq(aIn, SELL, "ref exactIn amountIn");
        assertEq(aIn, qIn, "ref quote == swap amountIn");
        assertEq(aOut, qOut, "ref quote == swap amountOut");
        assertEq(inBefore - c.d.tokens[0].balanceOf(address(tk)), aIn, "ref taker yield delta");
        assertEq(c.d.weth.balanceOf(address(tk)) - outBefore, aOut, "ref taker WETH delta");
    }

    function _run(bool yieldIsLt, address lowAt, address highAt)
        internal
        returns (uint256 outPlain, uint256 outFee, uint256 outNoFeeReduced, uint256 outRef)
    {
        Case memory c = _deploy(yieldIsLt, lowAt, highAt);
        _assertProgram(c, c.plain.program, 0, yieldIsLt);
        // Fee program: [21][4][feeBps u32] then the same Extruction instruction
        assertEq(uint8(c.fee.program[0]), 21, "flat fee opcode");
        assertEq(uint8(c.fee.program[1]), 4, "flat fee args length");
        assertEq(uint32(_word(c.fee.program, 2) >> 224), 500000, "fee bytes = 500000");
        _assertProgram(c, c.fee.program, 6, yieldIsLt);

        // v1.0.2 _flatFeeAmountInXD, exactIn: the swap instruction sees amountIn - ceil(amountIn * fee / 1e9)
        // (Fee.sol BPS = 1e9). Owner fee is the literal 500000 here, independent of the script's constant.
        uint256 reducedIn = SELL - Math.ceilDiv(SELL * 500000, 1e9);
        (, outNoFeeReduced,) = c.d.router.quote(
            c.plain.order, address(c.d.tokens[0]), address(c.d.weth), reducedIn,
            c.d.builder.buildTakerData(address(this), true, true)
        );

        outPlain = _sell(c, c.plain.order, SELL, "demo-taker-plain");
        outFee = _sell(c, c.fee.order, SELL, "demo-taker-fee");
        string memory tag = yieldIsLt ? "[yield=Lt]" : "[yield=Gt]";
        outRef = _refOurs(c, tag);
        emit log_named_uint(string.concat(tag, " 0x59 RateSpaceAquaRouter reference out for 1e18"), outRef);
        emit log_named_uint(string.concat(tag, " no-fee out for 1e18"), outPlain);
        emit log_named_uint(string.concat(tag, " fee out for 1e18"), outFee);
        emit log_named_uint(string.concat(tag, " no-fee quote for 1e18 - ceil(1e18 * 500000 / 1e9)"), outNoFeeReduced);
    }

    function test_DeployDemo_FeeConstant() public {
        DeployDemoHarness h = new DeployDemoHarness();
        assertEq(h.fee1e9(), 500000, "FEE_1E9 = 0.05% on the 1e9 scale");
        assertEq(uint256(h.fee1e9()) * 10000 / 1e9, 5, "5 bps");
    }

    function test_DeployDemo_BothOrderings() public {
        (uint256 pLt, uint256 fLt, uint256 rLt, uint256 refLt) = _run(true, LOW, HIGH);
        (uint256 pGt, uint256 fGt, uint256 rGt, uint256 refGt) = _run(false, LOW2, HIGH2);

        // (a) same amount both ways, equal to the same sell on our 0x59 router (computed above, per ordering)
        assertEq(pLt, refLt, "yield=Lt: v1.0.2 + Extruction out == RateSpaceAquaRouter 0x59 out");
        assertEq(pGt, refGt, "yield=Gt: v1.0.2 + Extruction out == RateSpaceAquaRouter 0x59 out");
        assertEq(pLt, pGt, "no-fee out: yield=Lt == yield=Gt");
        // secondary: the literal logged by test/SharedLiquidity.t.sol G3 market 0
        assertEq(pLt, SHARED_LIQ_OUT, "no-fee out = SharedLiquidity G3 market 0");
        // (b) fee order == no-fee order fed amountIn net of the v1.0.2 flat fee
        assertEq(fLt, rLt, "yield=Lt: fee out == no-fee out at the net amountIn");
        assertEq(fGt, rGt, "yield=Gt: fee out == no-fee out at the net amountIn");
        assertEq(fLt, fGt, "fee out: yield=Lt == yield=Gt");
        assertLt(fLt, pLt, "fee out < no-fee out");
        assertEq(fLt, FEE_OUT, "fee out pinned");
    }

    // ===== DeployDemo.run() itself: the four-order table built by the script's own loop =====

    string internal constant DEPLOYMENTS = "deployments/31337.json";

    struct Shipped {
        bytes32 strategyHash;
        ISwapVM.Order order;
        address yieldToken;
    }

    /// @dev Aqua 0.1.0 Shipped / Pushed events emitted by `aqua` in `logs`, in emission order. `ship` pushes
    ///   tokens[0] (the yield token in DeployDemo._ship) first, so the first Pushed per strategy is its yield token
    function _shippedFromLogs(Vm.Log[] memory logs, address aqua, address weth) internal pure returns (Shipped[] memory out) {
        bytes32 shippedSig = keccak256("Shipped(address,address,bytes32,bytes)");
        bytes32 pushedSig = keccak256("Pushed(address,address,bytes32,address,uint256)");
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == aqua && logs[i].topics[0] == shippedSig) n++;
        }
        out = new Shipped[](n);
        uint256 k;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != aqua) continue;
            if (logs[i].topics[0] == shippedSig) {
                (,, bytes32 h, bytes memory strategy) = abi.decode(logs[i].data, (address, address, bytes32, bytes));
                out[k].strategyHash = h;
                out[k].order = abi.decode(strategy, (ISwapVM.Order));
                k++;
            } else if (logs[i].topics[0] == pushedSig && k > 0) {
                (,, bytes32 h, address token,) = abi.decode(logs[i].data, (address, address, bytes32, address, uint256));
                if (h == out[k - 1].strategyHash && token != weth && out[k - 1].yieldToken == address(0)) {
                    out[k - 1].yieldToken = token;
                }
            }
        }
    }

    /// @dev The non-zero rate provider of the Extruction instruction at `p` (the yield token's feed)
    function _feedIn(bytes memory program, uint256 p) internal pure returns (address) {
        address pLt = _addrAt(program, p + 22 + 160);
        address pGt = _addrAt(program, p + 22 + 180);
        return pLt != address(0) ? pLt : pGt;
    }

    /// @dev One row of the run() order table: JSON row == shipped order, and == the expected market / fee
    function _checkRow(string memory json, uint256 i, Shipped memory shipped, address expToken, address expFeed, bool expFee)
        internal
    {
        string memory o = string.concat(".orders[", vm.toString(i), "]");
        string memory tag = string.concat("order ", vm.toString(i));
        bytes memory program = vm.parseJsonBytes(json, string.concat(o, ".program"));
        address tokenYield = vm.parseJsonAddress(json, string.concat(o, ".tokenYield"));
        bool hasFee = vm.parseJsonBool(json, string.concat(o, ".hasFee"));

        // the JSON row is the order that was actually shipped, in the same position
        assertEq(vm.parseJsonBytes32(json, string.concat(o, ".strategyHash")), shipped.strategyHash, string.concat(tag, " strategyHash"));
        assertEq(shipped.order.data, program, string.concat(tag, " shipped order data == JSON program"));
        assertEq(shipped.yieldToken, tokenYield, string.concat(tag, " Aqua-pushed yield token == JSON tokenYield"));

        assertEq(hasFee, expFee, string.concat(tag, " hasFee"));
        assertEq(tokenYield, expToken, string.concat(tag, " tokenYield = market token"));
        assertEq(vm.parseJsonAddress(json, string.concat(o, ".rateFeed")), expFeed, string.concat(tag, " rateFeed"));

        uint256 p = expFee ? 6 : 0;
        if (expFee) {
            // FlatFee instruction for 500000: [21 = _flatFeeAmountInXD][4][uint32 500000 = 0x0007a120]
            bytes memory head = new bytes(6);
            for (uint256 j = 0; j < 6; j++) head[j] = program[j];
            assertEq(head, hex"15040007a120", string.concat(tag, " starts with FlatFee(500000)"));
        }
        assertEq(uint8(program[p]), 0x20, string.concat(tag, " Extruction opcode"));
        assertEq(uint8(program[p + 1]), 222, string.concat(tag, " Extruction args length"));
        assertEq(_feedIn(program, p), expFeed, string.concat(tag, " program provider = market feed"));
        // salt instruction last: [20][8][uint64 i + 1]
        assertEq(program.length, p + 224 + 10, string.concat(tag, " program length"));
        assertEq(uint8(program[p + 224]), 20, string.concat(tag, " salt opcode"));
        assertEq(uint64(_word(program, program.length - 32)), uint64(i + 1), string.concat(tag, " salt"));
        emit log_named_address(string.concat(tag, " tokenYield"), tokenYield);
        emit log_named_string(string.concat(tag, " hasFee"), hasFee ? "true" : "false");
    }

    /// @dev Calls the script's real run() (the loop at script/DeployDemo.s.sol:98-101), then reads the order table
    ///   back from BOTH the Aqua Shipped/Pushed events and the deployments JSON run() writes. The tracked
    ///   deployments/31337.json is restored byte-for-byte right after run() returns.
    function test_DeployDemo_RunOrderTable() public {
        string memory saved = vm.readFile(DEPLOYMENTS);
        vm.recordLogs();
        new DeployDemo().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        string memory json = vm.readFile(DEPLOYMENTS);
        vm.writeFile(DEPLOYMENTS, saved);
        assertEq(keccak256(bytes(vm.readFile(DEPLOYMENTS))), keccak256(bytes(saved)), "deployments json restored");

        address aqua = vm.parseJsonAddress(json, ".Aqua");
        address weth = vm.parseJsonAddress(json, ".DemoWETH");
        address[3] memory tokens = [
            vm.parseJsonAddress(json, ".DemoWstETH"),
            vm.parseJsonAddress(json, ".DemoRETH"),
            vm.parseJsonAddress(json, ".DemoWeETH")
        ];
        address[3] memory feeds = [
            vm.parseJsonAddress(json, ".RateFeedWstETH"),
            vm.parseJsonAddress(json, ".RateFeedRETH"),
            vm.parseJsonAddress(json, ".RateFeedWeETH")
        ];
        assertEq(DemoYieldToken(tokens[0]).symbol(), "wstETH", "market 0 = wstETH");
        assertEq(DemoYieldToken(tokens[1]).symbol(), "rETH", "market 1 = rETH");
        assertEq(DemoYieldToken(tokens[2]).symbol(), "weETH", "market 2 = weETH");

        Shipped[] memory shipped = _shippedFromLogs(logs, aqua, weth);
        assertEq(shipped.length, 4, "run() ships four orders");

        // Expected table, from the brief: orders 0..2 = markets 0,1,2 without fee; order 3 = market 0 with the fee
        uint256[4] memory market = [uint256(0), 1, 2, 0];
        bool[4] memory fee = [false, false, false, true];
        for (uint256 i = 0; i < 4; i++) {
            _checkRow(json, i, shipped[i], tokens[market[i]], feeds[market[i]], fee[i]);
        }

        // order 3 is order 0's Extruction instruction behind the fee (same market, same pricing args)
        bytes memory p0 = vm.parseJsonBytes(json, ".orders[0].program");
        bytes memory p3 = vm.parseJsonBytes(json, ".orders[3].program");
        for (uint256 j = 0; j < 224; j++) {
            assertEq(p3[6 + j], p0[j], "order 3 Extruction == order 0 Extruction");
        }
    }

    /// @dev Measured by test_DeployDemo_BothOrderings (fee order, 1e18 yield sold exactIn)
    uint256 internal constant FEE_OUT = 1243395810130833463;
}
