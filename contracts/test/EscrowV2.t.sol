// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {PoshEscrow} from "../src/PoshEscrow.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {WeirdToken, GasBurner, Mock1271Wallet, RevertingReceiver} from "./mocks/MockUSDC.sol";

/// @notice Tests for the v0.2 escrow changes (arbiter registry, handoff recourse, deadlines, escalation,
///         timeout rule, settle reset, pause, payout hardening, admin).
contract EscrowV2Test is BaseTest {
    bytes32 terms = keccak256("terms");
    bytes32 item = keccak256("serial-xyz");
    uint256 constant AMT = 1 ether;

    function _deal(address arb) internal returns (uint256 id) {
        vm.prank(buyer);
        id = escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(vm.getBlockTimestamp() + 3 days), arb);
    }

    function _handoff() internal returns (uint256 id) {
        _file(seller, item, "watch");
        vm.prank(buyer);
        id = escrow.createHandoff{value: AMT}(seller, terms, item, 4 hours);
    }

    function _status(uint256 id) internal view returns (uint8 s) {
        (,,,,,,,, s,,) = escrow.getDeal(id);
    }

    function _arb(uint256 id) internal view returns (address a) {
        (,, a,,,,,,,,) = escrow.getDeal(id);
    }

    function _owner(bytes32 h) internal view returns (address o) {
        (o,,,) = vault.recordOf(h);
    }

    // ---------------- H-1 arbiter registry ----------------
    function test_arbiterMustBeApproved() public {
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.InvalidArbiter.selector);
        escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(vm.getBlockTimestamp() + 3 days), stranger);
        uint256 id = _deal(arbiter2);
        assertEq(_arb(id), arbiter2);
        assertTrue(escrow.isValidArbiter(arbiter2, buyer, seller));
        assertFalse(escrow.isValidArbiter(arbiter2, arbiter2, seller));
        assertFalse(escrow.isValidArbiter(address(0), buyer, seller));
    }

    function test_approvedArbiterCannotBeParty() public {
        vm.prank(owner);
        escrow.setArbiterApproved(buyer, true);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.InvalidArbiter.selector);
        escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(vm.getBlockTimestamp() + 3 days), buyer);
    }

    function test_defaultArbiterAsPartyRejected() public {
        vm.deal(arbiter, 10 ether);
        vm.prank(arbiter);
        vm.expectRevert(PoshEscrow.InvalidArbiter.selector);
        escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(vm.getBlockTimestamp() + 3 days), address(0));
        _file(seller, item, "w");
        vm.prank(arbiter);
        vm.expectRevert(PoshEscrow.InvalidArbiter.selector);
        escrow.createHandoff{value: AMT}(seller, terms, item, 4 hours);
    }

    // ---------------- M-1 ----------------
    function test_markDeliveredOnlyUntilDeadline() public {
        uint256 id = _deal(address(0));
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(seller);
        escrow.markDelivered(id); // exactly at deadline is fine
        uint256 id2 = _deal(address(0));
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.TooLate.selector);
        escrow.markDelivered(id2);
        vm.prank(buyer);
        escrow.refund(id2);
        assertEq(_status(id2), 4);
    }

    function test_markDeliveredWithProof() public {
        uint256 id = _deal(address(0));
        vm.prank(seller);
        escrow.markDeliveredWithProof(id, keccak256("tracking-123"));
        (,,,,,, bytes32 proof) = escrow.getDealExtra(id);
        assertEq(proof, keccak256("tracking-123"));
        assertEq(_status(id), 2);
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.markDelivered(id);
    }

    // ---------------- H-3 handoff recourse ----------------
    function test_handoffSellerMarksThenClaimsAfterConfirmWindow() public {
        uint256 id = _handoff();
        vm.prank(seller);
        escrow.markDeliveredWithProof(id, keccak256("meetup-photo"));
        vm.warp(vm.getBlockTimestamp() + 4 hours + 1);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.refund(id); // no refund once handed over
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.TooEarly.selector);
        escrow.sellerClaim(id);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        uint256 s0 = seller.balance;
        vm.prank(seller);
        escrow.sellerClaim(id);
        assertEq(seller.balance - s0, 0.99 ether);
        assertEq(_owner(item), buyer);
        assertEq(_status(id), 3);
    }

    function test_handoffSellerClaimRequiresFiling() public {
        uint256 id = _handoff();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(seller);
        vault.transfer(item, stranger);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.ItemNotOwnedBySeller.selector);
        escrow.sellerClaim(id);
    }

    function test_handoffBuyerDisputesFalseHandover() public {
        uint256 id = _handoff();
        vm.prank(seller);
        escrow.markDelivered(id); // seller claims handover that did not happen
        vm.prank(buyer);
        escrow.dispute(id);
        vm.prank(arbiter);
        escrow.acceptDeal(id);
        uint256 b0 = buyer.balance;
        vm.prank(arbiter);
        escrow.rule(id, false);
        assertEq(buyer.balance - b0, AMT);
        assertEq(_owner(item), seller);
    }

    function test_handoffBuyerCannotDisputeAfterConfirmWindow() public {
        uint256 id = _handoff();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.TooLate.selector);
        escrow.dispute(id);
    }

    function test_handoffSellerDisputeAndRulePaysAndMovesFiling() public {
        uint256 id = _handoff();
        vm.prank(seller);
        escrow.dispute(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.refund(id);
        vm.prank(arbiter);
        escrow.acceptDeal(id);
        vm.prank(arbiter);
        escrow.rule(id, true);
        assertEq(_owner(item), buyer);
        assertEq(_status(id), 6);
        assertEq(rewards.earned(seller), 0);
    }

    function test_handoffRuleSellerWithoutFilingStillPays() public {
        uint256 id = _handoff();
        vm.prank(seller);
        escrow.dispute(id);
        vm.prank(seller);
        vault.transfer(item, stranger);
        vm.prank(arbiter);
        escrow.acceptDeal(id);
        uint256 s0 = seller.balance;
        vm.prank(arbiter);
        escrow.rule(id, true);
        assertEq(seller.balance - s0, 0.99 ether);
        assertEq(_owner(item), stranger);
    }

    function test_sellerCannotDisputeFundedAfterDeadline() public {
        uint256 id = _handoff();
        vm.warp(vm.getBlockTimestamp() + 4 hours + 1);
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.TooLate.selector);
        escrow.dispute(id);
        vm.prank(buyer);
        escrow.refund(id);
    }

    function test_handoffReleaseWithBuyerSignature() public {
        (address b, uint256 pk) = makeAddrAndKey("sigBuyer");
        vm.deal(b, 5 ether);
        _file(seller, item, "w");
        vm.prank(b);
        uint256 id = escrow.createHandoff{value: AMT}(seller, terms, item, 2 hours);
        bytes32 digest = escrow.handoffReceiptDigest(id);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        // wrong signer
        (, uint256 pk2) = makeAddrAndKey("other");
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk2, digest);
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.BadSignature.selector);
        escrow.releaseHandoffWithSig(id, abi.encodePacked(r2, s2, v2));
        uint256 s0 = seller.balance;
        vm.prank(seller);
        escrow.releaseHandoffWithSig(id, abi.encodePacked(r, s, v));
        assertEq(seller.balance - s0, 0.99 ether);
        assertEq(_owner(item), b);
        // replay impossible
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.releaseHandoffWithSig(id, abi.encodePacked(r, s, v));
    }

    function test_handoffReleaseWithSmartWalletSignature() public {
        (address eoa, uint256 pk) = makeAddrAndKey("walletSigner");
        Mock1271Wallet w = new Mock1271Wallet(eoa);
        vm.deal(address(w), 5 ether);
        _file(seller, item, "w");
        vm.prank(eoa);
        bytes memory ret = w.call(
            address(escrow), AMT, abi.encodeCall(PoshEscrow.createHandoff, (seller, terms, item, uint64(2 hours)))
        );
        uint256 id = abi.decode(ret, (uint256));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, escrow.handoffReceiptDigest(id));
        vm.prank(seller);
        escrow.releaseHandoffWithSig(id, abi.encodePacked(r, s, v));
        assertEq(_owner(item), address(w));
    }

    function test_releaseHandoffWithSigOnNormalDealReverts() public {
        (address b, uint256 pk) = makeAddrAndKey("sigBuyer2");
        vm.deal(b, 5 ether);
        vm.prank(b);
        uint256 id =
            escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(vm.getBlockTimestamp() + 3 days), address(0));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, escrow.handoffReceiptDigest(id));
        vm.expectRevert(PoshEscrow.NotHandoff.selector);
        escrow.releaseHandoffWithSig(id, abi.encodePacked(r, s, v));
        vm.prank(b);
        vm.expectRevert(PoshEscrow.NotHandoff.selector);
        escrow.releaseHandoff(id, bytes32(0));
    }

    function test_handoffBuyerReleaseAfterMark() public {
        uint256 id = _handoff();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(buyer);
        escrow.releaseHandoff(id, item);
        assertEq(_owner(item), buyer);
    }

    function test_handoffSettleMovesFiling() public {
        uint256 id = _handoff();
        vm.prank(buyer);
        escrow.settle(id, true);
        vm.prank(seller);
        escrow.settle(id, true);
        assertEq(_owner(item), buyer);
        assertEq(_status(id), 3);
    }

    // ---------------- buyer dispute window on normal deals ----------------
    function test_buyerCannotDisputeAfterReviewPeriod() public {
        uint256 id = _deal(address(0));
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.TooLate.selector);
        escrow.dispute(id);
        vm.prank(seller);
        escrow.dispute(id); // seller may still (e.g. to get a ruling)
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.dispute(id);
    }

    // ---------------- M-2 escalation + timeout ----------------
    function test_escalateIdleCustomArbiterThenRule() public {
        uint256 id = _deal(arbiter2);
        vm.prank(buyer);
        escrow.dispute(id);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.TooEarly.selector);
        escrow.escalate(id);
        vm.prank(stranger);
        vm.expectRevert(PoshEscrow.NotParty.selector);
        escrow.escalate(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(seller);
        escrow.escalate(id);
        assertEq(_arb(id), arbiter);
        (,, bool acc,,, bool esc,) = escrow.getDealExtra(id);
        assertFalse(acc);
        assertTrue(esc);
        vm.prank(arbiter2);
        vm.expectRevert(PoshEscrow.NotArbiter.selector);
        escrow.acceptDeal(id);
        vm.prank(arbiter);
        escrow.acceptDeal(id);
        vm.prank(arbiter);
        escrow.rule(id, false);
        assertEq(_status(id), 6);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.escalate(id);
    }

    function test_escalateAcceptedButNotRuling() public {
        uint256 id = _deal(arbiter2);
        vm.prank(buyer);
        escrow.dispute(id);
        vm.prank(arbiter2);
        escrow.acceptDeal(id);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.TooEarly.selector);
        escrow.escalate(id); // accepted, still inside ruling window
        vm.warp(vm.getBlockTimestamp() + 22 days);
        vm.prank(buyer);
        escrow.escalate(id);
        assertEq(_arb(id), arbiter);
    }

    function test_escalateDelistedArbiterImmediately() public {
        uint256 id = _deal(arbiter2);
        vm.prank(buyer);
        escrow.dispute(id);
        vm.prank(owner);
        escrow.setArbiterApproved(arbiter2, false);
        vm.prank(buyer);
        escrow.escalate(id);
        assertEq(_arb(id), arbiter);
    }

    function test_cannotEscalateDefaultArbiter() public {
        uint256 id = _deal(address(0));
        vm.prank(buyer);
        escrow.dispute(id);
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.CannotEscalate.selector);
        escrow.escalate(id);
    }

    function test_timeoutRefundsBuyerWhenNeverDelivered() public {
        uint256 id = _deal(address(0));
        vm.prank(seller);
        escrow.dispute(id); // seller disputes before deadline to stall
        vm.warp(vm.getBlockTimestamp() + 30 days - 1);
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.TooEarly.selector);
        escrow.resolveTimeout(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 b0 = buyer.balance;
        vm.prank(seller);
        escrow.resolveTimeout(id);
        assertEq(buyer.balance - b0, AMT);
        assertEq(_status(id), 6);
        (,, uint256 refunds,,) = passport.getPassport(seller);
        assertEq(refunds, 1);
    }

    function test_timeoutPaysSellerWhenDelivered() public {
        uint256 id = _deal(address(0));
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(buyer);
        escrow.dispute(id); // buyer disputes after delivery to claw back
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 s0 = seller.balance;
        vm.prank(buyer);
        escrow.resolveTimeout(id);
        assertEq(seller.balance - s0, 0.99 ether);
        assertEq(rewards.earned(seller), 0);
        (uint256 c,,,,) = passport.getPassport(seller);
        assertEq(c, 1);
    }

    function test_timeoutRequiresEscalationFirst() public {
        uint256 id = _deal(arbiter2);
        vm.prank(buyer);
        escrow.dispute(id);
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.CannotEscalate.selector);
        escrow.resolveTimeout(id);
        vm.prank(buyer);
        escrow.escalate(id);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.TooEarly.selector);
        escrow.resolveTimeout(id); // fresh clock for the default arbiter
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(buyer);
        escrow.resolveTimeout(id);
        assertEq(_status(id), 6);
    }

    function test_timeoutOnlyPartiesAndDisputed() public {
        uint256 id = _deal(address(0));
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.resolveTimeout(id);
        vm.prank(stranger);
        vm.expectRevert(PoshEscrow.NotParty.selector);
        escrow.resolveTimeout(id);
    }

    // ---------------- L-4 settle reset ----------------
    function test_settleVotesResetOnStateChange() public {
        uint256 id = _deal(address(0));
        vm.prank(seller);
        escrow.settle(id, false); // seller offered a refund early
        vm.prank(seller);
        escrow.markDelivered(id); // ...then delivered: stale offer must not be executable
        (,,,,,,,,, bool sa,) = escrow.getDeal(id);
        assertFalse(sa);
        vm.prank(buyer);
        escrow.settle(id, false);
        assertEq(_status(id), 2);
        vm.prank(buyer);
        escrow.dispute(id);
        (,,,,,,,,,, bool ba) = escrow.getDeal(id);
        assertFalse(ba);
    }

    // ---------------- pause / guardian ----------------
    function test_creationPauseByGuardianOnlyOwnerUnpauses() public {
        uint256 id = _deal(address(0));
        vm.prank(stranger);
        vm.expectRevert(PoshEscrow.NotAuthorized.selector);
        escrow.setCreationPaused(true);
        vm.prank(guardian);
        escrow.setCreationPaused(true);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.CreationPaused.selector);
        escrow.createDeal{value: AMT}(seller, terms, address(0), AMT, uint64(vm.getBlockTimestamp() + 3 days), address(0));
        _file(seller, item, "w");
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.CreationPaused.selector);
        escrow.createHandoff{value: AMT}(seller, terms, item, 4 hours);
        // existing deals unaffected
        vm.prank(buyer);
        escrow.release(id);
        vm.prank(guardian);
        vm.expectRevert(PoshEscrow.NotAuthorized.selector);
        escrow.setCreationPaused(false);
        vm.prank(owner);
        escrow.setCreationPaused(false);
        _deal(address(0));
    }

    // ---------------- payout hardening ----------------
    function test_gasBurnerSellerDeferred() public {
        GasBurner g = new GasBurner();
        vm.prank(buyer);
        uint256 id = escrow.createDeal{value: AMT}(
            address(g), terms, address(0), AMT, uint64(vm.getBlockTimestamp() + 3 days), address(0)
        );
        vm.prank(buyer);
        escrow.release{gas: 2_000_000}(id);
        assertEq(escrow.pendingWithdrawals(address(0), address(g)), 0.99 ether);
        assertEq(escrow.totalPending(address(0)), 0.99 ether);
    }

    function test_weirdTokenReturnsDeferNotRevert() public {
        WeirdToken w = new WeirdToken();
        vm.prank(owner);
        escrow.setAllowedToken(address(w), true);
        w.mint(buyer, 1000e6);
        uint8[3] memory modes = [uint8(1), 2, 3];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(buyer);
            w.approve(address(escrow), 100e6);
            uint256 id = escrow.createDeal(seller, terms, address(w), 100e6, uint64(vm.getBlockTimestamp() + 3 days), address(0));
            vm.stopPrank();
            w.setMode(modes[i]);
            vm.prank(buyer);
            escrow.release(id);
            w.setMode(0);
        }
        // modes 1 and 2 deferred (false / malformed bool); mode 3 (no return data) paid
        assertEq(escrow.pendingWithdrawals(address(w), seller), 2 * 99e6);
        assertEq(w.balanceOf(seller), 99e6);
        vm.prank(seller);
        escrow.withdraw(address(w));
        assertEq(w.balanceOf(seller), 3 * 99e6);
    }

    function test_withdrawEthAndNothing() public {
        RevertingReceiver bad = new RevertingReceiver();
        vm.prank(buyer);
        uint256 id = escrow.createDeal{value: AMT}(
            address(bad), terms, address(0), AMT, uint64(vm.getBlockTimestamp() + 3 days), address(0)
        );
        vm.prank(buyer);
        escrow.release(id);
        vm.prank(address(bad));
        vm.expectRevert("eth send failed");
        escrow.withdraw(address(0));
        vm.prank(stranger);
        vm.expectRevert(PoshEscrow.NothingToWithdraw.selector);
        escrow.withdraw(address(0));
    }

    function test_usdcFeeOnTransferMismatchAndValue() public {
        vm.startPrank(buyer);
        vm.expectRevert(PoshEscrow.InvalidSeller.selector);
        escrow.createDeal(address(0), terms, address(0), AMT, uint64(vm.getBlockTimestamp() + 3 days), address(0));
        vm.expectRevert(PoshEscrow.InvalidSeller.selector);
        escrow.createHandoff{value: AMT}(buyer, terms, item, 4 hours);
        vm.expectRevert(PoshEscrow.InvalidAmount.selector);
        escrow.createHandoff(seller, terms, item, 4 hours);
        vm.expectRevert(PoshEscrow.ItemNotOwnedBySeller.selector);
        escrow.createHandoff{value: AMT}(seller, terms, item, 4 hours);
        vm.stopPrank();
    }

    // ---------------- access / admin ----------------
    function test_accessControlRevertsEverywhere() public {
        uint256 id = _deal(address(0));
        vm.startPrank(stranger);
        vm.expectRevert(PoshEscrow.NotBuyer.selector);
        escrow.refund(id);
        vm.expectRevert(PoshEscrow.NotSeller.selector);
        escrow.sellerRefund(id);
        vm.expectRevert(PoshEscrow.NotSeller.selector);
        escrow.sellerClaim(id);
        vm.expectRevert(PoshEscrow.NotBuyer.selector);
        escrow.releaseHandoff(id, item);
        vm.expectRevert(PoshEscrow.NotParty.selector);
        escrow.settle(id, true);
        vm.expectRevert(PoshEscrow.NotArbiter.selector);
        escrow.rule(id, true);
        vm.stopPrank();
        vm.prank(arbiter);
        escrow.acceptDeal(id);
        vm.prank(arbiter);
        vm.expectRevert(PoshEscrow.AlreadyAccepted.selector);
        escrow.acceptDeal(id);
        vm.prank(arbiter);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.rule(id, true); // not disputed
        vm.prank(buyer);
        escrow.release(id);
        vm.startPrank(seller);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.sellerRefund(id);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.settle(id, true);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.dispute(id);
        vm.stopPrank();
        vm.prank(arbiter);
        vm.expectRevert(PoshEscrow.AlreadyAccepted.selector);
        escrow.acceptDeal(id);
        uint256 id2 = _deal(address(0));
        vm.prank(buyer);
        escrow.release(id2);
        vm.prank(arbiter);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.acceptDeal(id2);
    }

    function test_adminSettersAndOwnable2Step() public {
        vm.startPrank(owner);
        vm.expectRevert(PoshEscrow.ZeroAddress.selector);
        escrow.setTreasury(address(0));
        vm.expectRevert(PoshEscrow.ZeroAddress.selector);
        escrow.setDefaultArbiter(address(0));
        vm.expectRevert(PoshEscrow.ZeroAddress.selector);
        escrow.setArbiterApproved(address(0), true);
        vm.expectRevert(PoshEscrow.ZeroAddress.selector);
        escrow.setAllowedToken(address(0), true);
        escrow.setTreasury(stranger);
        escrow.setDefaultArbiter(arbiter2);
        escrow.setHooks(address(0), address(0));
        escrow.transferOwnership(stranger);
        vm.stopPrank();
        assertEq(escrow.treasury(), stranger);
        assertEq(escrow.defaultArbiter(), arbiter2);
        assertEq(escrow.owner(), owner); // two-step: not yet
        vm.prank(stranger);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), stranger);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        escrow.setFeeBps(0);
        // hooks disabled: deals still complete
        uint256 id = _deal(address(0));
        vm.prank(buyer);
        escrow.release(id);
        assertEq(_status(id), 3);
    }

    function test_constructorZeroChecks() public {
        vm.expectRevert(PoshEscrow.ZeroAddress.selector);
        new PoshEscrow(address(0), address(0), address(0), treasury, arbiter, address(0), owner);
        vm.expectRevert(PoshEscrow.ZeroAddress.selector);
        new PoshEscrow(address(vault), address(0), address(0), address(0), arbiter, address(0), owner);
        vm.expectRevert(PoshEscrow.ZeroAddress.selector);
        new PoshEscrow(address(vault), address(0), address(0), treasury, address(0), address(0), owner);
        PoshEscrow e = new PoshEscrow(address(vault), address(0), address(0), treasury, arbiter, address(0), owner);
        assertFalse(e.allowedToken(address(usdc)));
    }
}
