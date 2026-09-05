// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Fund1, IUniversalRouter, FUND_FLAGS} from "../src/Fund1.sol";
import {Fund1Share} from "../src/Fund1Share.sol";
import {HookMiner} from "./HookMiner.sol";

/// Mintable stand-in for USDG on testnet (no official testnet USDG exists).
contract TestUSDG is ERC20("Test Global Dollar", "USDG", 6) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Testnet (chain id 46630) deploy: a Fund1 (-> Fund1Share, pool) wired to the real testnet
/// Universal Router and v4 PoolManager — both at their mainnet addresses, verified on-chain.
/// OWNER defaults to the broadcaster.
///
/// USDG defaults to Global Dollar (testnet), the only USDG on this chain with live v3 stock
/// pools, so the fund can actually trade. Pass MINT_USDG=true instead to get a throwaway
/// TestUSDG (1mm minted to the broadcaster) — fine for exercising deposits and the seeded v4
/// pools in the other scripts, useless for buying AAPL and friends.
contract DeployTestnet is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant TESTNET_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant TESTNET_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// Global Dollar (testnet), 6 decimals — has the USDG/AAPL 0.05% pool and the rest.
    address constant GLOBAL_DOLLAR = 0x004A37353Bd51CE8eDa2644E85E6a097ee07FB80;

    function run() external returns (Fund1 fund, Fund1Share share, address usdg) {
        address owner = vm.envOr("OWNER", msg.sender);
        string memory name = vm.envOr("FUND_NAME", string("Fund1 Test"));
        string memory symbol = vm.envOr("FUND_SYMBOL", string("TFUND1"));

        vm.startBroadcast();
        if (vm.envOr("MINT_USDG", false)) {
            TestUSDG minted = new TestUSDG();
            minted.mint(msg.sender, 1_000_000e6);
            usdg = address(minted);
        } else {
            usdg = vm.envOr("USDG", GLOBAL_DOLLAR);
        }

        bytes memory args = abi.encode(TESTNET_POOL_MANAGER, TESTNET_UNIVERSAL_ROUTER, usdg, owner, name, symbol);
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, FUND_FLAGS, type(Fund1).creationCode, args);
        fund = new Fund1{salt: salt}(
            IPoolManager(TESTNET_POOL_MANAGER),
            IUniversalRouter(TESTNET_UNIVERSAL_ROUTER),
            ERC20(usdg),
            owner,
            name,
            symbol
        );
        vm.stopBroadcast();

        require(address(fund) == predicted, "fund landed off its mined address");
        share = fund.share();
    }
}
