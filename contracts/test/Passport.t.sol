// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {TrustPassport} from "../src/TrustPassport.sol";

contract PassportTest is BaseTest {
    function test_onlyEscrowWrites() public {
        vm.prank(stranger);
        vm.expectRevert(TrustPassport.OnlyEscrow.selector);
        passport.recordCompletion(stranger, true);
        vm.prank(owner);
        vm.expectRevert(TrustPassport.OnlyEscrow.selector);
        passport.recordDispute(stranger);
    }

    function test_onTimeBps() public {
        vm.startPrank(address(escrow));
        passport.recordCompletion(seller, true);
        passport.recordCompletion(seller, true);
        passport.recordCompletion(seller, false);
        passport.recordCompletion(seller, true);
        passport.recordRefund(seller);
        passport.recordDispute(seller);
        vm.stopPrank();
        (uint256 c, uint256 d, uint256 r, uint256 bps, uint64 since) = passport.getPassport(seller);
        assertEq(c, 4);
        assertEq(d, 1);
        assertEq(r, 1);
        assertEq(bps, 7500);
        assertEq(since, block.timestamp);
    }

    function test_escrowSetOnce() public {
        vm.prank(owner);
        vm.expectRevert(TrustPassport.EscrowAlreadySet.selector);
        passport.setEscrow(owner);
        TrustPassport p2 = new TrustPassport(owner);
        vm.prank(owner);
        vm.expectRevert(TrustPassport.ZeroAddress.selector);
        p2.setEscrow(address(0));
        (uint256 c,,, uint256 bps, uint64 since) = p2.getPassport(stranger);
        assertEq(c + bps + since, 0);
    }
}
