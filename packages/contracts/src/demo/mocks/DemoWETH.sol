// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice DEMO ONLY (local anvil). WETH-like token: deposit()/withdraw() wrap real ETH 1:1, and
///   mint() lets the seed script create unbacked balance. Anyone can mint; minted balance is not
///   ETH-backed, so withdraw() of minted tokens reverts once the contract's ETH runs out.
contract DemoWETH is ERC20 {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    error DemoWETHEthTransferFailed();

    constructor() ERC20("Wrapped Ether", "WETH") { }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{ value: wad }("");
        require(ok, DemoWETHEthTransferFailed());
        emit Withdrawal(msg.sender, wad);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
