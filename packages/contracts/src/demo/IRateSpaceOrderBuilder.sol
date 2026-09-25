// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
// SHARED CONTRACT between the demo-contracts lane and the app lane. Do not change signatures.
// Deployed once per chain; the app calls these with eth_call and never encodes order bytes itself.
import { ISwapVM } from "@swap-vm-v1/interfaces/ISwapVM.sol"; // 1inch swap-vm v1.0.2 (the LIVE router's ABI)

interface IRateSpaceOrderBuilder {
    /// @return the 202-byte MovingPegSwap args (identical bytes to MovingPegSwap.build(...) from lib/swap-vm 3b3da7d)
    function buildMovingPegArgs(uint256 x0, uint256 y0, uint256 linearWidth, uint256 refRateLt, uint256 refRateGt, address providerLt, address providerGt, uint16 maxDeviationBps) external pure returns (bytes memory);
    /// @return program bytes for the v1.0.2 router: [FlatFeeAmountIn(feeBps1e9)]? ++ Extruction(target, mpsArgs) ++ Salt(salt). feeBps1e9 == 0 means no fee instruction.
    function buildProgram(address extructionTarget, bytes calldata mpsArgs, uint32 feeBps1e9, uint64 salt) external pure returns (bytes memory);
    /// @return an Aqua-mode order: MakerTraits with useAquaInsteadOfSignature = true, receiver 0, no hooks, no unwrap, allowZeroAmountIn = false
    function buildOrder(address maker, bytes calldata program) external pure returns (ISwapVM.Order memory);
    /// @return taker traits+data for an EOA taker: threshold "", to 0, deadline 0, no hooks/callbacks, isFirstTransferFromTaker false,
    ///         useTransferFromAndAquaPush = pushMode, hasPreTransferInCallback = !pushMode. The app always passes pushMode = true.
    function buildTakerData(address taker, bool isExactIn, bool pushMode) external pure returns (bytes memory);
    /// @return abi.encode(order) — the exact `strategy` bytes to pass to Aqua.ship
    function encodeOrder(ISwapVM.Order calldata order) external pure returns (bytes memory);
    /// @return keccak256(abi.encode(order)) — equals router.hash(order) and the Aqua strategyHash
    function orderHash(ISwapVM.Order calldata order) external pure returns (bytes32);
    /// @return balance * rate / 1e18 (MovingPegSwap.anchorFor)
    function anchorFor(uint256 balance, uint256 rate) external pure returns (uint256);
}
