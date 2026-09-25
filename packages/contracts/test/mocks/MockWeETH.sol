// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IWeETH } from "../../src/rate-providers/interfaces/IWeETH.sol";

/// @title MockWeETH
/// @notice Test-only weETH with a settable ETH-per-weETH rate
contract MockWeETH is IWeETH {
    uint256 private _rate;

    function setRate(uint256 rate_) external {
        _rate = rate_;
    }

    function getRate() external view returns (uint256) {
        return _rate;
    }
}
