// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {FMNYRewards} from "../src/FMNYRewards.sol";
import {MockAggregator} from "./mocks/MockUSDC.sol";

contract RewardsTest is BaseTest {
    function _notify(address b, address s, address tok, uint256 fee, uint256 amount) internal {
        vm.prank(address(escrow));
        rewards.notifyDeal(b, s, tok, fee, amount);
    }

    function _notifyEth(uint256 amount) internal {
        _notify(buyer, seller, address(0), amount / 100, amount);
    }

    function _w(uint256 i) internal pure returns (address) {
        return address(uint160(0xA000 + i));
    }

    function test_onlyEscrow() public {
        vm.prank(stranger);
        vm.expectRevert(FMNYRewards.OnlyEscrow.selector);
        rewards.notifyDeal(buyer, seller, address(0), 1 ether, 100 ether);
    }

    function test_ethRebateMathSplitAndDelayedClaim() public {
        _notifyEth(1 ether); // fee 0.01 ETH
        assertEq(rewards.earned(buyer), 125 ether);
        assertEq(rewards.earned(seller), 125 ether);
        assertEq(rewards.locked(buyer), 125 ether);
        assertEq(rewards.claimable(buyer), 0);
        vm.prank(buyer);
        vm.expectRevert(FMNYRewards.NothingToClaim.selector);
        rewards.claim();
        _nextEpoch();
        assertEq(rewards.claimable(buyer), 125 ether);
        vm.prank(buyer);
        rewards.claim();
        assertEq(fmny.balanceOf(buyer), 125 ether);
        assertEq(rewards.claimable(buyer), 0);
        assertEq(rewards.totalOwed(), 125 ether);
    }

    /// Value of the reward at the reference price is exactly rebateBps of the fee (25%).
    function testFuzz_rewardValueNeverExceedsRebateOfFee(uint256 amount) public {
        amount = bound(amount, MIN_DEAL, 3 ether); // stays under per-user daily cap
        uint256 fee = amount / 100;
        _notify(buyer, seller, address(0), fee, amount);
        uint256 total = rewards.earned(buyer) + rewards.earned(seller);
        // value in wei at the reference price
        uint256 valueWei = (total * PRICE) / 1e18;
        assertLe(valueWei * 10_000, fee * REBATE_BPS);
        assertLe(valueWei * 10_000, fee * rewards.MAX_REBATE_BPS());
    }

    function test_usdcValuedViaOracle() public {
        // 1,000 USDC deal, 10 USDC fee, ETH = $3,000 -> fee = 0.0033 ETH -> 83.33 FMNY
        _notify(buyer, seller, address(usdc), 10e6, 1000e6);
        uint256 total = rewards.earned(buyer) + rewards.earned(seller);
        assertApproxEqAbs(total, 83.333 ether, 0.001 ether);
        // same USD value paid in ETH earns the same (pair already rewarded this epoch, so use new wallets)
        uint256 tenUsd = uint256(10 ether) / 3000;
        _notify(_w(1), _w(2), address(0), tenUsd, tenUsd * 100);
        assertApproxEqAbs(rewards.earned(_w(1)) + rewards.earned(_w(2)), total, 1e6);
    }

    function test_usdcFailsClosedOnBadPrice() public {
        // stale
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _notify(buyer, seller, address(usdc), 10e6, 1000e6);
        assertEq(rewards.earned(buyer), 0);
        (,, FMNYRewards.Skip r,) = rewards.previewDeal(buyer, seller, address(usdc), 10e6, 1000e6);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.PriceUnavailable));
        // out of band (too low / too high)
        feed.set(50e8, vm.getBlockTimestamp());
        (,, r,) = rewards.previewDeal(buyer, seller, address(usdc), 10e6, 1000e6);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.PriceUnavailable));
        feed.set(200_000e8, vm.getBlockTimestamp());
        (,, r,) = rewards.previewDeal(buyer, seller, address(usdc), 10e6, 1000e6);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.PriceUnavailable));
        // future timestamp
        feed.set(ETH_USD, vm.getBlockTimestamp() + 1);
        (,, r,) = rewards.previewDeal(buyer, seller, address(usdc), 10e6, 1000e6);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.PriceUnavailable));
        // feed reverts
        feed.set(ETH_USD, vm.getBlockTimestamp());
        feed.setBroken(true);
        (bool ok,) = rewards.ethUsdPrice();
        assertFalse(ok);
        feed.setBroken(false);
        (ok,) = rewards.ethUsdPrice();
        assertTrue(ok);
        // ETH path needs no oracle
        feed.setBroken(true);
        _notifyEth(1 ether);
        assertEq(rewards.earned(buyer), 125 ether);
    }

    function test_sequencerUptimeCheck() public {
        MockAggregator seq = new MockAggregator(0, 0);
        FMNYRewards.Config memory c = _rewardsConfig();
        c.sequencerFeed = address(seq);
        FMNYRewards r2 = new FMNYRewards(c);
        (bool ok,) = r2.ethUsdPrice();
        assertFalse(ok); // inside grace period after (re)start
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        feed.set(ETH_USD, vm.getBlockTimestamp());
        (ok,) = r2.ethUsdPrice();
        assertTrue(ok);
        seq.set(1, vm.getBlockTimestamp()); // sequencer down
        (ok,) = r2.ethUsdPrice();
        assertFalse(ok);
        seq.set(0, vm.getBlockTimestamp());
        seq.setBroken(true);
        (ok,) = r2.ethUsdPrice();
        assertFalse(ok);
    }

    function test_noFeedMeansNoUsdcRewards() public {
        FMNYRewards.Config memory c = _rewardsConfig();
        c.ethUsdFeed = address(0);
        FMNYRewards r2 = new FMNYRewards(c);
        (bool ok,) = r2.ethUsdPrice();
        assertFalse(ok);
        (bool vok,) = r2.valueInWei(address(usdc), 1e6);
        assertFalse(vok);
    }

    function test_skipReasons() public {
        (,, FMNYRewards.Skip r,) = rewards.previewDeal(buyer, seller, address(0), 0, 1 ether);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.NoFee));
        (,, r,) = rewards.previewDeal(buyer, buyer, address(0), 1e16, 1 ether);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.SameWallet));
        (,, r,) = rewards.previewDeal(buyer, seller, address(fmny), 1e16, 1 ether);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.UnsupportedToken));
        (,, r,) = rewards.previewDeal(buyer, seller, address(0), 0.0099 ether / 100, 0.0099 ether);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.BelowMinDeal));
        _notifyEth(1 ether);
        _notifyEth(1 ether); // same pair, same epoch
        assertEq(rewards.earned(buyer), 125 ether);
        (,, r,) = rewards.previewDeal(seller, buyer, address(0), 1e16, 1 ether); // order-independent
        assertEq(uint8(r), uint8(FMNYRewards.Skip.PairAlreadyRewarded));
        _nextEpoch();
        _notifyEth(1 ether);
        assertEq(rewards.earned(buyer), 250 ether);
    }

    function test_dailyAndLifetimeCaps() public {
        // 100 ETH deal -> 25,000 FMNY total -> capped at 1,000 per wallet per day
        _notifyEth(100 ether);
        assertEq(rewards.earned(buyer), DAILY_CAP);
        _notify(buyer, _w(1), address(0), 1 ether, 100 ether);
        assertEq(rewards.earned(buyer), DAILY_CAP); // daily cap holds across counterparties
        assertEq(rewards.earned(_w(1)), DAILY_CAP);
        // lifetime: lower caps to make it quick
        vm.prank(owner);
        rewards.setParams(REBATE_BPS, PRICE, MIN_DEAL, 1_000 ether, 1_500 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _notify(buyer, _w(2), address(0), 1 ether, 100 ether);
        assertEq(rewards.earned(buyer), 1_500 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _notify(buyer, _w(3), address(0), 1 ether, 100 ether);
        assertEq(rewards.earned(buyer), 1_500 ether);
        assertEq(rewards.earned(_w(3)), 1_000 ether);
    }

    function test_epochBudgetEnforcedAcrossSybils() public {
        // raise per-user caps to the max so only the global budget binds
        vm.prank(owner);
        rewards.setParams(5_000, PRICE, MIN_DEAL, 10_000 ether, 250_000 ether);
        uint256 budget = rewards.epochBudget(0);
        for (uint256 i; i < 20; ++i) {
            _notify(_w(2 * i), _w(2 * i + 1), address(0), 1 ether, 100 ether); // 50k FMNY each, capped 10k+10k
        }
        assertEq(rewards.emittedInEpoch(0), budget);
        assertEq(rewards.totalEmitted(), budget);
        (,, FMNYRewards.Skip r,) = rewards.previewDeal(_w(100), _w(101), address(0), 1 ether, 100 ether);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.CapReached));
        _nextEpoch();
        _notify(_w(100), _w(101), address(0), 1 ether, 100 ether);
        assertEq(rewards.emittedInEpoch(1), 20_000 ether);
    }

    function test_scheduleHalvesAndSumsBelowPool() public view {
        assertEq(rewards.epochBudget(0), 180_000 ether);
        assertEq(rewards.epochBudget(103), 180_000 ether);
        assertEq(rewards.epochBudget(104), 90_000 ether);
        assertEq(rewards.epochBudget(208), 45_000 ether);
        assertEq(rewards.epochBudget(104 * 64), 0);
        uint256 sum;
        for (uint256 era; era < 64; ++era) {
            sum += rewards.epochBudget(era * 104) * 104;
        }
        assertLt(sum, 40_000_000 ether);
        assertApproxEqAbs(sum, 37_440_000 ether, 1 ether);
    }

    function test_rebateHalvesPerEra() public {
        assertEq(rewards.currentRebateBps(), 2_500);
        vm.warp(vm.getBlockTimestamp() + 104 * 7 days);
        assertEq(rewards.currentEpoch(), 104);
        assertEq(rewards.currentRebateBps(), 1_250);
        _notifyEth(1 ether);
        assertEq(rewards.earned(buyer), 62.5 ether);
        vm.warp(vm.getBlockTimestamp() + 64 * 104 * 7 days);
        assertEq(rewards.currentRebateBps(), 0);
    }

    function test_profileRequirement() public {
        vm.prank(owner);
        rewards.setProfiles(address(profiles), 3 days);
        (,, FMNYRewards.Skip r,) = rewards.previewDeal(buyer, seller, address(0), 1e16, 1 ether);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.NoProfile));
        vm.prank(buyer);
        profiles.register("buyer_one", "");
        vm.prank(seller);
        profiles.register("seller_one", "");
        (,, r,) = rewards.previewDeal(buyer, seller, address(0), 1e16, 1 ether);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.NoProfile)); // too young
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _notifyEth(1 ether);
        assertEq(rewards.earned(buyer), 125 ether);
        // a reverting profiles contract fails closed
        vm.prank(owner);
        rewards.setProfiles(address(fmny), 0);
        (,, r,) = rewards.previewDeal(_w(1), _w(2), address(0), 1e16, 1 ether);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.NoProfile));
        vm.prank(owner);
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        rewards.setProfiles(address(profiles), 31 days);
    }

    function test_paramBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        rewards.setParams(5_001, PRICE, MIN_DEAL, DAILY_CAP, LIFETIME_CAP); // > 50% rebate
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        rewards.setParams(REBATE_BPS, PRICE - 1, MIN_DEAL, DAILY_CAP, LIFETIME_CAP); // ref below sale price
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        rewards.setParams(REBATE_BPS, PRICE, 0.0009 ether, DAILY_CAP, LIFETIME_CAP);
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        rewards.setParams(REBATE_BPS, PRICE, 11 ether, DAILY_CAP, LIFETIME_CAP);
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        rewards.setParams(REBATE_BPS, PRICE, MIN_DEAL, 10_001 ether, LIFETIME_CAP);
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        rewards.setParams(REBATE_BPS, PRICE, MIN_DEAL, DAILY_CAP, 250_001 ether);
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        rewards.setParams(REBATE_BPS, PRICE, MIN_DEAL, 2_000 ether, 1_000 ether);
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        rewards.setMaxPriceAge(59);
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        rewards.setMaxPriceAge(1 days + 1);
        rewards.setMaxPriceAge(2 hours);
        // raising the reference price is always allowed and lowers rewards
        rewards.setParams(REBATE_BPS, PRICE * 2, MIN_DEAL, DAILY_CAP, LIFETIME_CAP);
        vm.stopPrank();
        _notifyEth(1 ether);
        assertEq(rewards.earned(buyer), 62.5 ether);
    }

    function test_constructorBounds() public {
        FMNYRewards.Config memory c = _rewardsConfig();
        c.token = address(0);
        vm.expectRevert(FMNYRewards.ZeroAddress.selector);
        new FMNYRewards(c);
        c = _rewardsConfig();
        c.floorPriceWei = 0;
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        new FMNYRewards(c);
        c = _rewardsConfig();
        c.maxEthUsd = c.minEthUsd;
        vm.expectRevert(FMNYRewards.OutOfBounds.selector);
        new FMNYRewards(c);
        c = _rewardsConfig();
        c.usdc = address(0);
        FMNYRewards r2 = new FMNYRewards(c);
        (bool ok,) = r2.valueInWei(address(usdc), 1e6);
        assertFalse(ok);
    }

    function test_escrowSetOnce() public {
        vm.prank(owner);
        vm.expectRevert(FMNYRewards.EscrowAlreadySet.selector);
        rewards.setEscrow(stranger);
        FMNYRewards r2 = new FMNYRewards(_rewardsConfig());
        vm.prank(owner);
        vm.expectRevert(FMNYRewards.ZeroAddress.selector);
        r2.setEscrow(address(0));
        vm.prank(stranger);
        vm.expectRevert(FMNYRewards.OnlyEscrow.selector);
        r2.notifyDeal(buyer, seller, address(0), 1, 1); // escrow unset
    }

    function test_pauseGuardianAndEnd() public {
        vm.prank(stranger);
        vm.expectRevert(FMNYRewards.NotAuthorized.selector);
        rewards.setPaused(true);
        vm.prank(guardian);
        rewards.setPaused(true);
        _notifyEth(1 ether);
        assertEq(rewards.earned(buyer), 0);
        vm.prank(guardian);
        vm.expectRevert(FMNYRewards.NotAuthorized.selector);
        rewards.setPaused(false);
        vm.prank(owner);
        rewards.setPaused(false);
        _notifyEth(1 ether);
        assertEq(rewards.earned(buyer), 125 ether);
        uint256 t0 = fmny.balanceOf(treasury);
        vm.prank(stranger);
        vm.expectRevert();
        rewards.endRewards();
        vm.prank(owner);
        rewards.endRewards();
        assertEq(fmny.balanceOf(treasury) - t0, 40_000_000 ether - 250 ether);
        vm.prank(owner);
        vm.expectRevert(FMNYRewards.AlreadyEnded.selector);
        rewards.endRewards();
        (,, FMNYRewards.Skip r,) = rewards.previewDeal(_w(1), _w(2), address(0), 1e16, 1 ether);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.Ended));
        _nextEpoch();
        vm.prank(seller);
        rewards.claim(); // earned stays claimable after end
        assertEq(fmny.balanceOf(seller), 125 ether);
    }

    function test_poolLimitProRata() public {
        // drain pool artificially by ending is not possible; instead use a fresh rewards with a tiny pool
        FMNYRewards r2 = new FMNYRewards(_rewardsConfig());
        vm.prank(owner);
        r2.setEscrow(address(this));
        vm.prank(treasury);
        fmny.transfer(address(r2), 100 ether);
        r2.notifyDeal(buyer, seller, address(0), 1e16, 1 ether); // wants 250, pool has 100
        assertEq(r2.earned(buyer) + r2.earned(seller), 100 ether);
        assertEq(r2.remainingPool(), 0);
        (,, FMNYRewards.Skip r,) = r2.previewDeal(_w(1), _w(2), address(0), 1e16, 1 ether);
        assertEq(uint8(r), uint8(FMNYRewards.Skip.CapReached));
    }
}
