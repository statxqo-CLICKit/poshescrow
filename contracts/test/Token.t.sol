// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {FMNYDistributor} from "../src/FMNYDistributor.sol";

contract TokenTest is BaseTest {
    function test_metadataAndSupply() public view {
        assertEq(fmny.name(), "FMoney Protocol");
        assertEq(fmny.symbol(), "FMNY");
        assertEq(fmny.decimals(), 18);
        assertEq(fmny.totalSupply(), 100_000_000 ether);
    }

    function test_allocation() public view {
        assertEq(fmny.balanceOf(address(rewards)), 40_000_000 ether);
        assertEq(fmny.balanceOf(address(sale)), 15_000_000 ether);
        assertEq(fmny.balanceOf(treasury), 25_000_000 ether); // 15% treasury + 10% liquidity
        assertEq(fmny.balanceOf(dist.teamVesting()), 7_500_000 ether);
        assertEq(fmny.balanceOf(dist.teamVesting2()), 7_500_000 ether);
        assertEq(fmny.balanceOf(dist.advisorVesting()), 5_000_000 ether);
        assertEq(fmny.balanceOf(address(dist)), 0);
    }

    function test_distributeOnlyOnce() public {
        vm.prank(owner);
        vm.expectRevert(FMNYDistributor.AlreadyDistributed.selector);
        dist.distribute(address(rewards), address(sale), treasury, team, team2, advisor);
    }

    function test_teamVestingCliffThenLinear() public {
        VestingWallet w = VestingWallet(payable(dist.teamVesting()));
        assertEq(w.owner(), team);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 365 days - 1);
        assertEq(w.releasable(address(fmny)), 0);
        vm.warp(t0 + 365 days + 365 days); // cliff + 12 of 24 months
        assertEq(w.releasable(address(fmny)), 3_750_000 ether);
        vm.warp(t0 + 365 days + 730 days);
        w.release(address(fmny));
        assertEq(fmny.balanceOf(team), 7_500_000 ether);
    }

    /// Team split: two developer beneficiaries share the 15% team allocation equally,
    /// on identical cliff + linear schedules; total stays exactly 15%.
    function test_teamSplitEqualSameSchedule() public {
        VestingWallet w1 = VestingWallet(payable(dist.teamVesting()));
        VestingWallet w2 = VestingWallet(payable(dist.teamVesting2()));
        assertTrue(address(w1) != address(w2));
        assertEq(w1.owner(), team);
        assertEq(w2.owner(), team2);
        assertEq(w1.start(), w2.start());
        assertEq(w1.duration(), w2.duration());
        assertEq(w1.duration(), 730 days);
        assertEq(fmny.balanceOf(address(w1)) + fmny.balanceOf(address(w2)), fmny.totalSupply() * 1500 / 10_000);
        assertEq(fmny.balanceOf(address(w1)), fmny.balanceOf(address(w2)));

        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 365 days - 1);
        assertEq(w1.releasable(address(fmny)), 0);
        assertEq(w2.releasable(address(fmny)), 0);
        vm.warp(t0 + 365 days + 730 days);
        w1.release(address(fmny));
        w2.release(address(fmny));
        assertEq(fmny.balanceOf(team), 7_500_000 ether);
        assertEq(fmny.balanceOf(team2), 7_500_000 ether);
    }

    function test_distributeRejectsDuplicateOrZeroTeam() public {
        vm.startPrank(owner);
        FMNYDistributor d2 = new FMNYDistributor(owner);
        vm.expectRevert(FMNYDistributor.DuplicateTeamBeneficiary.selector);
        d2.distribute(address(rewards), address(sale), treasury, team, team, advisor);
        vm.expectRevert(FMNYDistributor.ZeroAddress.selector);
        d2.distribute(address(rewards), address(sale), treasury, team, address(0), advisor);
        vm.stopPrank();
    }

    function test_advisorVestingCliff() public {
        VestingWallet w = VestingWallet(payable(dist.advisorVesting()));
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 182 days - 1);
        assertEq(w.releasable(address(fmny)), 0);
        vm.warp(t0 + 182 days + 547 days);
        w.release(address(fmny));
        assertEq(fmny.balanceOf(advisor), 5_000_000 ether);
    }
}
