// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Fund1Public, IUniversalRouter, FUND_PUBLIC_FLAGS} from "../src/Fund1Public.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {HookMiner} from "../script/HookMiner.sol";

/// Against the **real deployed AssetRegistry** on Robinhood testnet, not a mock.
///
/// The unit suite already proves the coin allowlist works against a registry the test itself
/// deployed. What that cannot tell us is whether the registry we actually put on chain - with
/// the owner and the 25 seeded assets we passed it - is the one the app will build funds
/// against. This closes that gap: it deploys a Fund1Public pointing at the live address and
/// checks the gate from the fund's own point of view.
contract RegistryLiveForkTest is Test {
    // Deployed 2026-09-22 by the treasury wallet.
    AssetRegistry constant REGISTRY = AssetRegistry(0x37EB0d9E68A174F3A60b0E8093499B0BAA7Deb83);
    address constant TREASURY = 0xa00Ce33896DDfA48F4f925Ac509af961F218c5B0;

    address constant USDG = 0x004A37353Bd51CE8eDa2644E85E6a097ee07FB80;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant SWAP_ROUTER_02 = 0xF3545700dbc70B8b3962FAf08039BdA2664b71C9;

    // Two assets from the seeded list, and one that must never be on it.
    address constant AAPL = 0x231EB41056C9AdB05475cd45D72FcCacACc7dc46;
    address constant WETH = 0x0bb81987d7db05186D3Cb96F6fb6033c3089b853;
    address constant NOT_LISTED = 0x000000000000000000000000000000000000dEaD;

    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork("robinhood_testnet");
    }

    function test_LiveRegistryIsDeployedAndOwned() public view {
        assertGt(address(REGISTRY).code.length, 0, "no code at the registry address");
        assertEq(REGISTRY.owner(), TREASURY, "registry owner is not the treasury");
    }

    function test_LiveRegistryAllowsTheSeededCatalog() public view {
        assertTrue(REGISTRY.allowed(AAPL), "AAPL not allowed");
        assertTrue(REGISTRY.allowed(WETH), "WETH not allowed");
        assertFalse(REGISTRY.allowed(NOT_LISTED), "an unlisted token is allowed");
    }

    /// The whole point: a fund built the way the app builds it is bound to this registry.
    function test_FundDeployedAgainstLiveRegistryIsGatedByIt() public {
        bytes memory args = abi.encode(
            POOL_MANAGER,
            UNIVERSAL_ROUTER,
            SWAP_ROUTER_02,
            UNIVERSAL_ROUTER,
            address(REGISTRY),
            USDG,
            bob,
            "Live",
            "LIVE"
        );
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), FUND_PUBLIC_FLAGS, type(Fund1Public).creationCode, args);

        Fund1Public fund = new Fund1Public{salt: salt}(
            IPoolManager(POOL_MANAGER),
            IUniversalRouter(UNIVERSAL_ROUTER),
            SWAP_ROUTER_02,
            UNIVERSAL_ROUTER,
            REGISTRY,
            ERC20(USDG),
            bob,
            "Live",
            "LIVE"
        );
        assertEq(address(fund), predicted, "fund landed off its mined address");
        assertEq(address(fund.registry()), address(REGISTRY), "fund is not bound to the live registry");

        // A coin the registry does not list is refused before any venue is ever called, so this
        // needs no liquidity to demonstrate.
        vm.prank(bob);
        vm.expectRevert(bytes("coin"));
        fund.trade(SWAP_ROUTER_02, "", NOT_LISTED, true, 0, type(uint256).max);

        // And a listed one gets past the gate. With empty calldata the real SwapRouter02
        // falls through to its `receive()`, which reverts "Not WETH9" - the venue's own error,
        // bubbled up by `trade`. That the failure comes from the venue rather than from the
        // allowlist is precisely the proof wanted here: AAPL cleared the registry check.
        vm.prank(bob);
        vm.expectRevert(bytes("Not WETH9"));
        fund.trade(SWAP_ROUTER_02, "", AAPL, true, 0, type(uint256).max);
    }
}
