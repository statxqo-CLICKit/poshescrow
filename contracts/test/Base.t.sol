// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FMNY} from "../src/FMNY.sol";
import {FMNYDistributor} from "../src/FMNYDistributor.sol";
import {ProofVault} from "../src/ProofVault.sol";
import {TrustPassport} from "../src/TrustPassport.sol";
import {FMNYRewards} from "../src/FMNYRewards.sol";
import {FMNYSale} from "../src/FMNYSale.sol";
import {PoshEscrow} from "../src/PoshEscrow.sol";
import {PoshProfiles} from "../src/PoshProfiles.sol";
import {MockUSDC, MockAggregator} from "./mocks/MockUSDC.sol";

abstract contract BaseTest is Test {
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address arbiter = makeAddr("arbiter"); // default arbiter
    address arbiter2 = makeAddr("arbiter2"); // approved custom arbiter
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address stranger = makeAddr("stranger");
    address team = makeAddr("team");
    address team2 = makeAddr("team2");
    address advisor = makeAddr("advisor");

    // rewards params (match script/Deploy.s.sol)
    uint256 constant REBATE_BPS = 2_500;
    uint256 constant PRICE = 1e13; // sale price & reference price floor
    uint256 constant MIN_DEAL = 0.01 ether;
    uint256 constant DAILY_CAP = 1_000 ether;
    uint256 constant LIFETIME_CAP = 50_000 ether;
    uint256 constant MAX_AGE = 1 hours;
    int256 constant ETH_USD = 3_000e8;

    FMNYDistributor dist;
    FMNY fmny;
    ProofVault vault;
    TrustPassport passport;
    FMNYRewards rewards;
    FMNYSale sale;
    PoshEscrow escrow;
    PoshProfiles profiles;
    MockUSDC usdc;
    MockAggregator feed;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        vm.roll(100);
        usdc = new MockUSDC();
        feed = new MockAggregator(8, ETH_USD);
        vm.startPrank(owner);
        dist = new FMNYDistributor(owner);
        fmny = dist.token();
        vault = new ProofVault(owner);
        passport = new TrustPassport(owner);
        rewards = new FMNYRewards(_rewardsConfig());
        escrow = new PoshEscrow(
            address(vault), address(passport), address(rewards), treasury, arbiter, address(usdc), owner
        );
        vault.setEscrow(address(escrow));
        passport.setEscrow(address(escrow));
        rewards.setEscrow(address(escrow));
        rewards.setGuardian(guardian);
        escrow.setGuardian(guardian);
        escrow.setArbiterApproved(arbiter2, true);
        sale = new FMNYSale(
            address(fmny),
            treasury,
            owner,
            PRICE,
            50 ether,
            150 ether,
            0.01 ether,
            5 ether,
            block.timestamp,
            30 days,
            90 days
        );
        sale.setGuardian(guardian);
        dist.distribute(address(rewards), address(sale), treasury, team, team2, advisor);
        profiles = new PoshProfiles();
        vm.stopPrank();

        vm.deal(buyer, 1000 ether);
        vm.deal(seller, 10 ether);
        usdc.mint(buyer, 1_000_000e6);
    }

    function _rewardsConfig() internal view returns (FMNYRewards.Config memory) {
        return FMNYRewards.Config({
            token: address(fmny),
            owner: owner,
            treasury: treasury,
            usdc: address(usdc),
            ethUsdFeed: address(feed),
            sequencerFeed: address(0),
            minEthUsd: 100e8,
            maxEthUsd: 100_000e8,
            floorPriceWei: PRICE,
            rebateBps: REBATE_BPS,
            refPriceWei: PRICE,
            minDealWei: MIN_DEAL,
            dailyCap: DAILY_CAP,
            lifetimeCap: LIFETIME_CAP,
            maxPriceAge: MAX_AGE
        });
    }

    /// @dev Expected total FMNY for an ETH-denominated fee at the deployed parameters (era 0).
    function _expectedTotal(uint256 feeWei) internal pure returns (uint256) {
        return (feeWei * REBATE_BPS * 1e18) / (10_000 * PRICE);
    }

    /// @dev ProofVault commit-reveal helper.
    function _file(address who, bytes32 h, string memory label) internal {
        bytes32 salt = keccak256(abi.encode(who, h));
        vm.prank(who);
        vault.commitFiling(vault.commitmentFor(h, who, salt));
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(who);
        vault.file(h, label, salt);
    }

    function _nextEpoch() internal {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        feed.set(ETH_USD, vm.getBlockTimestamp());
    }
}
