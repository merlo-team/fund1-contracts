// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface INonfungiblePositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// Holds a public fund's IFO liquidity position behind the same 72h notice as the fund's own
/// exit sweeps.
///
/// Why this contract exists at all: the fund's exit timelock is worthless without it. The IFO
/// position is an ordinary Uniswap v3 NFT owned by the fund's owner, so an owner who announces
/// a sweep can simply remove all liquidity the same minute - holders get their 72 hours of
/// notice and no market to sell into. A supply freeze plus an asset timelock plus a pullable
/// pool still adds up to a rug.
///
/// So the position lives here instead. Fees stay the beneficiary's and are collectable at any
/// time, because they are the return on capital the owner genuinely put up. Touching the
/// *principal* - decreasing liquidity, or taking the NFT back out - takes the same
/// announce-and-wait as the fund, with the same commitment to the exact call, the same expiry,
/// and the same single use.
contract LiquidityLock {
    /// Matches Fund1Public.EXIT_DELAY - the two windows are meant to be read as one promise.
    uint256 public constant EXIT_DELAY = 72 hours;
    /// Matches Fund1Public.EXIT_WINDOW.
    uint256 public constant EXIT_WINDOW = 7 days;

    INonfungiblePositionManager public immutable positionManager;
    /// Who the locked liquidity belongs to: the fund's owner. Fees go here, and released
    /// positions go here. The server checks this equals the fund's on-chain `owner()` before
    /// listing the fund, so a lock naming somebody else is not a lock at all.
    address public immutable beneficiary;
    /// The fund this lock is securing. Not used for access control - it is here so the pairing
    /// is verifiable on-chain rather than only in our database.
    address public immutable fund;

    /// keccak256 of the exact pending call, or zero when none is pending.
    bytes32 public releaseHash;
    uint256 public releaseAnnouncedAt;

    event PositionReceived(uint256 indexed tokenId, address indexed from);
    event ReleaseAnnounced(bytes32 indexed callHash, uint256 executableAt, uint256 expiresAt);
    event ReleaseCancelled(bytes32 indexed callHash);
    event ReleaseExecuted(bytes32 indexed callHash);

    modifier onlyBeneficiary() {
        require(msg.sender == beneficiary, "denied");
        _;
    }

    constructor(INonfungiblePositionManager _positionManager, address _beneficiary, address _fund) {
        require(address(_positionManager) != address(0), "npm");
        require(_beneficiary != address(0), "beneficiary");
        positionManager = _positionManager;
        beneficiary = _beneficiary;
        fund = _fund;
    }

    /// Accepts the position NFT. Only from the position manager we were told about, so a
    /// lookalike NFT cannot be parked here to make a lock look occupied.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(positionManager), "token");
        emit PositionReceived(tokenId, from);
        return this.onERC721Received.selector;
    }

    /// Fees earned by the locked position, to the beneficiary, at any time and with no notice.
    ///
    /// After a `decreaseLiquidity` has served its notice, the principal it released is also
    /// collectable here - which is correct, because that decrease already waited out the window.
    function collect(uint256 tokenId, uint128 amount0Max, uint128 amount1Max)
        external
        onlyBeneficiary
        returns (uint256 amount0, uint256 amount1)
    {
        return positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: beneficiary, amount0Max: amount0Max, amount1Max: amount1Max
            })
        );
    }

    /// Announces an intended release. `callHash` is `keccak256` of the exact calldata to follow,
    /// so an announcement to pull a sliver of liquidity cannot be redeemed for the whole
    /// position.
    function announceRelease(bytes32 callHash) external onlyBeneficiary {
        require(callHash != bytes32(0), "hash");
        require(releaseHash == bytes32(0), "pending");
        releaseHash = callHash;
        releaseAnnouncedAt = block.timestamp;
        emit ReleaseAnnounced(callHash, block.timestamp + EXIT_DELAY, block.timestamp + EXIT_DELAY + EXIT_WINDOW);
    }

    function cancelRelease() external onlyBeneficiary {
        bytes32 previous = releaseHash;
        require(previous != bytes32(0), "none");
        releaseHash = bytes32(0);
        releaseAnnouncedAt = 0;
        emit ReleaseCancelled(previous);
    }

    function _consumeRelease() internal {
        require(releaseHash == keccak256(msg.data), "announce");
        require(block.timestamp >= releaseAnnouncedAt + EXIT_DELAY, "early");
        require(block.timestamp <= releaseAnnouncedAt + EXIT_DELAY + EXIT_WINDOW, "expired");
        emit ReleaseExecuted(releaseHash);
        releaseHash = bytes32(0);
        releaseAnnouncedAt = 0;
    }

    /// Pulls liquidity out of the position, after notice. The tokens land as "owed" on the
    /// position itself; `collect` moves them to the beneficiary.
    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external onlyBeneficiary returns (uint256 amount0, uint256 amount1) {
        _consumeRelease();
        return positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );
    }

    /// Hands the position NFT back, after notice. This ends the lock's protection for that
    /// position, which is why it costs the same wait as draining it.
    function withdrawPosition(uint256 tokenId) external onlyBeneficiary {
        _consumeRelease();
        positionManager.safeTransferFrom(address(this), beneficiary, tokenId);
    }
}
