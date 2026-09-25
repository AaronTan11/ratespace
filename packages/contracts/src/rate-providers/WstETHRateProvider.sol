// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IRateProvider } from "./IRateProvider.sol";
import { IWstETH } from "./interfaces/IWstETH.sol";

/// @title WstETHRateProvider
/// @notice Reads the wstETH rate live from the wstETH token's `stEthPerToken()`
contract WstETHRateProvider is IRateProvider {
    IWstETH public immutable WSTETH;

    constructor(IWstETH wsteth) {
        WSTETH = wsteth;
    }

    function rate() external view returns (uint256) {
        return WSTETH.stEthPerToken();
    }
}
