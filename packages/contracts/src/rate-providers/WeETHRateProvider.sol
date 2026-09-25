// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IRateProvider } from "./IRateProvider.sol";
import { IWeETH } from "./interfaces/IWeETH.sol";

/// @title WeETHRateProvider
/// @notice Reads the weETH rate live from the weETH token's `getRate()`
contract WeETHRateProvider is IRateProvider {
    IWeETH public immutable WEETH;

    constructor(IWeETH weeth) {
        WEETH = weeth;
    }

    function rate() external view returns (uint256) {
        return WEETH.getRate();
    }
}
