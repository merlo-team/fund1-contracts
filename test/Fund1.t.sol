// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Fund1, IUniversalRouter, FUND_FLAGS} from "../src/Fund1.sol";
import {Fund1Share} from "../src/Fund1Share.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {PoolCaller} from "./PoolCaller.sol";

/// Matches Fund1.FEE_BPS — 10 = 0.1% of trade notional.
function tradeFee(uint256 notional) pure returns (uint256) {
    return notional * 10 / 10_000;
}

contract MockUsdg is ERC20("Global Dollar", "USDG", 6) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockCoin is ERC20("Coin", "COIN", 18) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockPermit2 {
    function approve(address, address, uint160, uint48) external {}
}

/// A venue that always fails, with or without saying why.
contract RevertingVenue {
    bool immutable silent;

    constructor(bool _silent) {
        silent = _silent;
    }

    fallback() external {
        if (silent) revert();
        revert("no liquidity");
    }
}

/// Universal Router stand-in. `execute` mints/burns the fund's USDG and coin balances as armed,
/// simulating trades. `swap` is a v4 exact-input swap the way the real router does one — SETTLE
/// the caller's input, SWAP_EXACT_IN_SINGLE, TAKE_ALL the output to the caller — and
/// `msgSender` names that caller for the fund's hook, as the real router does.
contract MockRouter is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager immutable pm;
    MockUsdg usdg;
    MockCoin coin;
    uint256 takeUsdg;
    uint256 giveUsdg;
    uint256 takeCoin;
    uint256 giveCoin;
    address public msgSender;

    constructor(IPoolManager _pm, MockUsdg _usdg, MockCoin _coin) {
        (pm, usdg, coin) = (_pm, _usdg, _coin);
    }

    function arm(uint256 _takeUsdg, uint256 _giveUsdg, uint256 _takeCoin, uint256 _giveCoin) external {
        (takeUsdg, giveUsdg, takeCoin, giveCoin) = (_takeUsdg, _giveUsdg, _takeCoin, _giveCoin);
    }

    function execute(bytes calldata, bytes[] calldata) external payable {
        if (takeUsdg > 0) usdg.burn(msg.sender, takeUsdg);
        if (giveUsdg > 0) usdg.mint(msg.sender, giveUsdg);
        if (takeCoin > 0) coin.burn(msg.sender, takeCoin);
        if (giveCoin > 0) coin.mint(msg.sender, giveCoin);
    }

    function swap(PoolKey memory key, address tokenIn, uint256 amountIn, uint256 minOut) external returns (uint256) {
        msgSender = msg.sender;
        bytes memory out = pm.unlock(abi.encode(key, tokenIn, amountIn, minOut));
        msgSender = address(0);
        return abi.decode(out, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "denied");
        (PoolKey memory key, address tokenIn, uint256 amountIn, uint256 minOut) =
            abi.decode(data, (PoolKey, address, uint256, uint256));
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        // SETTLE: the caller's input, paid in first
        pm.sync(Currency.wrap(tokenIn));
        ERC20(tokenIn).transferFrom(msgSender, address(pm), amountIn);
        pm.settle();
        // SWAP_EXACT_IN_SINGLE
        BalanceDelta delta = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 amountOut = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
        require(amountOut >= minOut, "too little received");
        // TAKE_ALL
        if (amountOut > 0) pm.take(zeroForOne ? key.currency1 : key.currency0, msgSender, amountOut);
        return abi.encode(amountOut);
    }
}

contract Fund1Test is Test {
    using PoolIdLibrary for PoolKey;

    MockUsdg usdg;
    MockCoin coin;
    MockRouter router;
    PoolManager pm; // the real thing — a mock hid a real bug once
    Fund1 fund;
    Fund1Share share;
    PoolKey key;

    address bob = makeAddr("bob"); // owner — NOT the deployer
    address mallory = makeAddr("mallory");

    function setUp() public {
        usdg = new MockUsdg();
        coin = new MockCoin();
        pm = new PoolManager(address(0));
        router = new MockRouter(IPoolManager(address(pm)), usdg, coin);

        // deployed by the test contract ON BEHALF of bob: fund -> share, the fund at a CREATE2
        // address carrying its v4 hook permission bits
        bytes memory args = abi.encode(address(pm), address(router), address(usdg), bob, "Bob Fund", "BOBF");
        (address predicted, bytes32 salt) = HookMiner.find(address(this), FUND_FLAGS, type(Fund1).creationCode, args);
        fund = new Fund1{salt: salt}(
            IPoolManager(address(pm)), IUniversalRouter(address(router)), ERC20(address(usdg)), bob, "Bob Fund", "BOBF"
        );
        assertEq(address(fund), predicted);
        share = fund.share();
        key = fund.poolKey();
        vm.etch(address(fund.PERMIT2()), address(new MockPermit2()).code);

        // the owner's one-time approvals to the router, as for any token they swap on it
        usdg.mint(bob, 100_000e6);
        vm.startPrank(bob);
        usdg.approve(address(router), type(uint256).max);
        share.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// The venue call `trade` makes. The MockRouter mints and burns whatever it was armed with
    /// and ignores the calldata, so this only has to be a well-formed `execute`.
    function execCall() internal pure returns (bytes memory) {
        return abi.encodeCall(IUniversalRouter.execute, ("", new bytes[](0)));
    }

    /// A deposit: the caller swaps USDG -> share on the fund's pool through the router.
    function deposit(uint256 amount) internal returns (uint256) {
        return router.swap(key, address(usdg), amount, 0);
    }

    /// A redeem: the caller swaps share -> USDG on the fund's pool through the router.
    function redeem(uint256 shares) internal returns (uint256) {
        return router.swap(key, address(share), shares, 0);
    }

    /// The PoolManager wraps a hook's revert: WrappedError(hook, selector, reason, HookCallFailed).
    function hookRevert(bytes4 selector, string memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(fund),
            selector,
            abi.encodeWithSignature("Error(string)", reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function test_DeployerIsNotOwner() public {
        // the test contract deployed the fund but owns nothing
        usdg.mint(address(this), 1e6);
        usdg.approve(address(router), type(uint256).max);
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, "locked"));
        deposit(1e6);
        vm.expectRevert("denied");
        fund.trade(address(router), execCall(), address(coin), true, 1);
        vm.expectRevert("denied");
        fund.withdrawAll(new address[](0));
        vm.expectRevert("denied");
        fund.burn(address(coin));
        vm.expectRevert("denied");
        fund.withdraw(address(coin));
        assertEq(fund.owner(), bob);
    }

    /// Shares are minted and burned in the fund's beforeSwap and nowhere else: the hook only
    /// answers the PoolManager, and only for an exact-input swap the router makes for the
    /// owner; the token only answers the fund.
    function test_MintAndBurnOnlyThroughTheHook() public {
        assertEq(share.minter(), address(fund));
        IPoolManager.SwapParams memory exactIn = IPoolManager.SwapParams(true, -1, 0);
        vm.prank(bob);
        vm.expectRevert("denied");
        fund.beforeSwap(address(router), key, exactIn, "");

        // as the PoolManager: not the router
        vm.prank(address(pm));
        vm.expectRevert("locked");
        fund.beforeSwap(mallory, key, exactIn, "");
        // the router, but not for the owner
        vm.mockCall(address(router), abi.encodeWithSelector(IUniversalRouter.msgSender.selector), abi.encode(mallory));
        vm.prank(address(pm));
        vm.expectRevert("locked");
        fund.beforeSwap(address(router), key, exactIn, "");
        // the router for the owner, but exact-output
        vm.mockCall(address(router), abi.encodeWithSelector(IUniversalRouter.msgSender.selector), abi.encode(bob));
        vm.prank(address(pm));
        vm.expectRevert("amount");
        fund.beforeSwap(address(router), key, IPoolManager.SwapParams(true, 1, 0), "");
        vm.clearMockedCalls();
    }

    /// The pool is the owner's alone. On the real PoolManager, a swap that doesn't come through
    /// the router dies in the hook, and so does a router swap by anyone but the owner.
    function test_PoolRejectsEveryoneElse() public {
        PoolCaller stranger = new PoolCaller(IPoolManager(address(pm)));
        usdg.mint(address(stranger), 1_000e6);
        bool usdgIsZero = fund.usdgIsZero();
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, "locked"));
        stranger.swap(key, usdgIsZero, -int256(1_000e6));

        usdg.mint(mallory, 1_000e6);
        vm.startPrank(mallory);
        usdg.approve(address(router), type(uint256).max);
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, "locked"));
        deposit(1_000e6);
        vm.stopPrank();
    }

    /// Nothing stops anyone adding liquidity to the pool, and nothing happens if they do: the
    /// hook consumes the whole swap, so the curve — and anything in it — is never touched.
    function test_StrayLiquidityIsInert() public {
        vm.prank(bob);
        deposit(10_000e6);
        PoolCaller lp = new PoolCaller(IPoolManager(address(pm)));
        usdg.mint(address(lp), 1_000e6);
        vm.prank(bob);
        share.transfer(address(lp), 1_000e18);
        lp.modifyLiquidity(key, 1e12);
        uint256 pmUsdg = usdg.balanceOf(address(pm));
        uint256 pmShare = share.balanceOf(address(pm));
        assertGt(pmUsdg, 0);
        assertGt(pmShare, 0);

        // the owner's deposit and redeem still price at NAV and leave the LP's tokens alone
        vm.startPrank(bob);
        assertEq(deposit(10_000e6), 1_000_000e18);
        assertEq(redeem(500_000e18), 5_000e6);
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(pm)), pmUsdg);
        assertEq(share.balanceOf(address(pm)), pmShare);

        // and the LP can take it all back
        lp.modifyLiquidity(key, -1e12);
        assertLe(usdg.balanceOf(address(pm)), 1);
        assertLe(share.balanceOf(address(pm)), 1);
    }

    /// The pool exists on the PoolManager as USDG/share with the fund as its hook, with the
    /// starting price v4 demanded, and the fund's address carries exactly the hook bits it uses.
    function test_PoolIsInitializedAndHookedByTheFund() public view {
        assertEq(address(key.hooks), address(fund));
        (address c0, address c1) = fund.usdgIsZero() ? (address(usdg), address(share)) : (address(share), address(usdg));
        assertEq(Currency.unwrap(key.currency0), c0);
        assertEq(Currency.unwrap(key.currency1), c1);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(pm)), key.toId());
        assertEq(sqrtPriceX96, 1 << 96);
        assertEq(uint160(address(fund)) & Hooks.ALL_HOOK_MASK, FUND_FLAGS);
    }

    /// The exact scenario from the spec: $10k -> 1mm shares; half invested; liquid redeem;
    /// positions sold for $95k; remaining shares redeem at the realized price. Each trade
    /// skims 0.1% of USDG notional to FEE_RECIPIENT.
    function test_FundLifecycle() public {
        vm.startPrank(bob);

        uint256 shares = deposit(10_000e6);
        assertEq(shares, 1_000_000e18);
        assertEq(fund.nav(), 10_000e6);
        assertEq(share.balanceOf(bob), 1_000_000e18);
        // flash accounting: the PoolManager holds none of it afterwards
        assertEq(usdg.balanceOf(address(pm)), 0);
        assertEq(share.balanceOf(address(pm)), 0);

        // invest half: router takes 5k USDG, delivers coins; 0.1% fee leaves liquid short of half NAV
        uint256 buySpent = 5_000e6;
        uint256 buyFee = tradeFee(buySpent);
        router.arm(buySpent, 0, 0, 1e18);
        fund.trade(address(router), execCall(), address(coin), true, 1e18);
        assertEq(fund.invested(), buySpent);
        assertEq(fund.nav(), 10_000e6 - buyFee); // positions at cost; fee left the fund
        assertEq(usdg.balanceOf(fund.FEE_RECIPIENT()), buyFee);

        uint256 liquid = buySpent - buyFee;
        uint256 navAfterBuy = 10_000e6 - buyFee;
        // drain liquid via a proportional redeem (slightly under half the supply)
        uint256 redeemShares = liquid * share.totalSupply() / navAfterBuy;
        assertApproxEqAbs(redeem(redeemShares), liquid, 1);
        assertLe(usdg.balanceOf(address(fund)), 1);
        assertEq(usdg.balanceOf(address(pm)), 0);
        assertEq(share.balanceOf(address(pm)), 0);
        assertApproxEqAbs(fund.nav(), buySpent, 1);

        // sell everything for 95k: basis released; 0.1% of proceeds skimmed
        uint256 sellGot = 95_000e6;
        uint256 sellFee = tradeFee(sellGot);
        router.arm(0, sellGot, 1e18, 0);
        fund.trade(address(router), execCall(), address(coin), false, sellGot);
        assertEq(fund.invested(), 0);
        assertApproxEqAbs(fund.nav(), sellGot - sellFee, 1);
        assertEq(usdg.balanceOf(fund.FEE_RECIPIENT()), buyFee + sellFee);

        // remaining shares redeem half the pot (tolerate 1 wei dust from prior redeem)
        uint256 rem = share.balanceOf(bob);
        assertApproxEqAbs(redeem(rem / 2), (sellGot - sellFee) / 2, 1);
        assertEq(share.balanceOf(bob), rem - rem / 2);
        vm.stopPrank();
    }

    function test_TradeSkimsFeeToRecipient() public {
        vm.startPrank(bob);
        deposit(10_000e6);

        router.arm(5_000e6, 0, 0, 1e18);
        fund.trade(address(router), execCall(), address(coin), true, 1);
        assertEq(usdg.balanceOf(fund.FEE_RECIPIENT()), tradeFee(5_000e6));

        router.arm(0, 8_000e6, 1e18, 0);
        fund.trade(address(router), execCall(), address(coin), false, 1);
        assertEq(usdg.balanceOf(fund.FEE_RECIPIENT()), tradeFee(5_000e6) + tradeFee(8_000e6));
        vm.stopPrank();
    }

    function test_DepositAtNavAfterGains() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        router.arm(5_000e6, 0, 0, 1e18);
        fund.trade(address(router), execCall(), address(coin), true, 1);
        router.arm(0, 15_000e6, 1e18, 0); // realize 3x on the 5k
        fund.trade(address(router), execCall(), address(coin), false, 1);
        // nav = 10k - buyFee - 5k + 15k - sellFee = 20k - fees
        uint256 fees = tradeFee(5_000e6) + tradeFee(15_000e6);
        assertEq(fund.nav(), 20_000e6 - fees);

        uint256 supplyBefore = share.totalSupply();
        uint256 minted = deposit(10_000e6);
        assertEq(minted, 10_000e6 * supplyBefore / (20_000e6 - fees));
        vm.stopPrank();
    }

    function test_RedeemRevertsWhenIlliquid() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        router.arm(8_000e6, 0, 0, 1e18);
        fund.trade(address(router), execCall(), address(coin), true, 1);

        // 0.5mm shares are worth 5k but only 2k is liquid — sell positions first
        vm.expectRevert();
        redeem(500_000e18);
        vm.stopPrank();
    }

    function test_MinOutEnforced() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        router.arm(5_000e6, 0, 0, 0.5e18);
        vm.expectRevert("output");
        fund.trade(address(router), execCall(), address(coin), true, 1e18);
        vm.stopPrank();
    }

    /// A venue address holding no code takes a plain call happily and does nothing - the shape
    /// of a pool address that was never deployed. The fund refuses it instead of booking the
    /// no-op as a trade.
    function test_TradeRejectsVenueWithoutCode() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        vm.expectRevert("venue");
        fund.trade(makeAddr("nothing here"), execCall(), address(coin), true, 0);
        assertEq(fund.invested(), 0);
        vm.stopPrank();
    }

    /// Whatever the venue said on the way down is what the owner sees.
    function test_TradeBubblesVenueRevert() public {
        address loud = address(new RevertingVenue(false));
        address silent = address(new RevertingVenue(true));
        vm.startPrank(bob);
        deposit(10_000e6);
        vm.expectRevert("no liquidity");
        fund.trade(loud, execCall(), address(coin), true, 0);
        // and a venue that reverts with nothing still names itself as the culprit
        vm.expectRevert("venue");
        fund.trade(silent, execCall(), address(coin), true, 0);
        vm.stopPrank();
    }

    /// The share token is a plain ERC20 the fund deploys and alone controls: name/symbol come
    /// from the fund's constructor, supply only moves through the swaps.
    function test_ShareTokenIsPlainErc20MintedOnlyByFund() public {
        assertEq(share.minter(), address(fund));
        assertEq(share.name(), "Bob Fund");
        assertEq(share.symbol(), "BOBF");
        assertEq(share.decimals(), 18);
        assertEq(share.totalSupply(), 0);

        // nobody mints or burns directly — not the owner, not the deployer, not a stranger
        vm.prank(bob);
        vm.expectRevert("denied");
        share.mint(bob, 1);
        vm.expectRevert("denied");
        share.mint(address(this), 1);
        vm.prank(mallory);
        vm.expectRevert("denied");
        share.burn(bob, 1);

        vm.prank(bob);
        deposit(10_000e6); // the only way supply appears
        assertEq(share.totalSupply(), 1_000_000e18);
        assertEq(share.balanceOf(bob), 1_000_000e18);
    }

    function test_SharesTradeFreelyButOnlyOwnerRedeems() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        share.transfer(mallory, 400_000e18); // e.g. sold into a pool
        vm.stopPrank();

        vm.startPrank(mallory);
        share.transfer(bob, 100_000e18); // shares are a normal ERC20
        share.approve(address(router), type(uint256).max);
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, "locked"));
        redeem(100_000e18); // but the NAV window is owner-only
        vm.stopPrank();
        assertEq(share.balanceOf(mallory), 300_000e18);
    }

    function test_BurnErasesRuggedPosition() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        router.arm(5_000e6, 0, 0, 1e18);
        fund.trade(address(router), execCall(), address(coin), true, 1);

        // total rug: torch the position; its basis vanishes from NAV
        fund.burn(address(coin));
        assertEq(fund.invested(), 0);
        assertEq(fund.nav(), 5_000e6 - tradeFee(5_000e6));
        assertEq(coin.balanceOf(address(0xdEaD)), 1e18);
        vm.stopPrank();
    }

    function test_BurnErasesRugEvenWithZeroedBalance() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        router.arm(5_000e6, 0, 0, 1e18);
        fund.trade(address(router), execCall(), address(coin), true, 1);
        vm.stopPrank();

        coin.burn(address(fund), 1e18); // the rug zeroes our balance outright

        vm.prank(bob);
        fund.burn(address(coin)); // accounting is still erased, no revert
        assertEq(fund.invested(), 0);
        assertEq(fund.nav(), 5_000e6 - tradeFee(5_000e6));
    }

    function test_LossAutoReleasesCost() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        router.arm(5_000e6, 0, 0, 1e18);
        fund.trade(address(router), execCall(), address(coin), true, 1);

        // close the whole position at a loss: releasing by amount sold zeroes the basis
        router.arm(0, 4_000e6, 1e18, 0);
        fund.trade(address(router), execCall(), address(coin), false, 1);
        assertEq(fund.invested(), 0);
        assertEq(fund.cost(address(coin)), 0);
        // 10k - buyFee - 5k spent + 4k got - sellFee = 9k - fees
        uint256 fees = tradeFee(5_000e6) + tradeFee(4_000e6);
        assertEq(redeem(1_000_000e18), 9_000e6 - fees);
        vm.stopPrank();
    }

    function test_PartialSellReleasesProRata() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        router.arm(5_000e6, 0, 0, 1e18);
        fund.trade(address(router), execCall(), address(coin), true, 1);

        // sell half the position (a winner, 10k proceeds): releases half the 5k cost, not all
        router.arm(0, 10_000e6, 0.5e18, 0);
        fund.trade(address(router), execCall(), address(coin), false, 1);
        assertEq(fund.invested(), 2_500e6);
        // liquid = 5k - buyFee + 10k - sellFee; open half at 2.5k cost
        uint256 fees = tradeFee(5_000e6) + tradeFee(10_000e6);
        assertEq(fund.nav(), 17_500e6 - fees);
        vm.stopPrank();
    }

    function test_TradeAirdroppedCoin() public {
        coin.mint(address(fund), 100e18); // airdropped: held with zero cost basis

        vm.startPrank(bob);
        deposit(10_000e6);
        // selling it books no basis release — the proceeds are pure NAV growth
        router.arm(0, 2_500e6, 100e18, 0);
        uint256 got = fund.trade(address(router), execCall(), address(coin), false, 2_500e6);
        assertEq(got, 2_500e6);
        assertEq(fund.invested(), 0);
        assertEq(fund.nav(), 12_500e6 - tradeFee(2_500e6));
        vm.stopPrank();
    }

    function test_WithdrawSweepsAirdropFundStaysAlive() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        router.arm(5_000e6, 0, 0, 1e18);
        fund.trade(address(router), execCall(), address(coin), true, 1);
        vm.stopPrank();

        MockCoin airdrop = new MockCoin();
        airdrop.mint(address(fund), 777e18);

        vm.startPrank(bob);
        fund.withdraw(address(airdrop)); // no basis: NAV untouched aside from prior trade fee
        assertEq(airdrop.balanceOf(bob), 777e18);
        assertEq(fund.nav(), 10_000e6 - tradeFee(5_000e6));

        fund.withdraw(address(coin)); // retiring a real position erases its basis
        assertEq(coin.balanceOf(bob), 1e18);
        assertEq(fund.invested(), 0);
        assertEq(fund.nav(), 5_000e6 - tradeFee(5_000e6));

        deposit(1_000e6); // still very much alive
        vm.stopPrank();
    }

    function test_WithdrawFireExit() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        router.arm(5_000e6, 0, 0, 1e18);
        fund.trade(address(router), execCall(), address(coin), true, 1);

        // one call evacuates everything the caller lists, USDG included
        address[] memory tokens = new address[](2);
        tokens[0] = address(coin);
        tokens[1] = address(usdg);
        fund.withdrawAll(tokens);
        assertEq(coin.balanceOf(bob), 1e18);
        // 90k never deposited + liquid after buy fee
        assertEq(usdg.balanceOf(bob), 90_000e6 + 5_000e6 - tradeFee(5_000e6));
        assertEq(fund.invested(), 0);
        assertEq(fund.nav(), 0);

        // calling again is fine — the caller just lists nothing
        fund.withdrawAll(new address[](0));

        // terminal: the dead latch blocks deposits (inside the hook) and trades for good
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, "paused"));
        deposit(1_000e6);
        vm.expectRevert(bytes("paused"));
        fund.trade(address(router), execCall(), address(coin), true, 1);
        vm.stopPrank();
    }

    function test_DeadEvenAfterFullRedeem() public {
        vm.startPrank(bob);
        deposit(10_000e6);
        redeem(1_000_000e18); // everything out the accounted way first
        fund.withdrawAll(new address[](0)); // then the kill switch
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, "paused")); // else this would re-arm at initRate
        deposit(10_000e6);
        vm.stopPrank();
    }
}
