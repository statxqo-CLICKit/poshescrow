// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {PoshProfiles} from "../src/PoshProfiles.sol";

contract ProfilesTest is BaseTest {
    function test_registerAndViews() public {
        vm.expectEmit(true, false, false, true);
        emit PoshProfiles.ProfileRegistered(buyer, "posh_buyer1");
        vm.prank(buyer);
        profiles.register("posh_buyer1", "ipfs://meta");
        assertEq(profiles.usernameOf(buyer), "posh_buyer1");
        assertEq(profiles.ownerOfUsername("posh_buyer1"), buyer);
        (string memory u, string memory m, uint64 at) = profiles.profileOf(buyer);
        assertEq(u, "posh_buyer1");
        assertEq(m, "ipfs://meta");
        assertEq(at, block.timestamp);
    }

    function test_update() public {
        vm.prank(buyer);
        profiles.register("abc", "a");
        vm.expectEmit(true, false, false, false);
        emit PoshProfiles.ProfileUpdated(buyer);
        vm.prank(buyer);
        profiles.update("b");
        (, string memory m,) = profiles.profileOf(buyer);
        assertEq(m, "b");
    }

    function test_revertUpdateUnregistered() public {
        vm.prank(buyer);
        vm.expectRevert(PoshProfiles.NotRegistered.selector);
        profiles.update("x");
    }

    function test_uniqueAndOnePerAddress() public {
        vm.prank(buyer);
        profiles.register("alice", "");
        vm.prank(seller);
        vm.expectRevert(PoshProfiles.UsernameTaken.selector);
        profiles.register("alice", "");
        vm.prank(buyer);
        vm.expectRevert(PoshProfiles.AlreadyRegistered.selector);
        profiles.register("alice2", "");
    }

    function test_invalidUsernames() public {
        string[6] memory bad = ["ab", "abcdefghijklmnopqrstu", "Alice", "al-ice", "al ice", unicode"alicé"];
        for (uint256 i; i < bad.length; i++) {
            vm.prank(buyer);
            vm.expectRevert(PoshProfiles.InvalidUsername.selector);
            profiles.register(bad[i], "");
        }
        vm.prank(buyer);
        profiles.register("a_1234567890_abcdefg", ""); // exactly 20
        assertEq(profiles.ownerOfUsername("a_1234567890_abcdefg"), buyer);
    }
}
