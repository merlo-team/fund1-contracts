// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidityLock} from "../src/LiquidityLock.sol";

interface IPositions {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128 liquidity,
            uint256,
            uint256,
            uint128,
            uint128
        );
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// The owner-console Exits panel against a **real** deployed LiquidityLock, on a fork.
///
/// The panel never stores what it announced: it rebuilds each call it could have made, hashes
/// it, and executes the one matching the lock's `releaseHash`. That only works if the calldata it
/// builds - a whole percentage of the position's liquidity, zero minimums, a max deadline - is
/// exactly what the lock hashes. This drives that exact shape through the live contract, so a
/// mismatch between the app and the chain shows up here rather than as a stuck withdrawal.
contract LockExitLiveForkTest is Test {
    LiquidityLock constant LOCK = LiquidityLock(0x93f15461dc2959dE96484f4CFD9f3f22E090A3cA);
    IPositions constant NPM = IPositions(0xD1e800aD30B2249977921ce5aFb8d69f773590Ec);
    address constant OWNER = 0xa00Ce33896DDfA48F4f925Ac509af961F218c5B0;
    uint256 constant TOKEN_ID = 99;

    function setUp() public {
        vm.createSelectFork("robinhood_testnet");
    }

    /// Mirrors `lockDecreaseAction` in client/src/lib/exits.ts.
    function decreaseCalldata(uint128 liquidity) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "decreaseLiquidity(uint256,uint128,uint256,uint256,uint256)",
            TOKEN_ID,
            liquidity,
            uint256(0),
            uint256(0),
            type(uint256).max
        );
    }

    function test_PanelShapedPartialReleaseExecutesOnTheLiveLock() public {
        (,,,,,,, uint128 before,,,,) = NPM.positions(TOKEN_ID);
        assertGt(before, 0, "position has no liquidity to test with");
        uint128 quarter = uint128((uint256(before) * 25) / 100);

        vm.prank(OWNER);
        LOCK.announceRelease(keccak256(decreaseCalldata(quarter)));

        // Too early, then a different amount after the notice - both refused.
        vm.prank(OWNER);
        vm.expectRevert(bytes("early"));
        LOCK.decreaseLiquidity(TOKEN_ID, quarter, 0, 0, type(uint256).max);

        vm.warp(block.timestamp + 72 hours);
        vm.prank(OWNER);
        vm.expectRevert(bytes("announce"));
        LOCK.decreaseLiquidity(TOKEN_ID, quarter + 1, 0, 0, type(uint256).max);

        // Exactly what was announced goes through.
        vm.prank(OWNER);
        LOCK.decreaseLiquidity(TOKEN_ID, quarter, 0, 0, type(uint256).max);

        (,,,,,,, uint128 afterwards,,,,) = NPM.positions(TOKEN_ID);
        assertEq(afterwards, before - quarter, "liquidity did not drop by the announced amount");
        assertEq(LOCK.releaseHash(), bytes32(0), "announcement was not consumed");

        // The released principal is now collectable, instantly.
        vm.prank(OWNER);
        (uint256 a0, uint256 a1) = LOCK.collect(TOKEN_ID, type(uint128).max, type(uint128).max);
        assertGt(a0 + a1, 0, "nothing came out after the release");
    }

    function test_PanelShapedFullWithdrawReturnsTheNft() public {
        vm.prank(OWNER);
        LOCK.announceRelease(keccak256(abi.encodeWithSignature("withdrawPosition(uint256)", TOKEN_ID)));
        vm.warp(block.timestamp + 72 hours);
        vm.prank(OWNER);
        LOCK.withdrawPosition(TOKEN_ID);
        assertEq(NPM.ownerOf(TOKEN_ID), OWNER, "position did not come back to the owner");
    }
}
