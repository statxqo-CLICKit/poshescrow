// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ProofVault} from "../src/ProofVault.sol";

contract ProofVaultTest is BaseTest {
    bytes32 h = keccak256("doc");

    function test_fileAndRecord() public {
        bytes32 salt = bytes32("s");
        vm.prank(seller);
        vault.commitFiling(vault.commitmentFor(h, seller, salt));
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectEmit(true, true, false, true);
        emit ProofVault.Filed(h, seller, "Invoice #1");
        vm.prank(seller);
        vault.file(h, "Invoice #1", salt);
        (address o, uint64 at, string memory label, uint256 c) = vault.recordOf(h);
        assertEq(o, seller);
        assertEq(at, vm.getBlockTimestamp());
        assertEq(label, "Invoice #1");
        assertEq(c, 0);
        assertEq(vault.commitBlock(vault.commitmentFor(h, seller, salt)), 0); // consumed
    }

    function test_commitRevealRules() public {
        bytes32 salt = bytes32("s");
        bytes32 c = vault.commitmentFor(h, seller, salt);
        vm.prank(seller);
        vm.expectRevert(ProofVault.NoCommitment.selector);
        vault.file(h, "a", salt);
        vm.prank(seller);
        vault.commitFiling(c);
        vm.prank(seller);
        vm.expectRevert(ProofVault.AlreadyCommitted.selector);
        vault.commitFiling(c);
        vm.expectRevert(ProofVault.ZeroHash.selector);
        vault.commitFiling(bytes32(0));
        vm.prank(seller);
        vm.expectRevert(ProofVault.CommitTooFresh.selector);
        vault.file(h, "a", salt); // same block
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(seller);
        vm.expectRevert(ProofVault.CommitExpired.selector);
        vault.file(h, "a", salt);
    }

    function test_revertDoubleFile() public {
        _file(seller, h, "a");
        bytes32 salt = bytes32("b");
        vm.prank(buyer);
        vault.commitFiling(vault.commitmentFor(h, buyer, salt));
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(buyer);
        vm.expectRevert(ProofVault.AlreadyFiled.selector);
        vault.file(h, "b", salt);
    }

    function test_revertLabelTooLongAndZeroHash() public {
        vm.prank(seller);
        vm.expectRevert(ProofVault.LabelTooLong.selector);
        vault.file(h, "01234567890123456789012345678901234567890123456789012345678901234", bytes32(0)); // 65
        vm.prank(seller);
        vm.expectRevert(ProofVault.ZeroHash.selector);
        vault.file(bytes32(0), "x", bytes32(0));
    }

    function test_cosignRules() public {
        _file(seller, h, "a");
        vm.prank(seller);
        vm.expectRevert(ProofVault.OwnerCannotCosign.selector);
        vault.cosign(h);
        vm.prank(buyer);
        vault.cosign(h);
        vm.prank(buyer);
        vm.expectRevert(ProofVault.AlreadyCosigned.selector);
        vault.cosign(h);
        vm.prank(stranger);
        vault.cosign(h);
        (,,, uint256 c) = vault.recordOf(h);
        assertEq(c, 2);
        vm.expectRevert(ProofVault.NotFiled.selector);
        vault.cosign(keccak256("nope"));
    }

    function test_transferByOwnerAndAuth() public {
        _file(seller, h, "a");
        vm.prank(stranger);
        vm.expectRevert(ProofVault.NotAuthorized.selector);
        vault.transfer(h, stranger);
        vm.prank(seller);
        vm.expectRevert(ProofVault.ZeroAddress.selector);
        vault.transfer(h, address(0));
        vm.expectRevert(ProofVault.NotFiled.selector);
        vault.transfer(keccak256("none"), buyer);
        vm.prank(seller);
        vault.transfer(h, buyer);
        (address o,,,) = vault.recordOf(h);
        assertEq(o, buyer);
        vm.prank(address(escrow));
        vault.transfer(h, seller);
        (o,,,) = vault.recordOf(h);
        assertEq(o, seller);
    }

    function test_escrowSetOnceAndOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.setEscrow(stranger);
        vm.prank(owner);
        vm.expectRevert(ProofVault.EscrowAlreadySet.selector);
        vault.setEscrow(owner);
        ProofVault v2 = new ProofVault(owner);
        vm.prank(owner);
        vm.expectRevert(ProofVault.ZeroAddress.selector);
        v2.setEscrow(address(0));
    }
}
