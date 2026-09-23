// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";

/// Deploys the protocol's `AssetRegistry` — the curated list of coins every public fund is
/// allowed to hold.
///
/// This is deployed once per chain, not once per fund: `Fund1Public` takes its address as an
/// immutable, so every public fund on a chain shares one list. That makes this contract a
/// trusted party for all of them at once, and a malicious entry re-opens the trade-into-my-own-
/// token drain for every fund simultaneously.
///
/// **`REGISTRY_OWNER` should therefore be a multisig with its own timelock, not an EOA.** The
/// script does not enforce that — it cannot tell one address from another — so it is on the
/// operator to check before broadcasting.
///
/// Required: REGISTRY_OWNER. Optional: INITIAL_ASSETS (comma-separated addresses), ALLOW_ALL
/// ("true" to let public funds hold any ERC20 - see the contract's docstring for what that
/// gives up).
contract DeployRegistry is Script {
    function run() external returns (AssetRegistry registry) {
        address owner = vm.envAddress("REGISTRY_OWNER");
        address[] memory initial = vm.envOr("INITIAL_ASSETS", ",", new address[](0));
        bool allowAll = vm.envOr("ALLOW_ALL", false);

        vm.startBroadcast();
        registry = new AssetRegistry(owner, initial, allowAll);
        vm.stopBroadcast();
    }
}
