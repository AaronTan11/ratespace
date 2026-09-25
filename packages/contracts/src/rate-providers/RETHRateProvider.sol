// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IRateProvider } from "./IRateProvider.sol";
import { IRETH } from "./interfaces/IRETH.sol";

/// @title RETHRateProvider
/// @notice Reads the rETH rate live from the rETH token's `getExchangeRate()`
contract RETHRateProvider is IRateProvider {
    IRETH public immutable RETH;

    constructor(IRETH reth) {
        RETH = reth;
    }

    function rate() external view returns (uint256) {
        return RETH.getExchangeRate();
    }
}
