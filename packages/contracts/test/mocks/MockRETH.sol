// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IRETH } from "../../src/rate-providers/interfaces/IRETH.sol";

/// @title MockRETH
/// @notice Test-only rETH with a settable ETH-per-rETH exchange rate
contract MockRETH is IRETH {
    uint256 private _exchangeRate;

    function setExchangeRate(uint256 exchangeRate_) external {
        _exchangeRate = exchangeRate_;
    }

    function getExchangeRate() external view returns (uint256) {
        return _exchangeRate;
    }
}
