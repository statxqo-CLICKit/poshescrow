// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {FMNY} from "../src/FMNY.sol";
import {FMNYDistributor} from "../src/FMNYDistributor.sol";
import {ProofVault} from "../src/ProofVault.sol";
import {TrustPassport} from "../src/TrustPassport.sol";
import {FMNYRewards} from "../src/FMNYRewards.sol";
import {FMNYSale} from "../src/FMNYSale.sol";
import {PoshEscrow} from "../src/PoshEscrow.sol";
import {MockUSDC, MockAggregator} from "./mocks/MockUSDC.sol";

contract DeployScriptTest is Test {
    address treasury = makeAddr("treasury");
    address arbiter = makeAddr("arbiter");
    address multisig = makeAddr("multisig");

    function setUp() public {
        vm.warp(1_750_000_000); // TimelockController treats timestamp 1 as "done"
    }

    function _cfg(address usdc, address feed) internal returns (Deploy.Config memory c) {
        c = Deploy.Config({
            treasury: treasury,
            arbiter: arbiter,
            usdc: usdc,
            team: makeAddr("team"),
            team2: makeAddr("team2"),
            advisor: makeAddr("advisor"),
            ownerMultisig: multisig,
            guardian: address(0),
            ethUsdFeed: feed,
            sequencerFeed: address(0),
            saleStart: block.timestamp + 1 days,
            adminDelay: 48 hours
        });
    }

    function test_deployWiresEverything() public {
        Deploy s = new Deploy();
        MockUSDC usdc = new MockUSDC();
        MockAggregator feed = new MockAggregator(8, 3000e8);
        Deploy.Deployed memory d = s.deploy(_cfg(address(usdc), address(feed)), address(s));

        assertEq(ProofVault(d.vault).escrow(), d.escrow);
        assertEq(TrustPassport(d.passport).escrow(), d.escrow);
        assertEq(FMNYRewards(d.rewards).escrow(), d.escrow);
        assertEq(FMNY(d.token).balanceOf(d.rewards), 40_000_000 ether);
        assertEq(FMNY(d.token).balanceOf(d.sale), 15_000_000 ether);
        assertEq(FMNY(d.token).balanceOf(treasury), 25_000_000 ether);
        assertEq(FMNY(d.token).balanceOf(d.teamVesting), 7_500_000 ether);
        assertEq(FMNY(d.token).balanceOf(d.teamVesting2), 7_500_000 ether);
        assertEq(FMNY(d.token).balanceOf(d.advisorVesting), 5_000_000 ether);
        PoshEscrow e = PoshEscrow(payable(d.escrow));
        assertTrue(e.allowedToken(address(usdc)));
        assertEq(e.defaultArbiter(), arbiter);
        assertEq(e.feeBps(), 100);
        assertEq(e.guardian(), multisig);
        assertTrue(d.profiles != address(0));

        // rewards parameters
        FMNYRewards r = FMNYRewards(d.rewards);
        assertEq(r.rebateBps(), 2_500);
        assertEq(r.refPriceWei(), 1e13);
        assertEq(r.floorPriceWei(), 1e13);
        assertEq(r.minDealWei(), 0.01 ether);
        assertEq(r.dailyCap(), 1_000 ether);
        assertEq(r.lifetimeCap(), 50_000 ether);
        assertEq(address(r.profiles()), d.profiles);
        assertEq(r.minProfileAge(), 3 days);
        assertEq(address(r.ethUsdFeed()), address(feed));

        // ownership: timelock owns admin contracts; powerless ones renounced; deployer keeps nothing
        assertEq(e.owner(), d.timelock);
        assertEq(r.owner(), d.timelock);
        assertEq(FMNYSale(payable(d.sale)).owner(), d.timelock);
        assertEq(ProofVault(d.vault).owner(), address(0));
        assertEq(TrustPassport(d.passport).owner(), address(0));
        assertEq(FMNYDistributor(d.distributor).owner(), address(0));
        TimelockController tl = TimelockController(payable(d.timelock));
        assertEq(tl.getMinDelay(), 48 hours);
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), multisig));
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), multisig));
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), multisig));
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), address(s)));
        assertFalse(tl.hasRole(tl.EXECUTOR_ROLE(), address(s)));
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(s)));

        // sale window
        FMNYSale sale = FMNYSale(payable(d.sale));
        assertEq(sale.startTime(), block.timestamp + 1 days);
        assertEq(sale.endTime(), block.timestamp + 31 days);
        assertEq(sale.guardian(), multisig);
    }

    function test_timelockedAdminChange() public {
        Deploy s = new Deploy();
        MockUSDC usdc = new MockUSDC();
        Deploy.Deployed memory d = s.deploy(_cfg(address(usdc), address(0)), address(s));
        TimelockController tl = TimelockController(payable(d.timelock));
        bytes memory call = abi.encodeCall(PoshEscrow.setFeeBps, (uint16(200)));
        vm.prank(multisig);
        tl.schedule(d.escrow, 0, call, bytes32(0), bytes32(0), 48 hours);
        vm.prank(multisig);
        vm.expectRevert();
        tl.execute(d.escrow, 0, call, bytes32(0), bytes32(0)); // too early
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        tl.execute(d.escrow, 0, call, bytes32(0), bytes32(0));
        assertEq(PoshEscrow(payable(d.escrow)).feeBps(), 200);
    }

    function test_deployRejectsDeployerAsOwner() public {
        Deploy s = new Deploy();
        Deploy.Config memory c = _cfg(address(new MockUSDC()), address(0));
        c.ownerMultisig = address(s);
        vm.expectRevert("OWNER_MULTISIG must not be the deployer EOA");
        s.deploy(c, address(s));
        c.ownerMultisig = address(0);
        vm.expectRevert("TREASURY/DEFAULT_ARBITER/OWNER_MULTISIG/TEAM/TEAM_2/ADVISOR required");
        s.deploy(c, address(s));
    }

    function test_deployRejectsSameTeamBeneficiaries() public {
        Deploy s = new Deploy();
        Deploy.Config memory c = _cfg(address(new MockUSDC()), address(0));
        c.team2 = c.team;
        vm.expectRevert("TEAM_BENEFICIARY and TEAM_2_BENEFICIARY must differ");
        s.deploy(c, address(s));
    }

    function test_runPrintsConfig() public {
        vm.etch(0x036CbD53842c5426634e7929541eC2318f3dCF7e, address(new MockUSDC()).code);
        vm.etch(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1, address(new MockAggregator(8, 3000e8)).code);
        vm.setEnv("TREASURY", vm.toString(treasury));
        vm.setEnv("DEFAULT_ARBITER", vm.toString(arbiter));
        vm.setEnv("OWNER_MULTISIG", vm.toString(multisig));
        vm.setEnv("TEAM_BENEFICIARY", vm.toString(makeAddr("team")));
        vm.setEnv("TEAM_2_BENEFICIARY", vm.toString(makeAddr("team2")));
        vm.setEnv("ADVISOR_BENEFICIARY", vm.toString(makeAddr("advisor")));
        vm.setEnv("SALE_START", vm.toString(block.timestamp + 1 hours));
        Deploy s = new Deploy();
        Deploy.Deployed memory d = s.run();
        assertTrue(d.escrow != address(0));
        assertTrue(d.timelock != address(0));
    }
}
