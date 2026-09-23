// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// The list of coins a public fund may hold, checked on every trade by Fund1Public.
///
/// Why a list exists at all: a venue allowlist alone still lets a fund owner route the whole
/// book into a worthless token they control, through a perfectly legitimate router, with
/// `minOut = 0`. That is a complete drain executed as an ordinary trade, and no timelock
/// touches it because nothing ever leaves the fund. Constraining *what* can be bought is the
/// only on-chain check that closes it.
///
/// The registry therefore has two modes, and they are a genuine product trade-off rather than
/// a configuration detail:
///
/// - **Curated** (`allowAll == false`): only listed assets. The drain above is impossible, at
///   the cost of the protocol deciding what every public fund may hold - real centralisation,
///   and a single point of compromise, since a malicious entry re-opens the drain for every
///   fund at once.
/// - **Open** (`allowAll == true`): any ERC20. Managers can hold anything, and the drain above
///   is possible again. The fund's other protections still stand - supply is frozen at listing,
///   sweeps need 72 hours' notice, liquidity is locked - but none of them stop a manager
///   trading the book into their own token. Holders are accepting manager risk, and every
///   surface that lets someone buy into a fund must say so.
///
/// Either way, deploy behind a multisig with its own timelock; `owner` is expected to be that
/// multisig, not a person.
contract AssetRegistry {
    address public owner;
    /// Nominated next owner - transfer is two-step so a typo cannot strand the registry.
    address public pendingOwner;

    /// Per-asset entries. Consulted only when `allowAll` is false.
    mapping(address => bool) public listed;

    /// When true, `allowed` answers true for every asset and `listed` is ignored.
    bool public allowAll;

    event AllowedSet(address indexed asset, bool allowed);
    event AllowAllSet(bool allowAll);
    event OwnerNominated(address indexed nominee);
    event OwnerChanged(address indexed previous, address indexed current);

    modifier onlyOwner() {
        require(msg.sender == owner, "denied");
        _;
    }

    constructor(address _owner, address[] memory initialAssets, bool _allowAll) {
        require(_owner != address(0), "owner");
        owner = _owner;
        emit OwnerChanged(address(0), _owner);
        allowAll = _allowAll;
        emit AllowAllSet(_allowAll);
        for (uint256 i = 0; i < initialAssets.length; i++) {
            listed[initialAssets[i]] = true;
            emit AllowedSet(initialAssets[i], true);
        }
    }

    /// What Fund1Public calls on every trade.
    function allowed(address asset) external view returns (bool) {
        return allowAll || listed[asset];
    }

    /// Opens the registry to every asset, or closes it back to the curated list.
    ///
    /// Not one-way in either direction: closing it again is the lever that matters if an open
    /// registry turns out to have been the wrong call, and leaving no way back would make that
    /// decision unrecoverable.
    function setAllowAll(bool value) external onlyOwner {
        allowAll = value;
        emit AllowAllSet(value);
    }

    function setAllowed(address asset, bool isAllowed) external onlyOwner {
        listed[asset] = isAllowed;
        emit AllowedSet(asset, isAllowed);
    }

    function setAllowedBatch(address[] calldata assets, bool isAllowed) external onlyOwner {
        for (uint256 i = 0; i < assets.length; i++) {
            listed[assets[i]] = isAllowed;
            emit AllowedSet(assets[i], isAllowed);
        }
    }

    function nominateOwner(address nominee) external onlyOwner {
        pendingOwner = nominee;
        emit OwnerNominated(nominee);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "denied");
        emit OwnerChanged(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
