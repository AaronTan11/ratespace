// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice DEMO ONLY (local anvil). 18-decimal ERC20 standing in for a yield token (wstETH, rETH, weETH).
///   Anyone can mint.
contract DemoYieldToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
