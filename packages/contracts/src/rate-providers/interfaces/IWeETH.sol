// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IWeETH
/// @notice Minimal ether.fi weETH interface exposing the ETH-per-weETH exchange rate
interface IWeETH {
    /// @notice Amount of ETH value per one weETH, 1e18-scaled
    function getRate() external view returns (uint256);
}
