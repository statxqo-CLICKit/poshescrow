// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {FMNYSale} from "../src/FMNYSale.sol";
import {RevertingReceiver} from "./mocks/MockUSDC.sol";

contract SaleTest is BaseTest {
    address[] wallets;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 40; i++) {
            address w = address(uint160(0x1000 + i));
            vm.deal(w, 10 ether);
            wallets.push(w);
        }
        vm.prank(owner);
        sale.setApproved(wallets, true);
    }

    function test_params() public view {
        assertEq(sale.price(), 1e13);
        assertEq(sale.softCap(), 50 ether);
        assertEq(sale.hardCap(), 150 ether);
        assertEq(sale.endTime(), block.timestamp + 30 days);
        assertTrue(sale.approved(wallets[0]));
        assertFalse(sale.approved(stranger));
    }

    function test_buyRules() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(FMNYSale.NotApproved.selector);
        sale.buy{value: 1 ether}();
        vm.startPrank(wallets[0]);
        vm.expectRevert(FMNYSale.BelowMin.selector);
        sale.buy{value: 0.009 ether}();
        sale.buy{value: 4 ether}();
        vm.expectRevert(FMNYSale.AboveMax.selector);
        sale.buy{value: 1.01 ether}();
        sale.buy{value: 1 ether}();
        vm.stopPrank();
        assertEq(sale.contributions(wallets[0]), 5 ether);
        assertEq(sale.raised(), 5 ether);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(wallets[1]);
        vm.expectRevert(FMNYSale.SaleClosed.selector);
        sale.buy{value: 1 ether}();
    }

    function test_softCapFailRefund() public {
        for (uint256 i; i < 5; i++) {
            vm.prank(wallets[i]);
            sale.buy{value: 5 ether}();
        }
        vm.prank(stranger);
        vm.expectRevert(FMNYSale.CannotFinalizeYet.selector);
        sale.finalize();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(stranger);
        sale.finalize();
        assertTrue(sale.finalized());
        assertFalse(sale.succeeded());
        uint256 b0 = wallets[0].balance;
        vm.prank(wallets[0]);
        sale.refund();
        assertEq(wallets[0].balance - b0, 5 ether);
        vm.prank(wallets[0]);
        vm.expectRevert(FMNYSale.NothingToRefund.selector);
        sale.refund();
        vm.prank(wallets[1]);
        vm.expectRevert(FMNYSale.SaleFailed.selector);
        sale.claim();
        uint256 t0 = fmny.balanceOf(treasury);
        sale.returnUnsold();
        assertEq(fmny.balanceOf(treasury) - t0, 15_000_000 ether);
    }

    function test_successClaimAfterLock() public {
        for (uint256 i; i < 12; i++) {
            vm.prank(wallets[i]);
            sale.buy{value: 5 ether}();
        }
        assertEq(sale.raised(), 60 ether);
        vm.prank(owner);
        vm.expectRevert(FMNYSale.CannotFinalizeYet.selector); // owner can no longer end early
        sale.finalize();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        sale.finalize();
        assertTrue(sale.succeeded());
        uint256 t0 = treasury.balance;
        vm.prank(treasury);
        sale.withdrawRaised(treasury);
        assertEq(treasury.balance - t0, 60 ether);
        assertEq(sale.unlockTime(), vm.getBlockTimestamp() + 90 days);
        vm.prank(wallets[0]);
        vm.expectRevert(FMNYSale.Locked.selector);
        sale.claim();
        vm.prank(wallets[0]);
        vm.expectRevert(FMNYSale.SaleSucceeded.selector);
        sale.refund();
        vm.warp(vm.getBlockTimestamp() + 90 days);
        vm.prank(wallets[0]);
        sale.claim();
        assertEq(fmny.balanceOf(wallets[0]), 500_000 ether); // 5 ETH / 0.00001
        vm.prank(wallets[0]);
        vm.expectRevert(FMNYSale.NothingToClaim.selector);
        sale.claim();
        // unsold: 15M - 6M sold returned; remaining claims still covered
        uint256 f0 = fmny.balanceOf(treasury);
        sale.returnUnsold();
        assertEq(fmny.balanceOf(treasury) - f0, 9_000_000 ether);
        vm.prank(wallets[11]);
        sale.claim();
        assertEq(fmny.balanceOf(wallets[11]), 500_000 ether);
    }

    function test_hardCapAllowsAnyoneToFinalize() public {
        for (uint256 i; i < 30; i++) {
            vm.prank(wallets[i]);
            sale.buy{value: 5 ether}();
        }
        assertEq(sale.raised(), 150 ether);
        vm.prank(wallets[30]);
        vm.expectRevert(FMNYSale.HardCapExceeded.selector);
        sale.buy{value: 1 ether}();
        vm.prank(stranger);
        sale.finalize();
        assertTrue(sale.succeeded());
        vm.prank(stranger);
        vm.expectRevert(FMNYSale.AlreadyFinalized.selector);
        sale.finalize();
        sale.returnUnsold(); // nothing unsold
        assertEq(fmny.balanceOf(address(sale)), 15_000_000 ether);
    }

    function test_onlyOwnerApproves() public {
        vm.prank(stranger);
        vm.expectRevert();
        sale.setApproved(wallets, false);
    }
}

contract SaleV2Test is BaseTest {
    address[] wallets;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 12; i++) {
            address w = address(uint160(0x2000 + i));
            vm.deal(w, 10 ether);
            wallets.push(w);
        }
        vm.prank(guardian); // guardian manages the allowlist
        sale.setApproved(wallets, true);
    }

    function _fill(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.prank(wallets[i]);
            sale.buy{value: 5 ether}();
        }
    }

    function test_startTimeEnforced() public {
        FMNYSale later = new FMNYSale(
            address(fmny), treasury, owner, PRICE, 50 ether, 150 ether, 0.01 ether, 5 ether,
            vm.getBlockTimestamp() + 3 days, 30 days, 90 days
        );
        vm.prank(owner);
        later.setApproved(wallets, true);
        vm.prank(treasury);
        fmny.transfer(address(later), 1_000_000 ether);
        vm.prank(wallets[0]);
        vm.expectRevert(FMNYSale.NotStarted.selector);
        later.buy{value: 1 ether}();
        assertEq(later.endTime(), later.startTime() + 30 days);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(wallets[0]);
        later.buy{value: 1 ether}();
        assertEq(later.raised(), 1 ether);
    }

    function test_constructorRejectsBadParams() public {
        uint256 t = vm.getBlockTimestamp();
        vm.expectRevert(FMNYSale.BadParams.selector);
        new FMNYSale(address(fmny), treasury, owner, PRICE, 50 ether, 150 ether, 0.01 ether, 5 ether, t - 1, 30 days, 90 days);
        vm.expectRevert(FMNYSale.BadParams.selector);
        new FMNYSale(address(fmny), treasury, owner, PRICE, 0, 150 ether, 0.01 ether, 5 ether, t, 30 days, 90 days);
        vm.expectRevert(FMNYSale.BadParams.selector);
        new FMNYSale(address(fmny), treasury, owner, PRICE, 50 ether, 150 ether, 0.01 ether, 5 ether, t, 0, 90 days);
        vm.expectRevert(FMNYSale.BadParams.selector);
        new FMNYSale(address(0), treasury, owner, PRICE, 50 ether, 150 ether, 0.01 ether, 5 ether, t, 30 days, 90 days);
        vm.expectRevert(FMNYSale.BadParams.selector);
        new FMNYSale(address(fmny), treasury, owner, PRICE, 50 ether, 150 ether, 6 ether, 5 ether, t, 30 days, 90 days);
    }

    function test_cancelPutsSaleInRefundMode() public {
        _fill(12); // 60 ETH, above soft cap
        vm.prank(stranger);
        vm.expectRevert(FMNYSale.NotAuthorized.selector);
        sale.cancel();
        vm.prank(guardian);
        sale.cancel();
        assertTrue(sale.finalized());
        assertTrue(sale.cancelled());
        assertFalse(sale.succeeded());
        uint256 b0 = wallets[3].balance;
        vm.prank(wallets[3]);
        sale.refund();
        assertEq(wallets[3].balance - b0, 5 ether);
        vm.prank(treasury);
        vm.expectRevert(FMNYSale.SaleFailed.selector);
        sale.withdrawRaised(treasury);
        vm.prank(owner);
        vm.expectRevert(FMNYSale.AlreadyFinalized.selector);
        sale.cancel();
    }

    function test_pauseBuys() public {
        vm.prank(guardian);
        sale.setPaused(true);
        vm.prank(wallets[0]);
        vm.expectRevert(FMNYSale.SalePaused.selector);
        sale.buy{value: 1 ether}();
        vm.prank(owner);
        sale.setPaused(false);
        vm.prank(wallets[0]);
        sale.buy{value: 1 ether}();
    }

    function test_rejectingTreasuryCannotFreezeSale() public {
        RevertingReceiver bad = new RevertingReceiver();
        FMNYSale s2 = new FMNYSale(
            address(fmny), address(bad), owner, PRICE, 1 ether, 150 ether, 0.01 ether, 5 ether,
            vm.getBlockTimestamp(), 1 days, 0
        );
        vm.prank(treasury);
        fmny.transfer(address(s2), 1_000_000 ether);
        vm.prank(owner);
        s2.setApproved(wallets, true);
        vm.prank(wallets[0]);
        s2.buy{value: 2 ether}();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        s2.finalize(); // no ETH push => cannot revert
        assertTrue(s2.succeeded());
        vm.prank(wallets[0]);
        s2.claim(); // buyers unaffected
        assertEq(fmny.balanceOf(wallets[0]), 200_000 ether);
        // treasury chooses a destination that accepts ETH
        vm.prank(address(bad));
        s2.withdrawRaised(stranger);
        assertEq(stranger.balance, 2 ether);
        vm.prank(address(bad));
        vm.expectRevert(FMNYSale.NothingToWithdraw.selector);
        s2.withdrawRaised(stranger);
        vm.prank(address(bad));
        vm.expectRevert(FMNYSale.ZeroAddress.selector);
        s2.withdrawRaised(address(0));
        vm.prank(stranger);
        vm.expectRevert(FMNYSale.NotAuthorized.selector);
        s2.withdrawRaised(stranger);
    }

    function test_withdrawToRejectingAddressReverts() public {
        _fill(12);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        sale.finalize();
        RevertingReceiver bad = new RevertingReceiver();
        vm.prank(treasury);
        vm.expectRevert(FMNYSale.TransferFailed.selector);
        sale.withdrawRaised(address(bad));
    }

    function test_refundAndClaimGuards() public {
        vm.prank(wallets[0]);
        vm.expectRevert(FMNYSale.NotFinalized.selector);
        sale.refund();
        vm.prank(wallets[0]);
        vm.expectRevert(FMNYSale.NotFinalized.selector);
        sale.claim();
        vm.expectRevert(FMNYSale.NotFinalized.selector);
        sale.returnUnsold();
        RevertingReceiver bad = new RevertingReceiver();
        address[] memory one = new address[](1);
        one[0] = address(bad);
        vm.prank(guardian);
        sale.setApproved(one, true);
        vm.deal(address(bad), 1 ether);
        vm.prank(address(bad));
        sale.buy{value: 1 ether}();
        vm.prank(guardian);
        sale.cancel();
        vm.prank(address(bad));
        vm.expectRevert(FMNYSale.TransferFailed.selector);
        sale.refund();
    }

    function test_guardianAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        sale.setGuardian(stranger);
        vm.prank(owner);
        sale.setGuardian(address(0));
        vm.prank(guardian);
        vm.expectRevert(FMNYSale.NotAuthorized.selector);
        sale.setPaused(true);
    }

    function test_insufficientTokens() public {
        FMNYSale s2 = new FMNYSale(
            address(fmny), treasury, owner, PRICE, 1 ether, 150 ether, 0.01 ether, 5 ether, vm.getBlockTimestamp(), 1 days, 0
        );
        vm.prank(owner);
        s2.setApproved(wallets, true);
        vm.prank(wallets[0]);
        vm.expectRevert(FMNYSale.InsufficientTokens.selector);
        s2.buy{value: 1 ether}();
    }
}
