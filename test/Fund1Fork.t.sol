// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Fund1, IUniversalRouter, IPermit2, FUND_FLAGS} from "../src/Fund1.sol";
import {Fund1Share} from "../src/Fund1Share.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {PoolCaller} from "./PoolCaller.sol";

/// End-to-end against the LIVE Universal Router and v4 PoolManager on Robinhood Chain mainnet
/// (needs network): deploy fund -> share, mint shares with real USDG by swapping on the fund's
/// pool through the real router, invest USDG -> WETH through the real 0.01% v3 pool, realize
/// back to USDG, redeem with another router swap. Exercises the router's v4 actions against
/// the hook's flash accounting, Permit2 approvals and the cost-basis accounting for real. The
/// public RPC keeps only a few minutes of state, so keep this quick.
contract Fund1ForkTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    // Universal Router recipient sentinels
    address constant MSG_SENDER = address(1);
    address constant ADDRESS_THIS = address(2);
    // Universal Router command and v4 action ids
    bytes1 constant V4_SWAP = 0x10;
    bytes1 constant SETTLE = 0x0b;
    bytes1 constant SWAP_EXACT_IN_SINGLE = 0x06;
    bytes1 constant TAKE_ALL = 0x0f;

    /// The router's SWAP_EXACT_IN_SINGLE parameters: v4-periphery's IV4Router.ExactInputSingleParams
    /// plus this router revision's per-hop price floor (0 = disabled), as on its v2/v3 inputs.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    uint256[] noHopPrices; // this router revision's extra v2/v3 input field ([] = disabled)
    Fund1 fund;
    Fund1Share share;
    address mallory = makeAddr("mallory");

    function setUp() public {
        vm.createSelectFork("https://rpc.mainnet.chain.robinhood.com");
        // deployer (this test) is NOT the owner-relevant party in prod; here it owns for convenience
        bytes memory args = abi.encode(POOL_MANAGER, ROUTER, USDG, address(this), "Test Fund", "TFUND");
        (, bytes32 salt) = HookMiner.find(address(this), FUND_FLAGS, type(Fund1).creationCode, args);
        fund = new Fund1{salt: salt}(
            IPoolManager(POOL_MANAGER), IUniversalRouter(ROUTER), ERC20(USDG), address(this), "Test Fund", "TFUND"
        );
        share = fund.share();

        // acquire real USDG: swap our own ETH through the live router (wrap + v3 0.01%)
        vm.deal(address(this), 1 ether);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ADDRESS_THIS, 0.02 ether);
        inputs[1] = abi.encode(MSG_SENDER, 0.02 ether, 0, abi.encodePacked(WETH, uint24(100), USDG), false, noHopPrices);
        IUniversalRouter(ROUTER).execute{value: 0.02 ether}(hex"0b00", inputs);

        // the owner's one-time approvals: USDG and shares to Permit2 -> router, as for any token
        permit(USDG);
        permit(address(share));
    }

    function permit(address token) internal {
        ERC20(token).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(token, ROUTER, type(uint160).max, type(uint48).max);
    }

    /// An exact-input swap on the fund's pool as a router transaction: SETTLE the input (paid in
    /// first), SWAP_EXACT_IN_SINGLE, TAKE_ALL the output.
    function encodeSwap(address tokenIn, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs, address tokenOut)
    {
        PoolKey memory key = fund.poolKey();
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenIn, amountIn, true);
        params[1] = abi.encode(ExactInputSingleParams(key, zeroForOne, uint128(amountIn), uint128(minOut), 0, ""));
        params[2] = abi.encode(tokenOut, minOut);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL), params);
        commands = abi.encodePacked(V4_SWAP);
    }

    function swapOnFund(address tokenIn, uint256 amountIn, uint256 minOut) internal returns (uint256 out) {
        (bytes memory commands, bytes[] memory inputs, address tokenOut) = encodeSwap(tokenIn, amountIn, minOut);
        uint256 had = ERC20(tokenOut).balanceOf(address(this));
        IUniversalRouter(ROUTER).execute(commands, inputs);
        out = ERC20(tokenOut).balanceOf(address(this)) - had;
    }

    function test_FundLifecycleThroughLiveRouterAndPool() public {
        // the fund's pool exists on the live PoolManager, with the starting price v4 demanded
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(POOL_MANAGER), fund.poolKey().toId());
        assertEq(sqrtPriceX96, 1 << 96);

        uint256 bag = ERC20(USDG).balanceOf(address(this));
        assertGt(bag, 0);
        uint256 pmUsdg = ERC20(USDG).balanceOf(POOL_MANAGER);

        // deposit: a router swap, USDG -> share, minted at the first-deposit rate (100 shares
        // per USDG, 6 -> 18 decimals), with the router's own minimum-output check on
        uint256 shares = swapOnFund(USDG, bag, bag * fund.initRate());
        assertEq(shares, bag * fund.initRate());
        assertEq(fund.nav(), bag);
        assertEq(share.balanceOf(address(this)), shares);
        // flash accounting: the PoolManager holds nothing it didn't before
        assertEq(ERC20(USDG).balanceOf(POOL_MANAGER), pmUsdg);
        assertEq(share.balanceOf(POOL_MANAGER), 0);

        // invest half: USDG -> WETH, pulled from the fund via Permit2 (self-approved on first
        // use). On mainnet the Universal Router is the venue that reaches the v3 pools.
        bytes memory v3ExactIn = hex"00";
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(MSG_SENDER, bag / 2, 0, abi.encodePacked(USDG, uint24(100), WETH), true, noHopPrices);
        uint256 wethGot =
            fund.trade(ROUTER, abi.encodeCall(IUniversalRouter.execute, (v3ExactIn, inputs)), WETH, true, 1);
        assertGt(wethGot, 0);
        uint256 spent = bag / 2;
        uint256 buyFee = spent * 10 / 10_000;
        assertEq(fund.invested(), spent); // cost basis == USDG spent
        assertEq(fund.nav(), bag - buyFee); // fee left the fund; position at cost

        // redeem shares worth the liquid USDG (half of supply is slightly more after the fee)
        uint256 liquid = spent - buyFee;
        uint256 redeemShares = liquid * shares / (bag - buyFee);
        uint256 out = swapOnFund(address(share), redeemShares, 0);
        assertApproxEqAbs(out, liquid, 1);
        assertEq(share.balanceOf(POOL_MANAGER), 0);

        uint256 feeBeforeSell = ERC20(USDG).balanceOf(fund.FEE_RECIPIENT());

        // realize: WETH -> USDG; proceeds release the cost basis; sell fee skimmed
        inputs[0] = abi.encode(MSG_SENDER, wethGot, 0, abi.encodePacked(WETH, uint24(100), USDG), true, noHopPrices);
        uint256 usdgBack =
            fund.trade(ROUTER, abi.encodeCall(IUniversalRouter.execute, (v3ExactIn, inputs)), WETH, false, 1);
        assertGt(usdgBack, 0);
        assertEq(fund.invested(), 0); // full close releases the full basis, loss or not
        uint256 sellFee = usdgBack * 10 / 10_000;
        assertEq(ERC20(USDG).balanceOf(fund.FEE_RECIPIENT()), feeBeforeSell + sellFee);

        // the remaining shares sweep what's left
        uint256 finalOut = swapOnFund(address(share), share.balanceOf(address(this)), 0);
        assertEq(share.totalSupply(), 0);
        assertGt(finalOut, 0);
        assertEq(ERC20(USDG).balanceOf(POOL_MANAGER), pmUsdg);
    }

    /// The pool is the owner's alone, on the real PoolManager and through the real router: a
    /// stranger's direct swap and a non-owner's router swap both die in the hook.
    function test_PoolIsPrivateOnTheLivePoolManager() public {
        PoolCaller stranger = new PoolCaller(IPoolManager(POOL_MANAGER));
        PoolKey memory key = fund.poolKey();
        bool usdgIsZero = fund.usdgIsZero();
        vm.expectRevert(); // wrapped by the PoolManager as a hook-call failure ("owner via router only")
        stranger.swap(key, usdgIsZero, -int256(1e6));

        // mallory, with real USDG and the same router approvals, gets the same answer
        ERC20(USDG).transfer(mallory, 1e6);
        (bytes memory commands, bytes[] memory inputs,) = encodeSwap(USDG, 1e6, 0);
        vm.startPrank(mallory);
        permit(USDG);
        vm.expectRevert();
        IUniversalRouter(ROUTER).execute(commands, inputs);
        vm.stopPrank();
    }
}
