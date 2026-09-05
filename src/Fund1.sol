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
import {Fund1Share} from "./Fund1Share.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
    /// The account that called `execute`, for the duration of the call - how a hook learns who
    /// is behind a router swap.
    function msgSender() external view returns (address);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

// The v4 permission bits a Fund1's address must carry (see script/HookMiner.sol).
uint160 constant FUND_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

/// Tokenized single-manager fund - and a Uniswap v4 hook. It deploys `share` (a plain ERC20
/// only it can mint or burn) and initializes a USDG/share pool on the PoolManager hooked by
/// itself. The pool admits exactly one kind of swap: the owner's, sent through Uniswap's
/// Universal Router like any other v4 swap on the chain. `beforeSwap` is the only place shares
/// are ever minted or burned: it prices them at NAV, takes the input the router paid into the
/// PoolManager, pays the output back in for the router to take, and returns a delta consuming
/// the whole input so the (empty) curve swaps nothing. USDG -> share is a deposit, share ->
/// USDG a redeem; there is no deposit or redeem function anywhere.
///
/// The owner (set at deploy; the deployer holds no rights) trades the pot through whatever swap
/// venue `trade` is handed; everyone else gets exposure by trading the share token. NAV is
/// oracle-free: liquid USDG + per-coin cost basis of open positions. `minOut` is the only
/// on-chain price check; venue, routing and policy are app-layer.
///
/// v4 reads a hook's permissions off its address: deploy via CREATE2 with a salt such that the
/// address's low 14 bits equal `FUND_FLAGS`.
contract Fund1 {
    using SafeTransferLib for ERC20;
    using SafeCast for uint256;

    IPermit2 public constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    /// Protocol fee recipient - 0.1% of each `trade` notional (USDG) lands here.
    address public constant FEE_RECIPIENT = 0xa00Ce33896DDfA48F4f925Ac509af961F218c5B0;
    /// 10 bps = 0.1%.
    uint256 public constant FEE_BPS = 10;

    IPoolManager public immutable poolManager;
    /// Uniswap's Universal Router: the owner's only way onto the fund's own pool. `trade` does
    /// not go through here - it calls whatever venue it is given.
    IUniversalRouter public immutable router;
    ERC20 public immutable usdg;
    /// The share token; this contract is its sole minter.
    Fund1Share public immutable share;
    address public immutable owner;
    /// Shares per USDG base unit on the first deposit (100 whole shares per whole USDG).
    uint256 public immutable initRate;
    /// v4 sorts a pool's currencies by address; true if USDG is currency0.
    bool public immutable usdgIsZero;

    /// USDG cost basis per open position, and the total.
    mapping(address => uint256) public cost;
    uint256 public invested;
    /// token => venue the fund has already approved to pull it, so the approvals in `trade`
    /// are a one-time cost per pair rather than per trade.
    mapping(address => mapping(address => bool)) public approvedVenue;
    /// Latched by withdrawAll: the fund is dead - no more deposits or trades.
    bool public dead;

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
        ERC20 _usdg,
        address _owner,
        string memory name,
        string memory symbol
    ) {
        require(uint160(address(this)) & Hooks.ALL_HOOK_MASK == FUND_FLAGS, "setup");
        poolManager = _poolManager;
        router = _router;
        usdg = _usdg;
        owner = _owner;
        initRate = 100 * 10 ** (18 - _usdg.decimals());
        share = new Fund1Share(name, symbol);
        usdgIsZero = address(_usdg) < address(share);
        // v4 won't create a pool without a starting price; with no liquidity it never matters
        _poolManager.initialize(poolKey(), 1 << 96);
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
    function nav() public view returns (uint256) {
        return usdg.balanceOf(address(this)) + invested;
    }

    /// v4 hook - the NAV window. Admits only the owner's swaps, sent through the Universal
    /// Router (which reports who called it); anyone else's revert. USDG -> share is a deposit,
    /// share -> USDG a redeem, exact-input only, and the input must already be paid into the
    /// PoolManager (router actions: SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL). The returned delta
    /// hands the whole input to this contract, so the curve swaps nothing and every delta nets
    /// to zero.
    function beforeSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(sender == address(router) && router.msgSender() == owner, "locked");
        require(params.amountSpecified < 0, "amount");
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 amountOut = params.zeroForOne == usdgIsZero ? _deposit(amountIn) : _redeem(amountIn);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(amountIn.toInt128(), -amountOut.toInt128()), 0);
    }

    /// Mints shares at NAV for the `amount` of USDG the router paid into the PoolManager: take
    /// the USDG, mint the shares straight into the PoolManager for the router to take.
    function _deposit(uint256 amount) internal returns (uint256 shares) {
        require(!dead, "paused");
        uint256 supply = share.totalSupply();
        shares = supply == 0 ? amount * initRate : amount * supply / nav();
        poolManager.take(Currency.wrap(address(usdg)), address(this), amount);
        poolManager.sync(Currency.wrap(address(share)));
        share.mint(address(poolManager), shares);
        poolManager.settle();
    }

    /// Burns the `shares` the router paid into the PoolManager for their NAV slice in liquid
    /// USDG (sell positions first if short), paid back into the PoolManager for the router.
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

    /// Trades USDG <-> `coin` by calling `venue` with `data`, both built off-chain. The venue is
    /// whatever swap contract holds the liquidity - Uniswap's Universal Router for v4 pools, its
    /// SwapRouter02 for v3 pools; the two are separate deployments and a chain may only wire one
    /// of them to the pools that matter, so the choice stays app-layer rather than baked in.
    /// Passing it per call is no extra trust: `trade` is owner-only and the owner can already
    /// empty the fund with `withdrawAll`. What the fund believes about the swap comes from its
    /// own balances before and after, never from the venue.
    ///
    /// Buys book the USDG spent into `cost[coin]`; sells release it pro-rata to the amount sold,
    /// so a full close zeroes it. `minOut` is checked on the coin for buys, on USDG for sells.
    /// Coins are ERC20s only - for ETH exposure hold WETH. The input token self-approves the
    /// venue on first use, both directly and through Permit2 (the Universal Router pulls ERC20s
    /// only through Permit2, SwapRouter02 only through a direct allowance). After the swap, 0.1%
    /// of the USDG notional (`spent` on buys, `got` on sells) is sent to `FEE_RECIPIENT`.
    function trade(address venue, bytes calldata data, address coin, bool buy, uint256 minOut)
        external
        onlyOwner
        returns (uint256 got)
    {
        require(!dead, "paused");
        require(coin != address(usdg), "token");
        // A plain call to an address holding no code succeeds and does nothing, which would book
        // a no-op trade instead of failing. Derived pool addresses that were never deployed are
        // exactly this, so refuse them outright.
        require(venue.code.length > 0, "venue");
        _approveVenue(buy ? address(usdg) : coin, venue);

        uint256 usdgBefore = usdg.balanceOf(address(this));
        uint256 coinBefore = ERC20(coin).balanceOf(address(this));
        (bool ok, bytes memory reason) = venue.call(data);
        if (!ok) _bubble(reason);

        uint256 notional;
        if (buy) {
            got = ERC20(coin).balanceOf(address(this)) - coinBefore;
            uint256 spent = usdgBefore - usdg.balanceOf(address(this));
            cost[coin] += spent;
            invested += spent;
            notional = spent;
        } else {
            got = usdg.balanceOf(address(this)) - usdgBefore;
            uint256 sold = coinBefore - ERC20(coin).balanceOf(address(this));
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

    /// Lets `venue` pull `token`, once per pair: a direct allowance for venues that use
    /// transferFrom, and a Permit2 allowance for those that pull through Permit2. Both are set
    /// because which one a venue uses is its own business, and an unused allowance costs
    /// nothing - the venue is owner-chosen and the owner is already trusted with the pot.
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

    /// Re-reverts the venue's own revert data, so a failed swap says why instead of dying blank.
    /// A venue that reverts with nothing at all - calling a pool address that holds no code, say
    /// - gets a reason of our own rather than an empty bubble nobody can debug.
    function _bubble(bytes memory reason) internal pure {
        require(reason.length > 0, "venue");
        assembly {
            revert(add(reason, 0x20), mload(reason))
        }
    }

    /// Sweeps one token to the owner, erasing its cost from NAV - the fund stays alive.
    /// For airdrops and retired positions; USDG only leaves via redeem or withdrawAll.
    function withdraw(address token) external onlyOwner {
        require(token != address(usdg), "token");
        invested -= cost[token];
        delete cost[token];
        ERC20(token).safeTransfer(owner, ERC20(token).balanceOf(address(this)));
    }

    /// Terminal fire exit: latches the fund dead (no more deposits or trades; deploy a new
    /// one), zeroes the whole cost ledger outright - no subtraction, so a bugged basis can
    /// never block the way out - and sweeps the listed tokens to the owner. The contract
    /// keeps no position list: pass everything the fund holds, USDG included.
    function withdrawAll(address[] calldata tokens) external onlyOwner {
        dead = true;
        invested = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            delete cost[tokens[i]];
            ERC20(tokens[i]).safeTransfer(owner, ERC20(tokens[i]).balanceOf(address(this)));
        }
    }

    /// Rug disposal: erases the coin's cost from NAV and torches any remaining tokens. The
    /// transfer is best-effort so a rug that froze transfers or zeroed our balance still
    /// gets erased from the books.
    function burn(address token) external onlyOwner {
        require(token != address(usdg), "token");
        invested -= cost[token];
        delete cost[token];
        token.call(
            abi.encodeWithSignature("transfer(address,uint256)", address(0xdEaD), ERC20(token).balanceOf(address(this)))
        );
    }
}
