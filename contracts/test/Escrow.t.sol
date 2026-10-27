// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {PoshEscrow} from "../src/PoshEscrow.sol";
import {RevertingReceiver} from "./mocks/MockUSDC.sol";

contract EscrowTest is BaseTest {
    bytes32 terms = keccak256("terms");
    uint256 constant AMT = 1 ether;

    function _ethDeal() internal returns (uint256 id) {
        vm.prank(buyer);
        id = escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(block.timestamp + 3 days), address(0));
    }

    function _status(uint256 id) internal view returns (uint8 s) {
        (,,,,,,,, s,,) = escrow.getDeal(id);
    }

    // ---------- create ----------
    function test_createEthDeal() public {
        vm.expectEmit(true, true, true, false);
        emit PoshEscrow.DealCreated(1, buyer, seller);
        uint256 id = _ethDeal();
        assertEq(id, 1);
        assertEq(escrow.nextDealId(), 2);
        (
            address b,
            address s,
            address a,
            address t,
            uint256 amt,
            bytes32 th,
            uint64 dl,
            uint64 da,
            uint8 st,
            bool sa,
            bool ba
        ) = escrow.getDeal(id);
        assertEq(b, buyer);
        assertEq(s, seller);
        assertEq(a, arbiter); // default
        assertEq(t, address(0));
        assertEq(amt, AMT);
        assertEq(th, terms);
        assertEq(dl, block.timestamp + 3 days);
        assertEq(da, 0);
        assertEq(st, 1);
        assertFalse(sa);
        assertFalse(ba);
        assertEq(address(escrow).balance, AMT);
    }

    function test_createReverts() public {
        vm.startPrank(buyer);
        uint64 dl = uint64(block.timestamp + 3 days);
        vm.expectRevert(PoshEscrow.InvalidDeadline.selector);
        escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(block.timestamp + 1 hours), address(0));
        vm.expectRevert(PoshEscrow.InvalidDeadline.selector);
        escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(block.timestamp + 721 hours), address(0));
        vm.expectRevert(PoshEscrow.WrongValue.selector);
        escrow.createDeal{value: AMT - 1}(seller, terms, address(0), AMT, dl, address(0));
        vm.expectRevert(PoshEscrow.InvalidSeller.selector);
        escrow.createDeal{value: AMT}(buyer, terms, address(0), AMT, dl, address(0));
        vm.expectRevert(PoshEscrow.InvalidArbiter.selector);
        escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, dl, seller);
        vm.expectRevert(PoshEscrow.TokenNotAllowed.selector);
        escrow.createDeal(seller, terms, address(fmny), AMT, dl, address(0));
        vm.expectRevert(PoshEscrow.InvalidAmount.selector);
        escrow.createDeal(seller, terms, address(0), 0, dl, address(0));
        vm.stopPrank();
    }

    function test_boundaryDeadlinesAccepted() public {
        vm.startPrank(buyer);
        escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(block.timestamp + 2 hours), address(0));
        escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(block.timestamp + 720 hours), address(0));
        vm.stopPrank();
    }

    // ---------- ETH happy path ----------
    function test_ethDeliverRelease() public {
        uint256 id = _ethDeal();
        vm.prank(stranger);
        vm.expectRevert(PoshEscrow.NotSeller.selector);
        escrow.markDelivered(id);
        vm.prank(seller);
        escrow.markDelivered(id);
        assertEq(_status(id), 2);
        uint256 sBefore = seller.balance;
        vm.prank(buyer);
        escrow.release(id);
        assertEq(_status(id), 3);
        assertEq(seller.balance - sBefore, 0.99 ether);
        assertEq(treasury.balance, 0.01 ether);
        (uint256 c,,, uint256 bps,) = passport.getPassport(seller);
        assertEq(c, 1);
        assertEq(bps, 10_000);
        // rewards: 0.01 ETH fee, 25% rebate at 0.00001 ETH/FMNY = 250 FMNY, split 125/125, claimable next epoch
        assertEq(rewards.earned(buyer), 125 ether);
        assertEq(rewards.earned(seller), 125 ether);
        assertEq(rewards.claimable(buyer), 0);
        _nextEpoch();
        assertEq(rewards.claimable(buyer), 125 ether);
    }

    function test_releaseOnlyBuyer_andNoDoubleRelease() public {
        uint256 id = _ethDeal();
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.NotBuyer.selector);
        escrow.release(id);
        vm.prank(buyer);
        escrow.release(id);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.release(id);
    }

    function test_sellerClaimAfterReview() public {
        uint256 id = _ethDeal();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.warp(vm.getBlockTimestamp() + 72 hours - 1);
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.TooEarly.selector);
        escrow.sellerClaim(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(seller);
        escrow.sellerClaim(id);
        assertEq(_status(id), 3);
        assertEq(treasury.balance, 0.01 ether);
    }

    function test_sellerClaimRequiresDelivered() public {
        uint256 id = _ethDeal();
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.sellerClaim(id);
    }

    // ---------- USDC ----------
    function test_usdcDealRelease() public {
        uint256 amt = 1000e6;
        vm.startPrank(buyer);
        usdc.approve(address(escrow), amt);
        uint256 id = escrow.createDeal(seller, terms, address(usdc), amt, uint64(block.timestamp + 1 days), address(0));
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(escrow)), amt);
        assertEq(usdc.allowance(buyer, address(escrow)), 0); // exact approval consumed
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(buyer);
        escrow.release(id);
        assertEq(usdc.balanceOf(seller), 990e6);
        assertEq(usdc.balanceOf(treasury), 10e6);
        // fee 10 USDC at $3000/ETH = 0.003333 ETH -> 25% rebate / 0.00001 ETH = 83.33 FMNY total
        uint256 feeWei = (10e6 * 1e12 * 1e8) / uint256(ETH_USD);
        uint256 total = _expectedTotal(feeWei);
        assertEq(rewards.earned(buyer), total / 2);
        assertEq(rewards.earned(seller), total - total / 2);
        assertApproxEqAbs(total, 83.333 ether, 0.001 ether);
    }

    function test_usdcRejectsEthValue() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1e6);
        vm.expectRevert(PoshEscrow.WrongValue.selector);
        escrow.createDeal{value: 1}(seller, terms, address(usdc), 1e6, uint64(block.timestamp + 1 days), address(0));
        vm.stopPrank();
    }

    function test_usdcRefundAfterDeadline() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 500e6);
        uint256 id =
            escrow.createDeal(seller, terms, address(usdc), 500e6, uint64(block.timestamp + 1 days), address(0));
        vm.stopPrank();
        uint256 before = usdc.balanceOf(buyer);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(buyer);
        escrow.refund(id);
        assertEq(usdc.balanceOf(buyer) - before, 500e6);
        assertEq(_status(id), 4);
    }

    // ---------- refunds ----------
    function test_refundAfterDeadline() public {
        uint256 id = _ethDeal();
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.TooEarly.selector);
        escrow.refund(id);
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        escrow.refund(id);
        assertEq(buyer.balance - before, AMT);
        assertEq(_status(id), 4);
        (,, uint256 r,,) = passport.getPassport(seller);
        assertEq(r, 1);
    }

    function test_noRefundIfDelivered() public {
        uint256 id = _ethDeal();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.refund(id);
    }

    function test_sellerRefund() public {
        uint256 id = _ethDeal();
        uint256 before = buyer.balance;
        vm.prank(seller);
        escrow.sellerRefund(id);
        assertEq(buyer.balance - before, AMT);
        assertEq(_status(id), 4);
        assertEq(treasury.balance, 0);
    }

    // ---------- disputes ----------
    function test_disputeAcceptRuleSeller() public {
        uint256 id = _ethDeal();
        vm.prank(stranger);
        vm.expectRevert(PoshEscrow.NotParty.selector);
        escrow.dispute(id);
        vm.prank(buyer);
        escrow.dispute(id);
        assertEq(_status(id), 5);
        vm.prank(arbiter);
        vm.expectRevert(PoshEscrow.NotAccepted.selector);
        escrow.rule(id, true);
        vm.prank(stranger);
        vm.expectRevert(PoshEscrow.NotArbiter.selector);
        escrow.acceptDeal(id);
        vm.prank(arbiter);
        escrow.acceptDeal(id);
        uint256 before = seller.balance;
        vm.prank(arbiter);
        escrow.rule(id, true);
        assertEq(_status(id), 6);
        assertEq(seller.balance - before, 0.99 ether);
        (, uint256 d,,,) = passport.getPassport(buyer);
        assertEq(d, 1);
    }

    function test_disputeRuleBuyer() public {
        uint256 id = _ethDeal();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(seller);
        escrow.dispute(id);
        vm.prank(arbiter);
        escrow.acceptDeal(id);
        uint256 before = buyer.balance;
        vm.prank(arbiter);
        escrow.rule(id, false);
        assertEq(buyer.balance - before, AMT);
        assertEq(_status(id), 6);
    }

    function test_cannotReleaseWhileDisputed() public {
        uint256 id = _ethDeal();
        vm.prank(buyer);
        escrow.dispute(id);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.release(id);
    }

    function test_settleMutual() public {
        uint256 id = _ethDeal();
        vm.prank(buyer);
        escrow.dispute(id);
        vm.prank(buyer);
        escrow.settle(id, true);
        (,,,,,,,,, bool sa, bool ba) = escrow.getDeal(id);
        assertTrue(ba);
        assertFalse(sa);
        assertEq(_status(id), 5);
        // seller disagrees first -> nothing happens
        vm.prank(seller);
        escrow.settle(id, false);
        assertEq(_status(id), 5);
        // seller matches -> executes
        uint256 before = seller.balance;
        vm.prank(seller);
        escrow.settle(id, true);
        assertEq(_status(id), 6);
        assertEq(seller.balance - before, 0.99 ether);
        assertEq(rewards.earned(seller), 0); // no rewards on disputed/settled deals
    }

    function test_settleToBuyerWithoutDispute() public {
        uint256 id = _ethDeal();
        vm.prank(seller);
        escrow.settle(id, false);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        escrow.settle(id, false);
        assertEq(buyer.balance - before, AMT);
        assertEq(_status(id), 4);
        vm.prank(stranger);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.settle(id, false);
    }

    // ---------- handoff ----------
    bytes32 item = keccak256("watch-serial-123");

    function _handoff() internal returns (uint256 id) {
        _file(seller, item, "Rolex serial 123");
        vm.prank(buyer);
        id = escrow.createHandoff{value: 2 ether}(seller, terms, item, 4 hours);
    }

    function test_handoffReleaseTransfersFiling() public {
        uint256 id = _handoff();
        (bool isH, bytes32 ih,,,,,) = escrow.getDealExtra(id);
        assertTrue(isH);
        assertEq(ih, item);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.ItemMismatch.selector);
        escrow.releaseHandoff(id, keccak256("wrong"));
        uint256 s0 = seller.balance;
        vm.prank(buyer);
        escrow.releaseHandoff(id, item);
        (address o,,,) = vault.recordOf(item);
        assertEq(o, buyer);
        assertEq(seller.balance - s0, 1.98 ether);
        assertEq(treasury.balance, 0.02 ether);
        assertEq(_status(id), 3);
        assertGt(rewards.earned(buyer), 0);
    }

    function test_handoffRequiresSellerFiling() public {
        _file(stranger, item, "x");
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.ItemNotOwnedBySeller.selector);
        escrow.createHandoff{value: 1 ether}(seller, terms, item, 4 hours);
    }

    function test_handoffWindowBounds() public {
        _file(seller, item, "x");
        vm.startPrank(buyer);
        vm.expectRevert(PoshEscrow.InvalidWindow.selector);
        escrow.createHandoff{value: 1 ether}(seller, terms, item, 1 hours);
        vm.expectRevert(PoshEscrow.InvalidWindow.selector);
        escrow.createHandoff{value: 1 ether}(seller, terms, item, 25 hours);
        vm.stopPrank();
    }

    function test_handoffRefundAfterWindow() public {
        uint256 id = _handoff();
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.TooEarly.selector);
        escrow.refund(id);
        vm.warp(vm.getBlockTimestamp() + 4 hours + 1);
        uint256 b0 = buyer.balance;
        vm.prank(buyer);
        escrow.refund(id);
        assertEq(buyer.balance - b0, 2 ether);
        (address o,,,) = vault.recordOf(item);
        assertEq(o, seller);
    }

    function test_handoffFailsIfSellerMovedFiling() public {
        uint256 id = _handoff();
        vm.prank(seller);
        vault.transfer(item, stranger);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.ItemNotOwnedBySeller.selector);
        escrow.releaseHandoff(id, item);
    }

    function test_handoffCannotUseNormalRelease() public {
        uint256 id = _handoff();
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.IsHandoff.selector);
        escrow.release(id);
    }

    // ---------- fees / admin ----------
    function test_feeSettable_andCapped_andSnapshotted() public {
        uint256 id = _ethDeal(); // created at 100 bps
        vm.prank(owner);
        escrow.setFeeBps(500);
        vm.prank(owner);
        vm.expectRevert(PoshEscrow.FeeTooHigh.selector);
        escrow.setFeeBps(501);
        vm.prank(stranger);
        vm.expectRevert();
        escrow.setFeeBps(0);
        vm.prank(buyer);
        escrow.release(id);
        assertEq(treasury.balance, 0.01 ether); // snapshot 1%
        uint256 id2 = _ethDeal();
        vm.prank(buyer);
        escrow.release(id2);
        assertEq(treasury.balance, 0.06 ether); // +5%
    }

    function test_revertingSellerFallsBackToPull() public {
        RevertingReceiver bad = new RevertingReceiver();
        vm.prank(buyer);
        uint256 id = escrow.createDeal{value: AMT}(
            address(bad), terms, address(0), AMT, uint64(block.timestamp + 3 days), address(0)
        );
        vm.prank(buyer);
        escrow.release(id);
        assertEq(escrow.pendingWithdrawals(address(0), address(bad)), 0.99 ether);
        assertEq(_status(id), 3);
    }

    function test_rewardsPausedDoesNotBlockRelease() public {
        vm.prank(owner);
        rewards.setPaused(true);
        uint256 id = _ethDeal();
        vm.prank(buyer);
        escrow.release(id);
        assertEq(_status(id), 3);
        assertEq(rewards.claimable(buyer), 0);
    }
}
