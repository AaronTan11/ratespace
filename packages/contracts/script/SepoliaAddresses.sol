// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Sepolia (chain 11155111) addresses used by DeploySepolia / ShipSepolia and the Sepolia fork test.
/// @dev Checked with cast against Sepolia on 2026-09-26 (block 11786360): code sizes Aqua 5619, 1inch router 20379,
///   wstETH 6492, stETH 1007, WETH 3124; the mainnet router address 0x111111338c5091E8440b67B168bAe16a668AC0De has
///   no code on Sepolia; router.AQUA() == AQUA; wstETH.stETH() == STETH; stETH.isStakingPaused() == false.
library SepoliaAddresses {
    uint256 internal constant CHAIN_ID = 11155111;

    /// @dev 1inch Aqua (same canonical address as mainnet)
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    /// @dev 1inch AquaSwapVMRouter on Sepolia (eip712Domain "1inch SwapVM v1.0" / "1.0.2"; AQUA() == AQUA)
    address internal constant ONEINCH_ROUTER = 0x1111113Db0e0ef9D0E3A50d5f094a3a57a26C0DE;
    /// @dev Lido wstETH on Sepolia; stEthPerToken() is the rate WstETHRateProvider reads
    address internal constant WSTETH = 0xB82381A3fBD3FaFA77B3a7bE693342618240067b;
    /// @dev Lido stETH on Sepolia: submit(address referral) payable mints stETH
    address internal constant STETH = 0x3e3FE7dBc6B4C189E7128855dD526361c49b40Af;
    /// @dev WETH9 on Sepolia ("Wrapped Ether"): deposit() payable
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    /// @dev Extruction opcode index on the Sepolia 1inch router. Proven by test/fork/SepoliaRouterExtruction.t.sol
    ///   test_S1 (d8cbbf4): of all 256 opcodes exactly one (32 = 0x20) dispatches Extruction. RateSpaceOrderBuilder
    ///   hard-codes 0x20 (MovingPegExtructionArgs.EXTRUCTION_OPCODE); SepoliaDemoFlow.t.sol asserts they are equal.
    uint8 internal constant EXTRUCTION_OPCODE_SEPOLIA = 0x20;
    /// @dev The same index on 1inch's MAINNET router (test/fork/LiveRouterExtruction.t.sol), kept for comparison
    uint8 internal constant EXTRUCTION_OPCODE_MAINNET = 0x20;
}
