// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// Finds a CREATE2 salt that puts a hook (here: the fund) at an address whose low 14 bits are
/// `flags` (v4 reads a hook's permissions off its address). `deployer` is whoever executes the CREATE2: the
/// deterministic-deployment proxy for a broadcast forge script, the test contract in tests.
library HookMiner {
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < 300_000; i++) {
            salt = bytes32(i);
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == flags && hook.code.length == 0) return (hook, salt);
        }
        revert("HookMiner: no salt found");
    }
}
