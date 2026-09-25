// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IRETH
/// @notice Minimal Rocket Pool rETH interface exposing the ETH-per-rETH exchange rate
interface IRETH {
    /// @notice Amount of ETH value per one rETH, 1e18-scaled
    function getExchangeRate() external view returns (uint256);
}
