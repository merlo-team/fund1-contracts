// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// The fund's share token: a plain 18-decimal ERC20 (with EIP-2612 permit, courtesy of
/// solmate) whose only extra is a single fixed minter - the Fund1 that deploys it.
/// No hooks, no pausing, no blacklists: transfers are free for everyone, and only the
/// fund can create or destroy supply.
contract Fund1Share is ERC20 {
    address public immutable minter;

    modifier onlyMinter() {
        require(msg.sender == minter, "denied");
        _;
    }

    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }
}
