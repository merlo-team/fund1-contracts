// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidityLock, INonfungiblePositionManager} from "../src/LiquidityLock.sol";

/// Minimal stand-in for Uniswap's NonfungiblePositionManager: enough ERC721 to hold and move a
/// position, and enough of the liquidity interface to see what the lock asked it to do.
contract MockPositionManager {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint128) public liquidityOf;

    uint256 public lastDecreasedToken;
    uint128 public lastDecreasedLiquidity;
    uint256 public collectCalls;
    address public lastCollectRecipient;

    function mintTo(address to, uint256 tokenId, uint128 liquidity) external {
        ownerOf[tokenId] = to;
        liquidityOf[tokenId] = liquidity;
    }

    /// The transfer an IFO wizard makes to park the position in the lock.
    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
        if (to.code.length > 0) {
            bytes4 ret = MockReceiver(to).onERC721Received(msg.sender, from, tokenId, "");
            require(ret == MockReceiver.onERC721Received.selector, "bad receiver");
        }
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        payable
        returns (uint256, uint256)
    {
        require(ownerOf[params.tokenId] == msg.sender, "not owner");
        collectCalls++;
        lastCollectRecipient = params.recipient;
        return (1e6, 1e18);
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256, uint256)
    {
        require(ownerOf[params.tokenId] == msg.sender, "not owner");
        require(liquidityOf[params.tokenId] >= params.liquidity, "too much");
        liquidityOf[params.tokenId] -= params.liquidity;
        lastDecreasedToken = params.tokenId;
        lastDecreasedLiquidity = params.liquidity;
        return (1e6, 1e18);
    }
}

interface MockReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// An NFT from somewhere else entirely, used to check the lock refuses to accept one.
contract LookalikeNft {
    function pushTo(address to, uint256 tokenId) external returns (bytes4) {
        return MockReceiver(to).onERC721Received(address(this), msg.sender, tokenId, "");
    }
}

contract LiquidityLockTest is Test {
    MockPositionManager npm;
    LiquidityLock lock;

    address bob = makeAddr("bob"); // fund owner / beneficiary
    address mallory = makeAddr("mallory");
    address fundAddress = makeAddr("fund");

    uint256 constant TOKEN_ID = 42;

    function setUp() public {
        npm = new MockPositionManager();
        lock = new LiquidityLock(INonfungiblePositionManager(address(npm)), bob, fundAddress);

        // bob seeds the IFO position, then parks it in the lock - the step that makes the
        // fund's exit timelock mean anything.
        npm.mintTo(bob, TOKEN_ID, 1_000_000);
        vm.prank(bob);
        npm.safeTransferFrom(bob, address(lock), TOKEN_ID);
    }

    function decreaseCalldata(uint256 tokenId, uint128 liquidity, uint256 deadline)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "decreaseLiquidity(uint256,uint128,uint256,uint256,uint256)",
            tokenId,
            liquidity,
            uint256(0),
            uint256(0),
            deadline
        );
    }

    function withdrawCalldata(uint256 tokenId) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("withdrawPosition(uint256)", tokenId);
    }

    function test_LockHoldsThePosition() public view {
        assertEq(npm.ownerOf(TOKEN_ID), address(lock));
        assertEq(lock.beneficiary(), bob);
        assertEq(lock.fund(), fundAddress);
    }

    function test_RejectsNftFromAnotherCollection() public {
        LookalikeNft fake = new LookalikeNft();
        vm.expectRevert("token");
        fake.pushTo(address(lock), 7);
    }

    /// Fees are the return on capital the owner genuinely put up, so they come out with no wait.
    function test_BeneficiaryCollectsFeesWithoutNotice() public {
        vm.prank(bob);
        lock.collect(TOKEN_ID, type(uint128).max, type(uint128).max);
        assertEq(npm.collectCalls(), 1);
        assertEq(npm.lastCollectRecipient(), bob, "fees must go to the beneficiary");
    }

    function test_CollectIsBeneficiaryOnly() public {
        vm.prank(mallory);
        vm.expectRevert("denied");
        lock.collect(TOKEN_ID, type(uint128).max, type(uint128).max);
    }

    /// The whole point: the pool cannot be pulled the moment an exit is announced.
    function test_DecreaseLiquidityRequiresNotice() public {
        vm.prank(bob);
        vm.expectRevert("announce");
        lock.decreaseLiquidity(TOKEN_ID, 1_000_000, 0, 0, block.timestamp + 1);
    }

    function test_DecreaseLiquiditySucceedsAfterNotice() public {
        uint256 deadline = block.timestamp + 30 days;
        vm.prank(bob);
        lock.announceRelease(keccak256(decreaseCalldata(TOKEN_ID, 400_000, deadline)));

        vm.prank(bob);
        vm.expectRevert("early");
        lock.decreaseLiquidity(TOKEN_ID, 400_000, 0, 0, deadline);

        vm.warp(block.timestamp + 72 hours);
        vm.prank(bob);
        lock.decreaseLiquidity(TOKEN_ID, 400_000, 0, 0, deadline);

        assertEq(npm.lastDecreasedLiquidity(), 400_000);
        assertEq(npm.liquidityOf(TOKEN_ID), 600_000);
        assertEq(lock.releaseHash(), bytes32(0), "announcement not consumed");
    }

    /// Announcing a sliver must not authorise draining the lot.
    function test_AnnouncementBindsTheExactAmount() public {
        uint256 deadline = block.timestamp + 30 days;
        vm.prank(bob);
        lock.announceRelease(keccak256(decreaseCalldata(TOKEN_ID, 1, deadline)));
        vm.warp(block.timestamp + 72 hours);

        vm.prank(bob);
        vm.expectRevert("announce");
        lock.decreaseLiquidity(TOKEN_ID, 1_000_000, 0, 0, deadline);

        vm.prank(bob);
        lock.decreaseLiquidity(TOKEN_ID, 1, 0, 0, deadline);
    }

    /// And must not be redeemable for taking the NFT out entirely.
    function test_DecreaseAnnouncementCannotWithdrawPosition() public {
        uint256 deadline = block.timestamp + 30 days;
        vm.prank(bob);
        lock.announceRelease(keccak256(decreaseCalldata(TOKEN_ID, 1_000_000, deadline)));
        vm.warp(block.timestamp + 72 hours);

        vm.prank(bob);
        vm.expectRevert("announce");
        lock.withdrawPosition(TOKEN_ID);
    }

    function test_WithdrawPositionAfterNotice() public {
        vm.prank(bob);
        lock.announceRelease(keccak256(withdrawCalldata(TOKEN_ID)));

        vm.prank(bob);
        vm.expectRevert("early");
        lock.withdrawPosition(TOKEN_ID);

        vm.warp(block.timestamp + 72 hours);
        vm.prank(bob);
        lock.withdrawPosition(TOKEN_ID);
        assertEq(npm.ownerOf(TOKEN_ID), bob);
    }

    function test_AnnouncementExpires() public {
        vm.prank(bob);
        lock.announceRelease(keccak256(withdrawCalldata(TOKEN_ID)));
        vm.warp(block.timestamp + 72 hours + 7 days + 1);

        vm.prank(bob);
        vm.expectRevert("expired");
        lock.withdrawPosition(TOKEN_ID);
    }

    function test_AnnouncementIsSingleUse() public {
        uint256 deadline = block.timestamp + 30 days;
        vm.prank(bob);
        lock.announceRelease(keccak256(decreaseCalldata(TOKEN_ID, 1, deadline)));
        vm.warp(block.timestamp + 72 hours);

        vm.prank(bob);
        lock.decreaseLiquidity(TOKEN_ID, 1, 0, 0, deadline);

        vm.prank(bob);
        vm.expectRevert("announce");
        lock.decreaseLiquidity(TOKEN_ID, 1, 0, 0, deadline);
    }

    function test_OnlyOneAnnouncementAtATime() public {
        vm.startPrank(bob);
        lock.announceRelease(keccak256(withdrawCalldata(TOKEN_ID)));
        vm.expectRevert("pending");
        lock.announceRelease(keccak256(decreaseCalldata(TOKEN_ID, 1, block.timestamp)));
        vm.stopPrank();
    }

    function test_CancelRestoresLockedState() public {
        vm.startPrank(bob);
        lock.announceRelease(keccak256(withdrawCalldata(TOKEN_ID)));
        lock.cancelRelease();
        assertEq(lock.releaseHash(), bytes32(0));
        vm.warp(block.timestamp + 72 hours);
        vm.expectRevert("announce");
        lock.withdrawPosition(TOKEN_ID);
        vm.stopPrank();
    }

    function test_AnnounceAndReleaseAreBeneficiaryOnly() public {
        vm.prank(mallory);
        vm.expectRevert("denied");
        lock.announceRelease(keccak256("x"));

        vm.prank(bob);
        lock.announceRelease(keccak256(withdrawCalldata(TOKEN_ID)));
        vm.warp(block.timestamp + 72 hours);

        vm.prank(mallory);
        vm.expectRevert("denied");
        lock.withdrawPosition(TOKEN_ID);

        vm.prank(mallory);
        vm.expectRevert("denied");
        lock.cancelRelease();
    }

    /// The lock's window must match the fund's, or the weaker of the two is the real promise.
    function test_DelayMatchesFund() public view {
        assertEq(lock.EXIT_DELAY(), 72 hours);
        assertEq(lock.EXIT_WINDOW(), 7 days);
    }
}
