// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {Fund1} from "../src/Fund1.sol";
import {TestUSDG} from "./DeployTestnet.s.sol";
import {TestnetBase} from "./TestnetBase.s.sol";

/// Against a live testnet fund (FUND): deposit AMOUNT USDG (default 5,000) through the router,
/// with the router's minimum output set to exactly the NAV-priced share count, so the router
/// itself checks the fund's math. Assumes the owner's Permit2 approvals are already in place.
contract TestnetDeposit is TestnetBase {
    function run() external {
        uint256 pk = privateKey();
        me = vm.addr(pk);
        fund = Fund1(vm.envAddress("FUND"));
        share = fund.share();
        usdg = TestUSDG(address(fund.usdg()));
        uint256 amount = vm.envOr("AMOUNT", uint256(5_000e6));
        require(fund.owner() == me, "PRIVATE_KEY is not the fund's owner");

        uint256 nav = fund.nav();
        uint256 supply = share.totalSupply();
        uint256 expected = supply == 0 ? amount * fund.initRate() : amount * supply / nav;
        console.log("before: nav", nav, "supply", supply);
        console.log("before: USDG per 1,000,000 shares", nav * 1e24 / supply);

        vm.startBroadcast(pk);
        uint256 minted = swapOnFund(address(usdg), amount, expected);
        vm.stopBroadcast();

        require(minted == expected, "minted != NAV price");
        console.log("deposit USDG", amount, "-> shares", minted);
        console.log("after: nav", fund.nav(), "supply", share.totalSupply());
        console.log("after: USDG per 1,000,000 shares", fund.nav() * 1e24 / share.totalSupply());
        console.log("after: liquid USDG", usdg.balanceOf(address(fund)), "invested", fund.invested());
    }
}
