// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Regression versions of compliance/audit/poc/SelfReviewPoC.t.sol (v0.1 exploits).
// Each test replays the original attack against the v0.2 code and asserts that it now FAILS.
import {BaseTest} from "./Base.t.sol";
import {PoshEscrow} from "../src/PoshEscrow.sol";
import {ProofVault} from "../src/ProofVault.sol";
import {FMNYSale} from "../src/FMNYSale.sol";
import {FMNYRewards} from "../src/FMNYRewards.sol";
import {RevertingReceiver} from "./mocks/MockUSDC.sol";

contract SelfReviewRegression is BaseTest {
    address buyerAlt = makeAddr("buyerAlt"); // attacker-controlled second wallet

    // H-1: buyer can no longer name its own alt wallet as arbiter.
    function test_H1_buyerCannotAppointOwnArbiter() public {
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.InvalidArbiter.selector);
        escrow.createDeal{value: 1 ether}(
            seller, bytes32("terms"), address(0), 1 ether, uint64(vm.getBlockTimestamp() + 3 days), buyerAlt
        );
        // and the original sequence cannot even start: no deal exists for the alt wallet to rule on
        vm.prank(buyerAlt);
        vm.expectRevert(PoshEscrow.NotArbiter.selector);
        escrow.acceptDeal(1);
    }

    // H-2: a 1 USDC fee used to earn 100,000 FMNY. Now: priced via oracle, 25% rebate, pair/min/caps.
    function test_H2_usdcWashTradeNoLongerProfitable() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100e6);
        uint256 id = escrow.createDeal(
            buyerAlt, bytes32("t"), address(usdc), 100e6, uint64(vm.getBlockTimestamp() + 3 days), address(0)
        );
        escrow.release(id); // self-deal to own alt wallet, 1 USDC fee
        vm.stopPrank();
        uint256 earned = rewards.earned(buyer) + rewards.earned(buyerAlt);
        emit log_named_decimal_uint("FMNY earned for a 1 USDC fee (v0.1: 100000)", earned, 18);
        // 1 USDC at $3000/ETH = 0.000333 ETH; 25% rebate at 0.00001 ETH/FMNY = 8.33 FMNY
        assertApproxEqAbs(earned, 8.333 ether, 0.001 ether);
        // value of the reward at the sale price is 25% of the fee: farming loses 75% of every fee + gas
        uint256 feeWei = (1e6 * 1e12 * 1e8) / uint256(ETH_USD);
        assertLe((earned * PRICE / 1e18) * 4, feeWei);
        // repeating with the same pair in the same epoch earns nothing more
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100e6);
        id = escrow.createDeal(
            buyerAlt, bytes32("t2"), address(usdc), 100e6, uint64(vm.getBlockTimestamp() + 3 days), address(0)
        );
        escrow.release(id);
        vm.stopPrank();
        assertEq(rewards.earned(buyer) + rewards.earned(buyerAlt), earned);
    }

    // H-2 (pool drain): even with max parameters and unlimited sybils, one epoch emits <= its budget.
    function test_H2_poolDrainBoundedByEpochBudget() public {
        vm.prank(owner);
        rewards.setParams(5_000, PRICE, 0.001 ether, 10_000 ether, 250_000 ether); // most generous allowed
        for (uint256 i; i < 40; ++i) {
            address b = address(uint160(0xB000 + 2 * i));
            address s = address(uint160(0xB001 + 2 * i));
            vm.deal(b, 200 ether);
            vm.prank(b);
            uint256 id = escrow.createDeal{value: 100 ether}(
                s, bytes32("w"), address(0), 100 ether, uint64(vm.getBlockTimestamp() + 3 days), address(0)
            );
            vm.prank(b);
            escrow.release(id);
        }
        assertEq(rewards.totalEmitted(), rewards.epochBudget(0));
        assertLe(rewards.totalEmitted(), 180_000 ether);
    }

    // H-3: buyer takes the item and goes silent -> seller marked handed-off -> refund impossible, seller claims.
    function test_H3_handoffBuyerFreeOptionClosed() public {
        bytes32 item = keccak256("serial-123");
        _file(seller, item, "watch");
        vm.prank(buyer);
        uint256 id = escrow.createHandoff{value: 1 ether}(seller, bytes32("t"), item, 2 hours);
        vm.prank(seller);
        escrow.markDeliveredWithProof(id, keccak256("meetup-qr-scan")); // at the meetup
        vm.warp(vm.getBlockTimestamp() + 2 hours + 1);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.refund(id); // the v0.1 exploit step now fails
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        uint256 s0 = seller.balance;
        vm.prank(seller);
        escrow.sellerClaim(id);
        assertEq(seller.balance - s0, 0.99 ether);
        (address o,,,) = vault.recordOf(item);
        assertEq(o, buyer);
    }

    // H-3 variant: seller forgot to mark but can dispute before the window ends (v0.1: dispute reverted).
    function test_H3_sellerCanDisputeHandoff() public {
        bytes32 item = keccak256("serial-456");
        _file(seller, item, "bike");
        vm.prank(buyer);
        uint256 id = escrow.createHandoff{value: 1 ether}(seller, bytes32("t"), item, 2 hours);
        vm.prank(seller);
        escrow.dispute(id);
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        vm.prank(buyer);
        vm.expectRevert(PoshEscrow.BadStatus.selector);
        escrow.refund(id);
    }

    // M-1: late markDelivered can no longer block the refund.
    function test_M1_lateMarkDeliveredRejected() public {
        vm.prank(buyer);
        uint256 id = escrow.createDeal{value: 1 ether}(
            seller, bytes32("t"), address(0), 1 ether, uint64(vm.getBlockTimestamp() + 2 hours), address(0)
        );
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(seller);
        vm.expectRevert(PoshEscrow.TooLate.selector);
        escrow.markDelivered(id);
        uint256 b0 = buyer.balance;
        vm.prank(buyer);
        escrow.refund(id);
        assertEq(buyer.balance - b0, 1 ether);
    }

    // M-2: no 50/50 coercion. A non-delivering seller who disputes gets nothing on timeout.
    function test_M2_disputeTimeoutNoLongerSplits() public {
        vm.prank(buyer);
        uint256 id = escrow.createDeal{value: 1 ether}(
            seller, bytes32("t"), address(0), 1 ether, uint64(vm.getBlockTimestamp() + 3 days), address(0)
        );
        vm.prank(seller);
        escrow.dispute(id);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 s0 = seller.balance;
        uint256 b0 = buyer.balance;
        vm.prank(seller);
        escrow.resolveTimeout(id);
        assertEq(seller.balance, s0);
        assertEq(buyer.balance - b0, 1 ether);
    }

    // M-3: owner can no longer repoint ProofVault.escrow and move filings.
    function test_M3_ownerCannotMoveFilings() public {
        bytes32 item = keccak256("deed");
        _file(seller, item, "deed");
        vm.startPrank(owner);
        vm.expectRevert(ProofVault.EscrowAlreadySet.selector);
        vault.setEscrow(owner);
        vm.expectRevert(ProofVault.NotAuthorized.selector);
        vault.transfer(item, stranger);
        vm.stopPrank();
        (address o,,,) = vault.recordOf(item);
        assertEq(o, seller);
    }

    // M-4: owner can no longer end the sale early as a success.
    function test_M4_ownerCannotFinalizeEarly() public {
        vm.prank(owner);
        vm.expectRevert(FMNYSale.CannotFinalizeYet.selector);
        sale.finalize();
    }

    // M-5: a treasury that rejects ETH can no longer freeze the sale.
    function test_M5_rejectingTreasuryDoesNotFreeze() public {
        RevertingReceiver bad = new RevertingReceiver();
        FMNYSale s2 = new FMNYSale(
            address(fmny), address(bad), owner, PRICE, 1 ether, 10 ether, 0.01 ether, 5 ether,
            vm.getBlockTimestamp(), 1 days, 0
        );
        vm.prank(treasury);
        fmny.transfer(address(s2), 1_000_000 ether);
        address[] memory a = new address[](1);
        a[0] = buyer;
        vm.prank(owner);
        s2.setApproved(a, true);
        vm.prank(buyer);
        s2.buy{value: 2 ether}();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        s2.finalize();
        assertTrue(s2.succeeded());
        vm.prank(buyer);
        s2.claim();
        assertEq(fmny.balanceOf(buyer), 200_000 ether);
    }

    // M-6: a front-runner who copies the reveal cannot file first.
    function test_M6_frontRunnerCannotSquat() public {
        bytes32 item = keccak256(abi.encode("my-receipt", bytes32("secret-salt")));
        bytes32 salt = bytes32("s");
        vm.prank(seller);
        vault.commitFiling(vault.commitmentFor(item, seller, salt));
        vm.roll(vm.getBlockNumber() + 1);
        // attacker sees seller's file(item, label, salt) in the mempool and copies it
        vm.prank(stranger);
        vm.expectRevert(ProofVault.NoCommitment.selector);
        vault.file(item, "squat", salt);
        // attacker can only commit now; the honest reveal lands first
        vm.prank(stranger);
        vault.commitFiling(vault.commitmentFor(item, stranger, salt));
        vm.prank(seller);
        vault.file(item, "real owner", salt);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(stranger);
        vm.expectRevert(ProofVault.AlreadyFiled.selector);
        vault.file(item, "squat", salt);
        (address o,,,) = vault.recordOf(item);
        assertEq(o, seller);
    }

    // L-4: a stale settlement offer cannot be executed after the deal changes state.
    function test_L4_staleSettleNotExecutable() public {
        vm.prank(buyer);
        uint256 id = escrow.createDeal{value: 1 ether}(
            seller, bytes32("t"), address(0), 1 ether, uint64(vm.getBlockTimestamp() + 3 days), address(0)
        );
        vm.prank(seller);
        escrow.settle(id, false);
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(buyer);
        escrow.settle(id, false); // would have refunded the buyer in v0.1
        (,,,,,,,, uint8 st,,) = escrow.getDeal(id);
        assertEq(st, 2);
    }

    // L-10: settle-to-seller no longer emits rewards ("no rewards on disputed deals").
    function test_L10_noRewardsOnSettleOrRule() public {
        vm.prank(buyer);
        uint256 id = escrow.createDeal{value: 1 ether}(
            seller, bytes32("t"), address(0), 1 ether, uint64(vm.getBlockTimestamp() + 3 days), address(0)
        );
        vm.prank(buyer);
        escrow.dispute(id);
        vm.prank(buyer);
        escrow.settle(id, true);
        vm.prank(seller);
        escrow.settle(id, true);
        assertEq(rewards.earned(seller) + rewards.earned(buyer), 0);
        assertEq(uint8(FMNYRewards.Skip.None), 0);
    }
}
