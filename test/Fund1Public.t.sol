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
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Fund1Public, IUniversalRouter, FUND_PUBLIC_FLAGS} from "../src/Fund1Public.sol";
import {Fund1PublicShare} from "../src/Fund1PublicShare.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {HookMiner} from "../script/HookMiner.sol";

/// Matches Fund1Public.FEE_BPS — 10 = 0.1% of trade notional.
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

/// Universal Router stand-in, doubling as the allowlisted trade venue. `execute` mints/burns
/// the fund's balances as armed, simulating swaps; `swap` is a v4 exact-input swap done the way
/// the real router does one, and `msgSender` names the caller for the fund's hook.
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

    /// Lets a test arm a swap in a second coin (used for the registry-allowlist tests).
    function armCoin(MockCoin _coin) external {
        coin = _coin;
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
        pm.sync(Currency.wrap(tokenIn));
        ERC20(tokenIn).transferFrom(msgSender, address(pm), amountIn);
        pm.settle();
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
        if (amountOut > 0) pm.take(zeroForOne ? key.currency1 : key.currency0, msgSender, amountOut);
        return abi.encode(amountOut);
    }
}

/// A second allowlisted venue, so the two-venue allowlist is exercised rather than assumed.
contract SecondVenue {
    MockUsdg usdg;
    MockCoin coin;

    constructor(MockUsdg _usdg, MockCoin _coin) {
        (usdg, coin) = (_usdg, _coin);
    }

    function execute(bytes calldata, bytes[] calldata) external payable {
        usdg.burn(msg.sender, 1_000e6);
        coin.mint(msg.sender, 1e18);
    }
}

contract Fund1PublicTest is Test {
    MockUsdg usdg;
    MockCoin coin;
    MockCoin evilCoin; // deployed but never added to the registry
    MockRouter router;
    SecondVenue venueB;
    AssetRegistry registry;
    PoolManager pm; // the real thing — a mock hid a real bug once
    Fund1Public fund;
    Fund1PublicShare share;
    PoolKey key;

    address bob = makeAddr("bob"); // owner — NOT the deployer
    address mallory = makeAddr("mallory");
    address protocol = makeAddr("protocol"); // owns the AssetRegistry

    function setUp() public {
        usdg = new MockUsdg();
        coin = new MockCoin();
        evilCoin = new MockCoin();
        pm = new PoolManager(address(0));
        router = new MockRouter(IPoolManager(address(pm)), usdg, coin);
        venueB = new SecondVenue(usdg, coin);

        address[] memory initial = new address[](1);
        initial[0] = address(coin);
        registry = new AssetRegistry(protocol, initial, false);

        bytes memory args = abi.encode(
            address(pm),
            address(router),
            address(router),
            address(venueB),
            address(registry),
            address(usdg),
            bob,
            "Bob Public",
            "BOBP"
        );
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), FUND_PUBLIC_FLAGS, type(Fund1Public).creationCode, args);
        fund = new Fund1Public{salt: salt}(
            IPoolManager(address(pm)),
            IUniversalRouter(address(router)),
            address(router),
            address(venueB),
            registry,
            ERC20(address(usdg)),
            bob,
            "Bob Public",
            "BOBP"
        );
        assertEq(address(fund), predicted);
        share = fund.share();
        key = fund.poolKey();
        vm.etch(address(fund.PERMIT2()), address(new MockPermit2()).code);

        usdg.mint(bob, 100_000e6);
        vm.startPrank(bob);
        usdg.approve(address(router), type(uint256).max);
        share.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------- helpers

    function execCall() internal pure returns (bytes memory) {
        return abi.encodeCall(IUniversalRouter.execute, ("", new bytes[](0)));
    }

    function deposit(uint256 amount) internal returns (uint256) {
        return router.swap(key, address(usdg), amount, 0);
    }

    function redeem(uint256 shares) internal returns (uint256) {
        return router.swap(key, address(share), shares, 0);
    }

    function hookRevert(bytes4 selector, string memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(fund),
            selector,
            abi.encodeWithSignature("Error(string)", reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// Seeds the fund with a deposit and one open position, the state most tests start from.
    function seedFundedAndInvested() internal {
        vm.prank(bob);
        deposit(10_000e6);
        router.arm(4_000e6, 0, 0, 1e18); // spend 4,000 USDG, receive 1 COIN
        vm.prank(bob);
        fund.trade(address(router), execCall(), address(coin), true, 1, type(uint256).max);
    }

    // ----------------------------------------------------- A1: venue allowlist closes the hole

    function test_A1_TradeRejectsVenueOutsideAllowlist() public {
        seedFundedAndInvested();
        address stranger = address(new SecondVenue(usdg, coin));
        vm.prank(bob);
        vm.expectRevert("venue");
        fund.trade(stranger, execCall(), address(coin), true, 0, type(uint256).max);
    }

    function test_A1_TradeRejectsShareUsdgAndSelfAsVenue() public {
        seedFundedAndInvested();
        vm.startPrank(bob);
        vm.expectRevert("venue");
        fund.trade(address(share), execCall(), address(coin), true, 0, type(uint256).max);
        vm.expectRevert("venue");
        fund.trade(address(usdg), execCall(), address(coin), true, 0, type(uint256).max);
        vm.expectRevert("venue");
        fund.trade(address(fund), execCall(), address(coin), true, 0, type(uint256).max);
        vm.stopPrank();
    }

    /// The first exploit from the audit: mint shares from nothing by having the fund call its
    /// own share token. The fund is the minter, so the only thing that ever stopped this was
    /// which addresses `trade` is willing to call.
    function test_A1_ExploitMintToSelfReverts() public {
        seedFundedAndInvested();
        uint256 supplyBefore = share.totalSupply();
        bytes memory mintCalldata = abi.encodeWithSignature("mint(address,uint256)", bob, 1e30);
        vm.prank(bob);
        vm.expectRevert("venue");
        fund.trade(address(share), mintCalldata, address(coin), true, 0, type(uint256).max);
        assertEq(share.totalSupply(), supplyBefore, "supply moved");
    }

    /// The second exploit: burn a holder's balance outright. `Fund1Share.burn(from, amount)`
    /// checks no allowance, so reaching it at all is the whole attack.
    function test_A1_ExploitBurnVictimReverts() public {
        vm.prank(bob);
        deposit(10_000e6);
        vm.prank(bob);
        share.transfer(mallory, 1_000e18);
        uint256 victimBefore = share.balanceOf(mallory);

        bytes memory burnCalldata = abi.encodeWithSignature("burn(address,uint256)", mallory, victimBefore);
        vm.prank(bob);
        vm.expectRevert("venue");
        fund.trade(address(share), burnCalldata, address(coin), true, 0, type(uint256).max);
        assertEq(share.balanceOf(mallory), victimBefore, "victim balance moved");
    }

    /// The silent drain: `coin != usdg` was checked, `venue != usdg` was not, so USDG left the
    /// fund while `nav()` read perfectly flat.
    function test_A1_SilentUsdgDrainReverts() public {
        seedFundedAndInvested();
        uint256 navBefore = fund.nav();
        bytes memory transferCalldata = abi.encodeWithSignature("transfer(address,uint256)", bob, 5_000e6);
        vm.prank(bob);
        vm.expectRevert("venue");
        fund.trade(address(usdg), transferCalldata, address(coin), true, 0, type(uint256).max);
        assertEq(fund.nav(), navBefore, "nav moved");
    }

    function test_BothAllowlistedVenuesWork() public {
        vm.prank(bob);
        deposit(10_000e6);

        router.arm(4_000e6, 0, 0, 1e18);
        vm.prank(bob);
        fund.trade(address(router), execCall(), address(coin), true, 1, type(uint256).max);

        // venueB spends 1,000 USDG for 1 COIN on its own terms
        vm.prank(bob);
        fund.trade(address(venueB), execCall(), address(coin), true, 1, type(uint256).max);
        assertEq(fund.cost(address(coin)), 5_000e6);
    }

    // ------------------------------------------------- R1: coin allowlist closes the rug-trade

    function test_TradeRejectsCoinNotInRegistry() public {
        seedFundedAndInvested();
        vm.prank(bob);
        vm.expectRevert(bytes("coin"));
        fund.trade(address(router), execCall(), address(evilCoin), true, 0, type(uint256).max);
    }

    function test_RegistryCanAllowAndRevoke() public {
        seedFundedAndInvested();

        vm.prank(protocol);
        registry.setAllowed(address(evilCoin), true);
        router.armCoin(evilCoin);
        router.arm(1_000e6, 0, 0, 1e18);
        vm.prank(bob);
        fund.trade(address(router), execCall(), address(evilCoin), true, 1, type(uint256).max);
        assertEq(fund.cost(address(evilCoin)), 1_000e6);

        vm.prank(protocol);
        registry.setAllowed(address(evilCoin), false);
        vm.prank(bob);
        vm.expectRevert(bytes("coin"));
        fund.trade(address(router), execCall(), address(evilCoin), true, 0, type(uint256).max);
    }

    /// An open registry lets a fund hold anything - including, deliberately, a token nobody
    /// curated. This is the manager-risk mode; the test exists so the switch cannot silently
    /// stop working in either direction.
    function test_AllowAllOpensTradingToAnyToken() public {
        seedFundedAndInvested();

        // Closed by default: an unlisted coin is refused.
        vm.prank(bob);
        vm.expectRevert(bytes("coin"));
        fund.trade(address(router), execCall(), address(evilCoin), true, 0, type(uint256).max);

        vm.prank(protocol);
        registry.setAllowAll(true);
        assertTrue(registry.allowed(address(evilCoin)), "allowAll did not open the registry");

        router.armCoin(evilCoin);
        router.arm(1_000e6, 0, 0, 1e18);
        vm.prank(bob);
        fund.trade(address(router), execCall(), address(evilCoin), true, 1, type(uint256).max);
        assertEq(fund.cost(address(evilCoin)), 1_000e6);

        // And it can be closed again - the way back matters if opening was the wrong call.
        vm.prank(protocol);
        registry.setAllowAll(false);
        vm.prank(bob);
        vm.expectRevert(bytes("coin"));
        fund.trade(address(router), execCall(), address(evilCoin), true, 0, type(uint256).max);
    }

    function test_AllowAllIsOwnerOnly() public {
        vm.prank(mallory);
        vm.expectRevert("denied");
        registry.setAllowAll(true);
    }

    function test_RegistryOnlyOwnerCanSet() public {
        vm.prank(mallory);
        vm.expectRevert("denied");
        registry.setAllowed(address(evilCoin), true);
    }

    // ------------------------------------------------------------------------ maxIn on trade

    function test_BuyRevertsWhenSpentExceedsMaxIn() public {
        vm.prank(bob);
        deposit(10_000e6);
        // The venue takes 9,000 USDG but returns enough coin to satisfy minOut - exactly the
        // shape `minOut` alone cannot catch.
        router.arm(9_000e6, 0, 0, 1e18);
        vm.prank(bob);
        vm.expectRevert("input");
        fund.trade(address(router), execCall(), address(coin), true, 1, 5_000e6);
    }

    function test_BuySucceedsAtMaxIn() public {
        vm.prank(bob);
        deposit(10_000e6);
        router.arm(5_000e6, 0, 0, 1e18);
        vm.prank(bob);
        fund.trade(address(router), execCall(), address(coin), true, 1, 5_000e6);
        assertEq(fund.cost(address(coin)), 5_000e6);
    }

    function test_SellRevertsWhenSoldExceedsMaxIn() public {
        seedFundedAndInvested();
        router.arm(0, 4_000e6, 1e18, 0); // sell the whole 1 COIN
        vm.prank(bob);
        vm.expectRevert("input");
        fund.trade(address(router), execCall(), address(coin), false, 0, 0.5e18);
    }

    /// Fund1 divides by the raw balance with no guard, so this panics instead of explaining.
    function test_SellWithNoPositionRevertsWithReason() public {
        vm.prank(bob);
        deposit(10_000e6);
        router.arm(0, 0, 0, 0);
        vm.prank(bob);
        vm.expectRevert("empty");
        fund.trade(address(router), execCall(), address(coin), false, 0, type(uint256).max);
    }

    // ------------------------------------------------------------ A2: goPublic freezes supply

    function test_GoPublicClosesNavWindowBothDirections() public {
        vm.prank(bob);
        deposit(10_000e6);
        vm.prank(bob);
        fund.goPublic();

        usdg.mint(bob, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, "closed"));
        deposit(1_000e6);

        vm.prank(bob);
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, "closed"));
        redeem(1_000e18);
    }

    /// Defence in depth: even reaching `mint` from the fund itself does nothing after the freeze.
    function test_ShareMintRevertsAfterFreezeEvenFromFund() public {
        vm.prank(bob);
        deposit(10_000e6);
        vm.prank(bob);
        fund.goPublic();

        assertTrue(share.frozen());
        vm.prank(address(fund));
        vm.expectRevert("frozen");
        share.mint(bob, 1e18);
        vm.prank(address(fund));
        vm.expectRevert("frozen");
        share.burn(bob, 1e18);
    }

    function test_ShareFreezeIsMinterOnly() public {
        vm.prank(mallory);
        vm.expectRevert("denied");
        share.freezeSupply();
    }

    function test_GoPublicIsOneWayAndOwnerOnly() public {
        vm.prank(mallory);
        vm.expectRevert("denied");
        fund.goPublic();

        vm.prank(bob);
        fund.goPublic();
        assertTrue(fund.isPublic());

        vm.prank(bob);
        vm.expectRevert("public");
        fund.goPublic();
    }

    /// The dilution attack from the plan's worked simulation, attempted after listing.
    function test_A2_DilutionDepositImpossibleAfterGoPublic() public {
        vm.prank(bob);
        deposit(10_000e6);
        uint256 supplyBefore = share.totalSupply();

        vm.prank(bob);
        fund.goPublic();

        usdg.mint(bob, 10_000e6);
        vm.prank(bob);
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, "closed"));
        deposit(10_000e6);
        assertEq(share.totalSupply(), supplyBefore, "supply diluted");
    }

    /// The owner must keep managing the book after listing — that is the whole product.
    function test_TradeStillWorksAfterGoPublic() public {
        seedFundedAndInvested();
        vm.prank(bob);
        fund.goPublic();

        router.arm(1_000e6, 0, 0, 1e18);
        vm.prank(bob);
        fund.trade(address(router), execCall(), address(coin), true, 1, type(uint256).max);
        assertEq(fund.cost(address(coin)), 5_000e6);
    }

    // ------------------------------------------------------------------- A3: exit timelock

    function withdrawAllCalldata(address[] memory tokens) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("withdrawAll(address[])", tokens);
    }

    function tokenList(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function tokenList(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function test_ExitSweepsAreInstantBeforeGoPublic() public {
        seedFundedAndInvested();
        uint256 before = coin.balanceOf(bob);
        vm.prank(bob);
        fund.withdraw(address(coin)); // no announcement needed while private
        assertEq(coin.balanceOf(bob), before + 1e18);
    }

    function test_WithdrawAllRevertsBeforeTimelockAndSucceedsAfter() public {
        seedFundedAndInvested();
        vm.prank(bob);
        fund.goPublic();

        address[] memory tokens = tokenList(address(usdg), address(coin));
        bytes memory callData = withdrawAllCalldata(tokens);

        vm.prank(bob);
        vm.expectRevert("announce");
        fund.withdrawAll(tokens);

        vm.prank(bob);
        fund.announceExit(keccak256(callData));

        vm.prank(bob);
        vm.expectRevert("early");
        fund.withdrawAll(tokens);

        vm.warp(block.timestamp + 72 hours);
        uint256 coinBefore = coin.balanceOf(bob);
        vm.prank(bob);
        fund.withdrawAll(tokens);
        assertEq(coin.balanceOf(bob), coinBefore + 1e18);
        assertTrue(fund.dead());
        assertEq(fund.exitHash(), bytes32(0), "announcement not consumed");
    }

    /// The commitment is to the exact call. Announcing a single-token sweep must not be
    /// redeemable for a sweep of everything.
    function test_AnnouncementForOneListCannotExecuteAnother() public {
        seedFundedAndInvested();
        vm.prank(bob);
        fund.goPublic();

        address[] memory announced = tokenList(address(coin));
        address[] memory everything = tokenList(address(usdg), address(coin));

        vm.prank(bob);
        fund.announceExit(keccak256(withdrawAllCalldata(announced)));
        vm.warp(block.timestamp + 72 hours);

        vm.prank(bob);
        vm.expectRevert("announce");
        fund.withdrawAll(everything);

        // the announced one still works
        vm.prank(bob);
        fund.withdrawAll(announced);
    }

    /// An announcement for `withdraw(coin)` must not unlock `burn(coin)` — same argument,
    /// different selector, so the hash must differ.
    function test_AnnouncementDoesNotCrossSelectors() public {
        seedFundedAndInvested();
        vm.prank(bob);
        fund.goPublic();

        vm.prank(bob);
        fund.announceExit(keccak256(abi.encodeWithSignature("withdraw(address)", address(coin))));
        vm.warp(block.timestamp + 72 hours);

        vm.prank(bob);
        vm.expectRevert("announce");
        fund.burn(address(coin));

        vm.prank(bob);
        fund.withdraw(address(coin));
    }

    function test_AnnouncementExpiresAfterWindow() public {
        seedFundedAndInvested();
        vm.prank(bob);
        fund.goPublic();

        address[] memory tokens = tokenList(address(coin));
        vm.prank(bob);
        fund.announceExit(keccak256(withdrawAllCalldata(tokens)));

        vm.warp(block.timestamp + 72 hours + 7 days + 1);
        vm.prank(bob);
        vm.expectRevert("expired");
        fund.withdrawAll(tokens);
    }

    function test_TradeBlockedWhileExitPending() public {
        seedFundedAndInvested();
        vm.prank(bob);
        fund.goPublic();

        vm.prank(bob);
        fund.announceExit(keccak256(withdrawAllCalldata(tokenList(address(coin)))));

        router.arm(1_000e6, 0, 0, 1e18);
        vm.prank(bob);
        vm.expectRevert("exiting");
        fund.trade(address(router), execCall(), address(coin), true, 1, type(uint256).max);

        vm.prank(bob);
        fund.cancelExit();
        vm.prank(bob);
        fund.trade(address(router), execCall(), address(coin), true, 1, type(uint256).max);
    }

    function test_OnlyOneAnnouncementAtATime() public {
        seedFundedAndInvested();
        vm.prank(bob);
        fund.goPublic();

        vm.startPrank(bob);
        fund.announceExit(keccak256(withdrawAllCalldata(tokenList(address(coin)))));
        vm.expectRevert("pending");
        fund.announceExit(keccak256(withdrawAllCalldata(tokenList(address(usdg)))));
        vm.stopPrank();
    }

    function test_AnnouncementIsSingleUse() public {
        seedFundedAndInvested();
        vm.prank(bob);
        fund.goPublic();

        bytes memory callData = abi.encodeWithSignature("withdraw(address)", address(coin));
        vm.prank(bob);
        fund.announceExit(keccak256(callData));
        vm.warp(block.timestamp + 72 hours);

        vm.prank(bob);
        fund.withdraw(address(coin));

        vm.prank(bob);
        vm.expectRevert("announce");
        fund.withdraw(address(coin));
    }

    function test_AnnounceAndCancelAreOwnerOnly() public {
        vm.prank(bob);
        fund.goPublic();

        vm.prank(mallory);
        vm.expectRevert("denied");
        fund.announceExit(keccak256("x"));

        vm.prank(bob);
        fund.announceExit(keccak256("x"));

        vm.prank(mallory);
        vm.expectRevert("denied");
        fund.cancelExit();
    }

    function test_CannotAnnounceWhilePrivate() public {
        vm.prank(bob);
        vm.expectRevert("private");
        fund.announceExit(keccak256("x"));
    }

    // ------------------------------------------------- pre-goPublic parity with classic Fund1

    function test_DeployerIsNotOwner() public {
        usdg.mint(address(this), 1e6);
        usdg.approve(address(router), type(uint256).max);
        vm.expectRevert(hookRevert(IHooks.beforeSwap.selector, "locked"));
        deposit(1e6);
        vm.expectRevert("denied");
        fund.trade(address(router), execCall(), address(coin), true, 1, type(uint256).max);
        vm.expectRevert("denied");
        fund.withdrawAll(new address[](0));
        vm.expectRevert("denied");
        fund.burn(address(coin));
        vm.expectRevert("denied");
        fund.withdraw(address(coin));
    }

    function test_FirstDepositMintsAtInitRate() public {
        vm.prank(bob);
        uint256 shares = deposit(10_000e6);
        assertEq(shares, 10_000e6 * fund.initRate());
        assertEq(share.totalSupply(), shares);
        assertEq(fund.nav(), 10_000e6);
    }

    function test_BuyBooksCostBasisAndPaysFee() public {
        vm.prank(bob);
        deposit(10_000e6);
        router.arm(4_000e6, 0, 0, 1e18);
        vm.prank(bob);
        fund.trade(address(router), execCall(), address(coin), true, 1, type(uint256).max);

        assertEq(fund.cost(address(coin)), 4_000e6);
        assertEq(fund.invested(), 4_000e6);
        assertEq(usdg.balanceOf(fund.FEE_RECIPIENT()), tradeFee(4_000e6));
        // nav is unchanged by a buy except for the fee leaving
        assertEq(fund.nav(), 10_000e6 - tradeFee(4_000e6));
    }

    function test_SellReleasesCostProRata() public {
        seedFundedAndInvested();
        router.arm(0, 2_000e6, 0.5e18, 0); // sell half the position for 2,000 USDG
        vm.prank(bob);
        fund.trade(address(router), execCall(), address(coin), false, 1, type(uint256).max);
        assertEq(fund.cost(address(coin)), 2_000e6);
    }

    function test_RedeemPaysNavSlice() public {
        vm.prank(bob);
        uint256 shares = deposit(10_000e6);
        vm.prank(bob);
        uint256 out = redeem(shares / 2);
        assertEq(out, 5_000e6);
    }

    function test_TradeRejectsUsdgAsCoin() public {
        vm.prank(bob);
        deposit(10_000e6);
        vm.prank(bob);
        vm.expectRevert("token");
        fund.trade(address(router), execCall(), address(usdg), true, 0, type(uint256).max);
    }

    function test_MinOutStillEnforced() public {
        vm.prank(bob);
        deposit(10_000e6);
        router.arm(4_000e6, 0, 0, 1e18);
        vm.prank(bob);
        vm.expectRevert("output");
        fund.trade(address(router), execCall(), address(coin), true, 2e18, type(uint256).max);
    }

    function test_DeadFundRefusesTrades() public {
        seedFundedAndInvested();
        vm.prank(bob);
        fund.withdrawAll(tokenList(address(usdg), address(coin)));
        assertTrue(fund.dead());

        router.arm(0, 0, 0, 0);
        vm.prank(bob);
        vm.expectRevert("paused");
        fund.trade(address(router), execCall(), address(coin), true, 0, type(uint256).max);
    }

    function test_ConstructorRejectsUnsafeVenue() public {
        // A fund whose venue is its own USDG would reopen the silent-drain path.
        bytes memory args = abi.encode(
            address(pm), address(router), address(usdg), address(0), address(registry), address(usdg), bob, "Bad", "BAD"
        );
        (, bytes32 salt) = HookMiner.find(address(this), FUND_PUBLIC_FLAGS, type(Fund1Public).creationCode, args);
        vm.expectRevert("venue");
        new Fund1Public{salt: salt}(
            IPoolManager(address(pm)),
            IUniversalRouter(address(router)),
            address(usdg),
            address(0),
            registry,
            ERC20(address(usdg)),
            bob,
            "Bad",
            "BAD"
        );
    }
}
