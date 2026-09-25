// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IWstETH } from "../../src/rate-providers/interfaces/IWstETH.sol";

/// @title MockWstETH
/// @notice Test-only wstETH with a settable stETH-per-wstETH rate
contract MockWstETH is IWstETH {
    uint256 private _stEthPerToken;

    function setStEthPerToken(uint256 stEthPerToken_) external {
        _stEthPerToken = stEthPerToken_;
    }

    function stEthPerToken() external view returns (uint256) {
        return _stEthPerToken;
    }
}
