// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Fund1PublicShare} from "./Fund1PublicShare.sol";
import {AssetRegistry} from "./AssetRegistry.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
    /// The account that called `execute`, for the duration of the call - how a hook learns who
    /// is behind a router swap.
    function msgSender() external view returns (address);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

// The v4 permission bits a Fund1Public's address must carry (see script/HookMiner.sol). Same
// bits as Fund1 - the NAV pool works identically until `goPublic()` closes it.
uint160 constant FUND_PUBLIC_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

/// A tokenized single-manager fund whose share token is meant to trade on a public market.
///
/// This is [Fund1](./Fund1.sol) with the changes that a public float makes necessary. Classic
/// Fund1 is unchanged and remains the private-fund path; the two share no code so that listing
/// a fund can never alter the audit surface of one that stayed private.
///
/// Up to `goPublic()` it behaves exactly like Fund1: the owner mints and redeems at book NAV
/// through the v4 hook pool, and trades the book through an allowlisted venue. `goPublic()` is
/// a one-way latch that closes the NAV window for good and freezes share supply. After it, the
/// owner can still manage the book with `trade` but can never issue or retire a share again.
///
/// What changed from Fund1, and why each one:
///
/// 1. **Venue allowlist.** Fund1's `trade` was `venue.call(data)` against any address with
///    code. That is an arbitrary-call primitive owned by the fund, and the fund is its own
///    share token's minter - so `trade(address(share), abi.encodeCall(mint, ...))` minted
///    shares from nothing, and `trade(address(usdg), abi.encodeCall(transfer, ...))` moved USDG
///    out while `nav()` read perfectly flat. Venues are now a fixed pair of routers set at
///    construction, so neither call has anywhere to land.
/// 2. **Coin allowlist.** A venue allowlist alone still permits trading the whole book into a
///    worthless token the owner controls, through a real router, at `minOut = 0`. Every trade
///    now requires `registry.allowed(coin)`. See AssetRegistry for the centralisation this buys.
/// 3. **`maxIn`.** `minOut` bounds only what comes back; what goes out was unbounded, so one
///    call to a bad venue could spend the entire USDG balance and still satisfy `minOut`.
/// 4. **Exit timelock.** Once public, `withdraw`, `withdrawAll` and `burn` require a 72h
///    announcement committing to the exact call. Holders cannot redeem, so their only defence
///    against the fire exit is seeing it coming.
///
/// v4 reads a hook's permissions off its address: deploy via CREATE2 with a salt such that the
/// address's low 14 bits equal `FUND_PUBLIC_FLAGS`.
contract Fund1Public {
    using SafeTransferLib for ERC20;
    using SafeCast for uint256;

    IPermit2 public constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    /// Protocol fee recipient - 0.1% of each `trade` notional (USDG) lands here.
    address public constant FEE_RECIPIENT = 0xa00Ce33896DDfA48F4f925Ac509af961F218c5B0;
    /// 10 bps = 0.1%.
    uint256 public constant FEE_BPS = 10;

    /// How long after an exit announcement the sweep becomes possible.
    uint256 public constant EXIT_DELAY = 72 hours;
    /// And how long it stays possible before the announcement goes stale. Without an expiry an
    /// owner announces once on day one and holds a standing, unannounced right to sweep forever.
    uint256 public constant EXIT_WINDOW = 7 days;

    IPoolManager public immutable poolManager;
    /// Uniswap's Universal Router: the owner's only way onto the fund's own pool.
    IUniversalRouter public immutable router;
    /// The only two contracts `trade` may call. A chain wires v3 and v4 pools to different
    /// routers (Universal Router and SwapRouter02), which is what Fund1's per-call venue
    /// argument was really for - two immutables cover it without leaving an open call.
    /// `venueB` may be the zero address on a chain that needs only one.
    address public immutable venueA;
    address public immutable venueB;
    /// Protocol-curated list of coins this fund may hold. Immutable per fund; the registry's
    /// own contents are not.
    AssetRegistry public immutable registry;
    ERC20 public immutable usdg;
    /// The share token; this contract is its sole minter.
    Fund1PublicShare public immutable share;
    address public immutable owner;
    /// Shares per USDG base unit on the first deposit (100 whole shares per whole USDG).
    uint256 public immutable initRate;
    /// v4 sorts a pool's currencies by address; true if USDG is currency0.
    bool public immutable usdgIsZero;

    /// USDG cost basis per open position, and the total.
    mapping(address => uint256) public cost;
    uint256 public invested;
    /// token => venue the fund has already approved to pull it.
    mapping(address => mapping(address => bool)) public approvedVenue;
    /// Latched by withdrawAll: the fund is dead - no more deposits or trades.
    bool public dead;

    /// One-way: set by `goPublic()`. NAV window closed, supply frozen, exits timelocked.
    bool public isPublic;

    /// keccak256 of the exact pending exit calldata, or zero when none is pending.
    bytes32 public exitHash;
    /// When that announcement was made.
    uint256 public exitAnnouncedAt;

    event WentPublic(uint256 finalSupply, uint256 navUsdg);
    event ExitAnnounced(bytes32 indexed callHash, uint256 executableAt, uint256 expiresAt);
    event ExitCancelled(bytes32 indexed callHash);
    event ExitExecuted(bytes32 indexed callHash);

    modifier onlyOwner() {
        require(msg.sender == owner, "denied");
        _;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "denied");
        _;
    }

    constructor(
        IPoolManager _poolManager,
        IUniversalRouter _router,
        address _venueA,
        address _venueB,
        AssetRegistry _registry,
        ERC20 _usdg,
        address _owner,
        string memory name,
        string memory symbol
    ) {
        require(uint160(address(this)) & Hooks.ALL_HOOK_MASK == FUND_PUBLIC_FLAGS, "setup");
        require(_venueA != address(0), "venue");
        require(address(_registry) != address(0), "registry");
        poolManager = _poolManager;
        router = _router;
        venueA = _venueA;
        venueB = _venueB;
        registry = _registry;
        usdg = _usdg;
        owner = _owner;
        initRate = 100 * 10 ** (18 - _usdg.decimals());
        share = new Fund1PublicShare(name, symbol);
        usdgIsZero = address(_usdg) < address(share);
        // A venue that is the share token, USDG or this fund would hand back the very
        // arbitrary-call primitive the allowlist exists to remove. `share` is deployed above,
        // so this can only be checked here, after it exists.
        require(_isSafeVenue(_venueA), "venue");
        require(_venueB == address(0) || _isSafeVenue(_venueB), "venue");
        // v4 won't create a pool without a starting price; with no liquidity it never matters
        _poolManager.initialize(poolKey(), 1 << 96);
    }

    function _isSafeVenue(address venue) internal view returns (bool) {
        return venue != address(this) && venue != address(share) && venue != address(usdg);
    }

    /// The fund's pool: USDG/share, zero fee, hooked by this contract.
    function poolKey() public view returns (PoolKey memory) {
        (Currency usdgC, Currency shareC) = (Currency.wrap(address(usdg)), Currency.wrap(address(share)));
        return PoolKey({
            currency0: usdgIsZero ? usdgC : shareC,
            currency1: usdgIsZero ? shareC : usdgC,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(this))
        });
    }

    /// Liquid USDG + cost basis of open positions, in USDG base units.
    ///
    /// This is a *book* value, not a mark: it counts what positions cost, never what they are
    /// worth now. That is safe here only because mint and redeem are owner-only before
    /// `goPublic()` and impossible after it. Nothing public ever transacts against this number,
    /// and no UI should present it as the fund's value.
    function nav() public view returns (uint256) {
        return usdg.balanceOf(address(this)) + invested;
    }

    /// Closes the fund to primary issuance, for good.
    ///
    /// After this: the NAV window reverts in both directions, share supply is frozen at its
    /// current level, and the exit sweeps require 72h notice. The owner keeps `trade`, so the
    /// book is still managed; what they lose is the ability to mint shares below true value or
    /// redeem them above it, which with a public float is the owner's most direct route into
    /// holders' money.
    ///
    /// Must be called before any public liquidity is seeded, so that no public buyer is ever
    /// exposed to the open window.
    function goPublic() external onlyOwner {
        require(!isPublic, "public");
        require(!dead, "paused");
        isPublic = true;
        share.freezeSupply();
        emit WentPublic(share.totalSupply(), nav());
    }

    /// v4 hook - the NAV window, owner-only and closed for good by `goPublic()`.
    function beforeSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(!isPublic, "closed");
        require(sender == address(router) && router.msgSender() == owner, "locked");
        require(params.amountSpecified < 0, "amount");
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 amountOut = params.zeroForOne == usdgIsZero ? _deposit(amountIn) : _redeem(amountIn);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(amountIn.toInt128(), -amountOut.toInt128()), 0);
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        require(!dead, "paused");
        uint256 supply = share.totalSupply();
        shares = supply == 0 ? amount * initRate : amount * supply / nav();
        poolManager.take(Currency.wrap(address(usdg)), address(this), amount);
        poolManager.sync(Currency.wrap(address(share)));
        share.mint(address(poolManager), shares);
        poolManager.settle();
    }

    function _redeem(uint256 shares) internal returns (uint256 amount) {
        amount = shares * nav() / share.totalSupply();
        poolManager.take(Currency.wrap(address(share)), address(this), shares);
        share.burn(address(this), shares);
        if (amount > 0) {
            poolManager.sync(Currency.wrap(address(usdg)));
            usdg.safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// Trades USDG <-> `coin` by calling `venue` with `data`, both built off-chain.
    ///
    /// `venue` must be one of the two set at construction, and `coin` must be allowed by the
    /// registry. What the fund believes about the swap still comes from its own balances before
    /// and after, never from the venue.
    ///
    /// `maxIn` bounds the input side - USDG on a buy, `coin` on a sell - so a venue that
    /// misbehaves or gets upgraded cannot take more than the caller intended while still
    /// returning enough to satisfy `minOut`.
    ///
    /// Buys book the USDG spent into `cost[coin]`; sells release it pro-rata to the amount sold.
    function trade(address venue, bytes calldata data, address coin, bool buy, uint256 minOut, uint256 maxIn)
        external
        onlyOwner
        returns (uint256 got)
    {
        require(!dead, "paused");
        // Assets must not move while holders are reading an exit announcement - otherwise the
        // book can be reshuffled into whatever is most convenient to sweep, during the window
        // that exists for holders to react to it.
        require(exitHash == bytes32(0), "exiting");
        require(coin != address(usdg), "token");
        require(venue == venueA || (venueB != address(0) && venue == venueB), "venue");
        require(registry.allowed(coin), "coin");
        _approveVenue(buy ? address(usdg) : coin, venue);

        uint256 usdgBefore = usdg.balanceOf(address(this));
        uint256 coinBefore = ERC20(coin).balanceOf(address(this));
        (bool ok, bytes memory reason) = venue.call(data);
        if (!ok) _bubble(reason);

        uint256 notional;
        if (buy) {
            got = ERC20(coin).balanceOf(address(this)) - coinBefore;
            uint256 spent = usdgBefore - usdg.balanceOf(address(this));
            require(spent <= maxIn, "input");
            cost[coin] += spent;
            invested += spent;
            notional = spent;
        } else {
            // Fund1 divides by `coinBefore` here with no guard, so selling a coin the fund
            // holds none of panics on division by zero instead of saying why.
            require(coinBefore > 0, "empty");
            got = usdg.balanceOf(address(this)) - usdgBefore;
            uint256 sold = coinBefore - ERC20(coin).balanceOf(address(this));
            require(sold <= maxIn, "input");
            uint256 released = cost[coin] * sold / coinBefore;
            cost[coin] -= released;
            invested -= released;
            notional = got;
        }
        require(got >= minOut, "output");

        uint256 fee = notional * FEE_BPS / 10_000;
        if (fee > 0) {
            require(usdg.balanceOf(address(this)) >= fee, "fee");
            usdg.safeTransfer(FEE_RECIPIENT, fee);
        }
    }

    /// Lets `venue` pull `token`, once per pair. The venue is one of two fixed addresses set at
    /// construction, so an infinite allowance here is bounded in a way Fund1's was not.
    function _approveVenue(address token, address venue) internal {
        if (approvedVenue[token][venue]) return;
        approvedVenue[token][venue] = true;
        if (ERC20(token).allowance(address(this), venue) == 0) {
            ERC20(token).safeApprove(venue, type(uint256).max);
        }
        if (ERC20(token).allowance(address(this), address(PERMIT2)) == 0) {
            ERC20(token).safeApprove(address(PERMIT2), type(uint256).max);
        }
        PERMIT2.approve(token, venue, type(uint160).max, type(uint48).max);
    }

    function _bubble(bytes memory reason) internal pure {
        require(reason.length > 0, "venue");
        assembly {
            revert(add(reason, 0x20), mload(reason))
        }
    }

    // ---------------------------------------------------------------------------------------
    // Exit timelock
    //
    // Holders of a public fund have no redemption right; their only exit is selling into the
    // pool. So the one protection available against the owner sweeping the book is advance
    // notice, and notice is only worth anything if it commits to *what* is being swept.
    // ---------------------------------------------------------------------------------------

    /// Announces an intended sweep. `callHash` is `keccak256` of the exact calldata that will
    /// later be sent - selector and all arguments, including the full token list - so an
    /// announcement for one token cannot be redeemed for a `withdrawAll` of everything.
    /// Single-use and self-expiring; `trade` is blocked while one is pending.
    function announceExit(bytes32 callHash) external onlyOwner {
        require(isPublic, "private");
        require(callHash != bytes32(0), "hash");
        require(exitHash == bytes32(0), "pending");
        exitHash = callHash;
        exitAnnouncedAt = block.timestamp;
        emit ExitAnnounced(callHash, block.timestamp + EXIT_DELAY, block.timestamp + EXIT_DELAY + EXIT_WINDOW);
    }

    /// Withdraws the announcement and re-enables trading.
    function cancelExit() external onlyOwner {
        bytes32 previous = exitHash;
        require(previous != bytes32(0), "none");
        exitHash = bytes32(0);
        exitAnnouncedAt = 0;
        emit ExitCancelled(previous);
    }

    /// Checks that this exact call was announced and is now due, then consumes the
    /// announcement. A no-op before `goPublic()`, where the sweeps behave as Fund1's do.
    function _consumeExit() internal {
        if (!isPublic) return;
        require(exitHash == keccak256(msg.data), "announce");
        require(block.timestamp >= exitAnnouncedAt + EXIT_DELAY, "early");
        require(block.timestamp <= exitAnnouncedAt + EXIT_DELAY + EXIT_WINDOW, "expired");
        emit ExitExecuted(exitHash);
        exitHash = bytes32(0);
        exitAnnouncedAt = 0;
    }

    /// Sweeps one token to the owner, erasing its cost from NAV - the fund stays alive.
    function withdraw(address token) external onlyOwner {
        _consumeExit();
        require(token != address(usdg), "token");
        invested -= cost[token];
        delete cost[token];
        ERC20(token).safeTransfer(owner, ERC20(token).balanceOf(address(this)));
    }

    /// Terminal fire exit: latches the fund dead, zeroes the whole cost ledger outright, and
    /// sweeps the listed tokens to the owner. The contract keeps no position list: pass
    /// everything the fund holds, USDG included.
    function withdrawAll(address[] calldata tokens) external onlyOwner {
        _consumeExit();
        dead = true;
        invested = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            delete cost[tokens[i]];
            ERC20(tokens[i]).safeTransfer(owner, ERC20(tokens[i]).balanceOf(address(this)));
        }
    }

    /// Rug disposal: erases the coin's cost from NAV and torches any remaining tokens.
    function burn(address token) external onlyOwner {
        _consumeExit();
        require(token != address(usdg), "token");
        invested -= cost[token];
        delete cost[token];
        token.call(
            abi.encodeWithSignature("transfer(address,uint256)", address(0xdEaD), ERC20(token).balanceOf(address(this)))
        );
    }
}
