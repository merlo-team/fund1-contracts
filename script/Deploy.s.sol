// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Fund1, IUniversalRouter, FUND_FLAGS} from "../src/Fund1.sol";
import {Fund1Share} from "../src/Fund1Share.sol";
import {HookMiner} from "./HookMiner.sol";

/// Deploys a Fund1 for OWNER — which deploys its Fund1Share token and initializes its pool
/// on the PoolManager — in one CREATE2 transaction through forge's deterministic-deployment
/// proxy, at a salt-mined address carrying the fund's v4 hook permission bits. The
/// broadcasting key is just the deployer and holds no rights.
/// Required: OWNER. Optional: FUND_NAME, FUND_SYMBOL, ROUTER, USDG, POOL_MANAGER (default to
/// the canonical Robinhood Chain mainnet addresses).
contract Deploy is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant ROBINHOOD_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant ROBINHOOD_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external returns (Fund1 fund, Fund1Share share) {
        IPoolManager poolManager = IPoolManager(vm.envOr("POOL_MANAGER", ROBINHOOD_POOL_MANAGER));
        IUniversalRouter router = IUniversalRouter(vm.envOr("ROUTER", ROBINHOOD_UNIVERSAL_ROUTER));
        ERC20 usdg = ERC20(vm.envOr("USDG", ROBINHOOD_USDG));
        address owner = vm.envAddress("OWNER");
        string memory name = vm.envOr("FUND_NAME", string("Fund1"));
        string memory symbol = vm.envOr("FUND_SYMBOL", string("FUND1"));

        bytes memory args = abi.encode(poolManager, router, usdg, owner, name, symbol);
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, FUND_FLAGS, type(Fund1).creationCode, args);

        vm.startBroadcast();
        fund = new Fund1{salt: salt}(poolManager, router, usdg, owner, name, symbol);
        vm.stopBroadcast();

        require(address(fund) == predicted, "fund landed off its mined address");
        share = fund.share();
    }
}
