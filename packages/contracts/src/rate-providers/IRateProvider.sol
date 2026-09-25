// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IRateProvider
/// @notice Live exchange-rate source for a single token, consumed by MovingPegSwap
/// @dev `rate()` returns the value of one unit of this token scaled by 1e18, expressed in
///   units of a token whose own rate is exactly 1e18. For example, for wstETH a rate of
///   `1.2e18` means one wstETH is worth `1.2` units of the 1e18-rate token.
interface IRateProvider {
    /// @notice Current rate of this token in 1e18-scaled value units
    /// @return rate Rate scaled by 1e18; MUST be non-zero for a usable token
    function rate() external view returns (uint256 rate);
}
