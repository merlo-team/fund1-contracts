// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// A public fund's share token: [Fund1Share](./Fund1Share.sol) plus a one-way supply freeze.
///
/// Same shape otherwise - a plain 18-decimal ERC20 with EIP-2612 permit and a single fixed
/// minter, the Fund1Public that deploys it. Transfers stay free for everyone; no pausing, no
/// blacklists.
///
/// `freezeSupply` is defence in depth for the dilution problem. `Fund1Public.goPublic()`
/// already makes the NAV window revert, so nothing should reach `mint` or `burn` afterwards -
/// but "should" is doing a lot of work in a contract holding other people's money, and the
/// original audit finding was precisely a call path nobody expected reaching `mint`. Once
/// frozen, supply cannot change no matter what calls in or which path is found later.
contract Fund1PublicShare is ERC20 {
    address public immutable minter;

    /// One-way: set by `freezeSupply`, never cleared.
    bool public frozen;

    event SupplyFrozen(uint256 finalSupply);

    modifier onlyMinter() {
        require(msg.sender == minter, "denied");
        _;
    }

    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        require(!frozen, "frozen");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        require(!frozen, "frozen");
        _burn(from, amount);
    }

    /// Permanently fixes total supply. Callable only by the fund, and only once.
    function freezeSupply() external onlyMinter {
        require(!frozen, "frozen");
        frozen = true;
        emit SupplyFrozen(totalSupply);
    }
}
