// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IRateProvider } from "../../src/rate-providers/IRateProvider.sol";

/// @title MockRateProvider
/// @notice Test-only settable rate provider
/// @dev `rate()` can be forced to revert to exercise fail-closed provider handling
contract MockRateProvider is IRateProvider {
    error MockRateProviderForcedRevert();

    uint256 private _rate;
    bool private _shouldRevert;

    function setRate(uint256 rate_) external {
        _rate = rate_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        _shouldRevert = shouldRevert_;
    }

    function rate() external view returns (uint256) {
        if (_shouldRevert) revert MockRateProviderForcedRevert();
        return _rate;
    }
}
