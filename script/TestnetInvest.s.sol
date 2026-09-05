// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Fund1} from "../src/Fund1.sol";
import {TestUSDG} from "./DeployTestnet.s.sol";
import {TestnetBase, TestCoin, PoolSeeder} from "./TestnetBase.s.sol";

/// Against a live testnet fund (FUND): launch a new coin with its own public USDG pool, put half
/// the fund's NAV into it through the router, then redeem half the share supply — which must pay
/// out exactly the liquid half, positions counting at cost. Optional: COIN_NAME, COIN_SYMBOL,
/// COIN_PRICE (USDG base units per whole coin, default 100 USDG; 1e18/price must be a square).
contract TestnetInvest is TestnetBase {
    function run() external {
        uint256 pk = privateKey();
        me = vm.addr(pk);
        fund = Fund1(vm.envAddress("FUND"));
        share = fund.share();
        usdg = TestUSDG(address(fund.usdg()));
        string memory name = vm.envOr("COIN_NAME", string("Other Coin"));
        string memory symbol = vm.envOr("COIN_SYMBOL", string("OTHR"));
        uint256 price = vm.envOr("COIN_PRICE", uint256(100e6));
        require(fund.owner() == me, "PRIVATE_KEY is not the fund's owner");
        vm.startBroadcast(pk);

        // the new coin and a 50,000-USDG-deep public pool for it
        TestCoin coin = new TestCoin(name, symbol);
        coin.mint(me, 1_000_000e18);
        PoolSeeder seeder = new PoolSeeder(IPoolManager(POOL_MANAGER));
        usdg.approve(address(seeder), type(uint256).max);
        coin.approve(address(seeder), type(uint256).max);
        PoolKey memory pool = hookless(address(usdg), address(coin));
        seeder.seed(pool, sqrtPriceUsdgVs(address(coin), price), liquidityFor(50_000e6, price));
        console.log("COIN  ", address(coin), "priced at USDG", price / 1e6);

        // invest half the NAV in it
        uint256 navBefore = fund.nav();
        uint256 half = navBefore / 2;
        (bytes memory cmd, bytes[] memory inputs) = encodeRouterSwap(pool, address(usdg), half);
        uint256 got = fund.trade(ROUTER, routerCall(cmd, inputs), address(coin), true, 1);
        require(fund.invested() == half && fund.nav() == navBefore, "buy accounting");
        console.log("trade: USDG", half / 1e6, "-> COIN", got / 1e18);
        console.log("invested", fund.invested() / 1e6, "nav", fund.nav() / 1e6);

        // redeem half the supply: worth half the NAV, which is exactly what's still liquid
        uint256 toRedeem = share.totalSupply() / 2;
        if (toRedeem > share.balanceOf(me)) toRedeem = share.balanceOf(me);
        uint256 out = swapOnFund(address(share), toRedeem, 0);
        console.log("redeem shares", toRedeem / 1e18, "-> USDG", out / 1e6);
        console.log("liquid left", usdg.balanceOf(address(fund)), "nav", fund.nav() / 1e6);

        vm.stopBroadcast();
    }
}
