// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Fund1, IUniversalRouter, IPermit2} from "../src/Fund1.sol";
import {Fund1Share} from "../src/Fund1Share.sol";
import {TestUSDG} from "./DeployTestnet.s.sol";

/// A coin for the fund to trade on testnet.
contract TestCoin is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Initializes a hookless v4 pool and fills it with full-range liquidity paid by the caller
/// (approve both tokens to it first); `pull` gives it back. Testnet plumbing only.
contract PoolSeeder is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager immutable pm;
    address immutable owner;
    int24 constant FULL_RANGE = 887220; // the widest tick that is a multiple of 60

    constructor(IPoolManager _pm) {
        pm = _pm;
        owner = msg.sender;
    }

    function seed(PoolKey memory key, uint160 sqrtPriceX96, int256 liquidity) external {
        require(msg.sender == owner, "not owner");
        pm.initialize(key, sqrtPriceX96);
        pm.unlock(abi.encode(msg.sender, key, liquidity));
    }

    /// Removes `liquidity` and pays both tokens back to the owner.
    function pull(PoolKey memory key, int256 liquidity) external {
        require(msg.sender == owner, "not owner");
        pm.unlock(abi.encode(msg.sender, key, -liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pool manager");
        (address who, PoolKey memory key, int256 liquidity) = abi.decode(data, (address, PoolKey, int256));
        (BalanceDelta delta,) = pm.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -FULL_RANGE, tickUpper: FULL_RANGE, liquidityDelta: liquidity, salt: 0
            }),
            ""
        );
        _close(who, key.currency0, delta.amount0());
        _close(who, key.currency1, delta.amount1());
        return "";
    }

    /// `who` pays what is owed, or receives what is due.
    function _close(address who, Currency currency, int128 amount) internal {
        if (amount < 0) {
            pm.sync(currency);
            ERC20(Currency.unwrap(currency)).transferFrom(who, address(pm), uint256(uint128(-amount)));
            pm.settle();
        } else if (amount > 0) {
            pm.take(currency, who, uint256(uint128(amount)));
        }
    }
}

/// Shared plumbing for the testnet scripts: the chain's addresses, the router's v4 encodings
/// (this revision's minHopPriceX36 included), the owner's swaps on the fund's pool, and pool
/// seeding math. Everything runs from PRIVATE_KEY (.env, with or without 0x), the owner.
abstract contract TestnetBase is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // Universal Router command and v4 action ids
    bytes1 constant V4_SWAP = 0x10;
    bytes1 constant SWAP_EXACT_IN_SINGLE = 0x06;
    bytes1 constant SETTLE = 0x0b;
    bytes1 constant SETTLE_ALL = 0x0c;
    bytes1 constant TAKE_ALL = 0x0f;

    /// The router's SWAP_EXACT_IN_SINGLE params: v4-periphery's plus this router's minHopPriceX36.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    address me;
    TestUSDG usdg;
    Fund1 fund;
    Fund1Share share;

    /// PRIVATE_KEY from the environment (.env), with or without the 0x prefix.
    function privateKey() internal view returns (uint256) {
        string memory raw = vm.envString("PRIVATE_KEY");
        bytes memory b = bytes(raw);
        bool prefixed = b.length > 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X");
        return vm.parseUint(prefixed ? raw : string.concat("0x", raw));
    }

    /// Permit2 approvals for `token` -> router, the owner's one-time setup for swapping it.
    function permit(address token) internal {
        ERC20(token).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(token, ROUTER, type(uint160).max, type(uint48).max);
    }

    function hookless(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
    }

    /// Starting price for a USDG (6 dec) / 18-dec `token` pool where one whole token is worth
    /// `usdgUnits` USDG base units. 1e18 / usdgUnits must be a perfect square (1, 0.01, 100 USDG...).
    function sqrtPriceUsdgVs(address token, uint256 usdgUnits) internal view returns (uint160) {
        uint256 root = priceRoot(usdgUnits);
        return uint160(address(usdg) < token ? root << 96 : (1 << 96) / root);
    }

    /// Full-range liquidity that puts `usdgUnits` of USDG (and the matching amount of the token)
    /// into a pool priced with `sqrtPriceUsdgVs(_, priceUnits)`.
    function liquidityFor(uint256 usdgUnits, uint256 priceUnits) internal pure returns (int256) {
        return int256(usdgUnits * priceRoot(priceUnits));
    }

    function priceRoot(uint256 usdgUnits) internal pure returns (uint256 root) {
        root = isqrt(1e18 / usdgUnits);
        require(root * root * usdgUnits == 1e18, "price: 1e18/usdgUnits must be a perfect square");
    }

    function isqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        r = x;
        while (z < r) {
            r = z;
            z = (x / z + z) / 2;
        }
    }

    /// Wraps router commands as the venue call `Fund1.trade` makes. These scripts trade v4 pools
    /// they seed themselves, which the Universal Router does reach on testnet; the live v3 stock
    /// pools need SwapRouter02 as the venue instead.
    function routerCall(bytes memory commands, bytes[] memory inputs) internal pure returns (bytes memory) {
        return abi.encodeCall(IUniversalRouter.execute, (commands, inputs));
    }

    /// A plain exact-input router swap on a normal pool: swap, SETTLE_ALL the input, TAKE_ALL the output.
    function encodeRouterSwap(PoolKey memory key, address tokenIn, uint256 amountIn)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        address tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, uint128(amountIn), 0, 0, ""));
        params[1] = abi.encode(tokenIn, amountIn);
        params[2] = abi.encode(tokenOut, 0);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);
        commands = abi.encodePacked(V4_SWAP);
    }

    /// The owner's swap on the fund's pool: SETTLE the input first, swap, TAKE_ALL the output.
    function swapOnFund(address tokenIn, uint256 amountIn, uint256 minOut) internal returns (uint256 out) {
        PoolKey memory key = fund.poolKey();
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        address tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenIn, amountIn, true);
        params[1] = abi.encode(ExactInputSingleParams(key, zeroForOne, uint128(amountIn), uint128(minOut), 0, ""));
        params[2] = abi.encode(tokenOut, minOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL), params);
        uint256 had = ERC20(tokenOut).balanceOf(me);
        IUniversalRouter(ROUTER).execute(abi.encodePacked(V4_SWAP), inputs);
        out = ERC20(tokenOut).balanceOf(me) - had;
    }
}
