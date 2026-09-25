// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IRateProvider } from "../../rate-providers/IRateProvider.sol";

/// @notice DEMO ONLY (local anvil). Settable IRateProvider standing in for a live rate source
///   (e.g. Lido's stEthPerToken). Anyone can set the rate; set() simulates an oracle report.
contract DemoRateFeed is IRateProvider {
    event RateSet(uint256 oldRate, uint256 newRate);

    uint256 private _rate;

    constructor(uint256 initialRate) {
        _rate = initialRate;
        emit RateSet(0, initialRate);
    }

    function rate() external view returns (uint256) {
        return _rate;
    }

    function set(uint256 newRate) external {
        emit RateSet(_rate, newRate);
        _rate = newRate;
    }
}
