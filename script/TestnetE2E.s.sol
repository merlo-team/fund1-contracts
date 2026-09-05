// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Fund1, IUniversalRouter, FUND_FLAGS} from "../src/Fund1.sol";
import {HookMiner} from "./HookMiner.sol";
import {TestUSDG} from "./DeployTestnet.s.sol";
import {TestnetBase, TestCoin, PoolSeeder} from "./TestnetBase.s.sol";

/// Testnet (chain id 46630) end-to-end, all from PRIVATE_KEY (the owner): deploy TestUSDG, the
/// fund (-> share, its pool), a coin and a pool seeder; deposit through the real router; seed a
/// USDG/coin pool for the fund to trade against and trade it into and out of the coin through
/// the router; redeem half through the router. Shares never leave the owner: the only liquidity
/// anywhere is the coin pool. Optional: FUND_NAME, FUND_SYMBOL.
contract TestnetE2E is TestnetBase {
    function run() external {
        uint256 pk = privateKey();
        me = vm.addr(pk);
        string memory name = vm.envOr("FUND_NAME", string("Fund1 Test"));
        string memory symbol = vm.envOr("FUND_SYMBOL", string("TFUND1"));
        vm.startBroadcast(pk);

        // deploy: TestUSDG (1mm to me), the fund for me at its mined hook address, a coin, the seeder
        usdg = new TestUSDG();
        usdg.mint(me, 1_000_000e6);
        bytes memory args = abi.encode(POOL_MANAGER, ROUTER, address(usdg), me, name, symbol);
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, FUND_FLAGS, type(Fund1).creationCode, args);
        fund = new Fund1{salt: salt}(
            IPoolManager(POOL_MANAGER), IUniversalRouter(ROUTER), ERC20(address(usdg)), me, name, symbol
        );
        require(address(fund) == predicted, "fund landed off its mined address");
        share = fund.share();
        TestCoin coin = new TestCoin("Test Coin", "TCOIN");
        coin.mint(me, 1_000_000e18);
        PoolSeeder seeder = new PoolSeeder(IPoolManager(POOL_MANAGER));
        console.log("USDG  ", address(usdg));
        console.log("FUND  ", address(fund));
        console.log("SHARE ", address(share));
        console.log("COIN  ", address(coin));

        // owner's approvals: USDG and shares to Permit2 -> router (deposit/redeem, like any swap);
        // USDG and the coin to the seeder
        permit(address(usdg));
        permit(address(share));
        usdg.approve(address(seeder), type(uint256).max);
        coin.approve(address(seeder), type(uint256).max);

        // deposit 10,000 USDG: one router swap on the fund's pool -> 1,000,000 shares
        uint256 shares = swapOnFund(address(usdg), 10_000e6, 1_000_000e18);
        require(shares == 1_000_000e18, "deposit");
        console.log("deposit 10,000 USDG -> shares", shares / 1e18);

        // a public USDG/COIN pool to trade against: 100k USDG + 100k COIN at 1 COIN = 1 USDG
        PoolKey memory coinPool = hookless(address(usdg), address(coin));
        seeder.seed(coinPool, sqrtPriceUsdgVs(address(coin), 1e6), liquidityFor(100_000e6, 1e6));

        // invest 5,000 USDG in COIN through the router, then sell it all back
        (bytes memory cmd, bytes[] memory inputs) = encodeRouterSwap(coinPool, address(usdg), 5_000e6);
        uint256 coinGot = fund.trade(ROUTER, routerCall(cmd, inputs), address(coin), true, 1);
        require(fund.invested() == 5_000e6 && fund.nav() == 10_000e6, "buy accounting");
        console.log("trade: 5,000 USDG -> COIN", coinGot / 1e18, "invested", fund.invested() / 1e6);
        (cmd, inputs) = encodeRouterSwap(coinPool, address(coin), coinGot);
        uint256 usdgBack = fund.trade(ROUTER, routerCall(cmd, inputs), address(coin), false, 1);
        require(fund.invested() == 0, "sell accounting");
        console.log("trade: COIN -> USDG", usdgBack / 1e6, "nav", fund.nav() / 1e6);

        // redeem half of what the deposit minted: a router swap the other way
        uint256 out = swapOnFund(address(share), 500_000e18, 0);
        console.log("redeem 500,000 shares -> USDG", out / 1e6, "nav", fund.nav() / 1e6);

        vm.stopBroadcast();
    }
}
