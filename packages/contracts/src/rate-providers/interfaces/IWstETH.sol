// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IWstETH
/// @notice Minimal wstETH interface exposing the stETH-per-wstETH exchange rate
interface IWstETH {
    /// @notice Amount of stETH value per one wstETH, 1e18-scaled
    function stEthPerToken() external view returns (uint256);
}
