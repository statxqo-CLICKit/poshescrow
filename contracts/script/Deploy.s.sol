// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {FMNY} from "../src/FMNY.sol";
import {FMNYDistributor} from "../src/FMNYDistributor.sol";
import {ProofVault} from "../src/ProofVault.sol";
import {TrustPassport} from "../src/TrustPassport.sol";
import {FMNYRewards} from "../src/FMNYRewards.sol";
import {FMNYSale} from "../src/FMNYSale.sol";
import {PoshEscrow} from "../src/PoshEscrow.sol";
import {PoshProfiles} from "../src/PoshProfiles.sol";

/// @notice Deploys and wires the whole POSH stack (v0.2). Signer comes from the CLI
///         (--private-key $PRIVATE_KEY or --account <keystore>); this script never reads a key.
///         TESTNET ONLY (Base Sepolia, 84532) until audit and legal review are complete.
///
/// Ownership model (self-review M-3 / L-5):
///   - PoshEscrow, FMNYRewards and FMNYSale end up owned by an OpenZeppelin TimelockController with an
///     ADMIN_DELAY (default 48h). Only OWNER_MULTISIG can propose/cancel/execute; the deployer keeps no role.
///   - ProofVault and TrustPassport have their escrow set once, then ownership is renounced (no powers left).
///   - FMNYDistributor ownership is renounced after the one-time distribute().
///   - GUARDIAN (default OWNER_MULTISIG) can, without delay, only reduce risk: pause new escrow deals,
///     pause reward credits, pause sale buys / cancel the sale into refund mode, manage the sale allowlist.
///
/// Env (required): TREASURY, DEFAULT_ARBITER, OWNER_MULTISIG, TEAM_BENEFICIARY, TEAM_2_BENEFICIARY,
///   ADVISOR_BENEFICIARY (the two team beneficiaries share the 15% team allocation equally, 7.5% each)
/// Env (optional): GUARDIAN (default OWNER_MULTISIG), USDC (default Base Sepolia Circle USDC),
///   ETH_USD_FEED (default Chainlink Base Sepolia ETH/USD), SEQUENCER_FEED (default none; Base mainnet:
///   0xBCF85224fc0756B9Fa45aA7892530B47e10b6433), SALE_START (default 2026-10-25 09:00 PDT),
///   ADMIN_DELAY (default 172800 = 48h).
contract Deploy is Script {
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant BASE_SEPOLIA_ETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;

    // Rewards (see docs/REWARDS-ECONOMICS.md)
    uint256 constant REBATE_BPS = 2_500; // 25% of fee value at the reference price
    uint256 constant MIN_DEAL_WEI = 0.01 ether; // ETH-equivalent minimum deal size
    uint256 constant DAILY_CAP = 1_000 ether; // FMNY per wallet per UTC day
    uint256 constant LIFETIME_CAP = 50_000 ether; // FMNY per wallet, lifetime
    uint256 constant MAX_PRICE_AGE = 1 hours; // Chainlink staleness limit
    int256 constant MIN_ETH_USD = 100e8; // sanity band (8-decimals feed)
    int256 constant MAX_ETH_USD = 100_000e8;
    uint256 constant MIN_PROFILE_AGE = 3 days;

    // Sale
    uint256 constant PRICE = 1e13; // 0.00001 ETH per FMNY (also the rewards reference-price floor)
    uint256 constant SOFT_CAP = 50 ether;
    uint256 constant HARD_CAP = 150 ether;
    uint256 constant MIN_BUY = 0.01 ether;
    uint256 constant MAX_PER_WALLET = 5 ether;
    uint256 constant DEFAULT_SALE_START = 1_792_944_000; // Sun 2026-10-25 09:00 PDT (16:00 UTC)
    uint256 constant SALE_DURATION = 30 days;
    uint256 constant LOCK = 90 days;

    uint256 constant DEFAULT_ADMIN_DELAY = 48 hours;

    struct Config {
        address treasury;
        address arbiter;
        address usdc;
        address team;
        address team2;
        address advisor;
        address ownerMultisig;
        address guardian;
        address ethUsdFeed;
        address sequencerFeed;
        uint256 saleStart;
        uint256 adminDelay;
    }

    struct Deployed {
        address token;
        address distributor;
        address vault;
        address passport;
        address rewards;
        address escrow;
        address sale;
        address profiles;
        address teamVesting;
        address teamVesting2;
        address advisorVesting;
        address timelock;
    }

    function run() external returns (Deployed memory d) {
        Config memory c;
        c.treasury = vm.envAddress("TREASURY");
        c.arbiter = vm.envAddress("DEFAULT_ARBITER");
        c.ownerMultisig = vm.envAddress("OWNER_MULTISIG");
        c.team = vm.envAddress("TEAM_BENEFICIARY"); // L-8: no silent default to TREASURY
        c.team2 = vm.envAddress("TEAM_2_BENEFICIARY"); // Team 2 developer (7.5%)
        c.advisor = vm.envAddress("ADVISOR_BENEFICIARY");
        c.guardian = vm.envOr("GUARDIAN", c.ownerMultisig);
        c.usdc = vm.envOr("USDC", BASE_SEPOLIA_USDC);
        c.ethUsdFeed = vm.envOr("ETH_USD_FEED", BASE_SEPOLIA_ETH_USD);
        c.sequencerFeed = vm.envOr("SEQUENCER_FEED", address(0));
        c.saleStart = vm.envOr("SALE_START", DEFAULT_SALE_START);
        c.adminDelay = vm.envOr("ADMIN_DELAY", DEFAULT_ADMIN_DELAY);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        d = deploy(c, deployer);
        vm.stopBroadcast();

        _print(d, c);
    }

    function deploy(Config memory c, address deployer) public returns (Deployed memory d) {
        require(
            c.treasury != address(0) && c.arbiter != address(0) && c.ownerMultisig != address(0)
                && c.team != address(0) && c.team2 != address(0) && c.advisor != address(0),
            "TREASURY/DEFAULT_ARBITER/OWNER_MULTISIG/TEAM/TEAM_2/ADVISOR required"
        );
        require(c.team != c.team2, "TEAM_BENEFICIARY and TEAM_2_BENEFICIARY must differ");
        require(c.ownerMultisig != deployer, "OWNER_MULTISIG must not be the deployer EOA");
        if (c.guardian == address(0)) c.guardian = c.ownerMultisig;

        // 0. Timelock, bootstrapped with zero delay and the deployer as temporary sole proposer/executor/admin
        address[] memory boot = new address[](1);
        boot[0] = deployer;
        TimelockController tl = new TimelockController(0, boot, boot, deployer);
        d.timelock = address(tl);

        // 1. Distributor deploys FMNY and receives 100M
        FMNYDistributor dist = new FMNYDistributor(deployer);
        d.distributor = address(dist);
        d.token = address(dist.token());

        // 2. Core
        PoshProfiles profiles = new PoshProfiles();
        ProofVault vault = new ProofVault(deployer);
        TrustPassport passport = new TrustPassport(deployer);
        FMNYRewards rewards = new FMNYRewards(
            FMNYRewards.Config({
                token: d.token,
                owner: deployer,
                treasury: c.treasury,
                usdc: c.usdc,
                ethUsdFeed: c.ethUsdFeed,
                sequencerFeed: c.sequencerFeed,
                minEthUsd: MIN_ETH_USD,
                maxEthUsd: MAX_ETH_USD,
                floorPriceWei: PRICE,
                rebateBps: REBATE_BPS,
                refPriceWei: PRICE,
                minDealWei: MIN_DEAL_WEI,
                dailyCap: DAILY_CAP,
                lifetimeCap: LIFETIME_CAP,
                maxPriceAge: MAX_PRICE_AGE
            })
        );
        PoshEscrow escrow = new PoshEscrow(
            address(vault), address(passport), address(rewards), c.treasury, c.arbiter, c.usdc, deployer
        );

        // 3. Wire permissions (set-once writers)
        vault.setEscrow(address(escrow));
        passport.setEscrow(address(escrow));
        rewards.setEscrow(address(escrow));
        rewards.setProfiles(address(profiles), MIN_PROFILE_AGE);
        rewards.setGuardian(c.guardian);
        escrow.setGuardian(c.guardian);

        // 4. Sale
        FMNYSale sale = new FMNYSale(
            d.token,
            c.treasury,
            deployer,
            PRICE,
            SOFT_CAP,
            HARD_CAP,
            MIN_BUY,
            MAX_PER_WALLET,
            c.saleStart,
            SALE_DURATION,
            LOCK
        );
        sale.setGuardian(c.guardian);

        // 5. Genesis allocation (40/15/15+10/15/5; team 15% = 7.5% Team 1 + 7.5% Team 2)
        dist.distribute(address(rewards), address(sale), c.treasury, c.team, c.team2, c.advisor);

        // 6. Ownership: powerless contracts renounce; admin contracts go to the timelock (two-step)
        vault.renounceOwnership();
        passport.renounceOwnership();
        dist.renounceOwnership();
        _handToTimelock(tl, address(escrow), address(rewards), address(sale), c, deployer);

        d.vault = address(vault);
        d.passport = address(passport);
        d.rewards = address(rewards);
        d.escrow = address(escrow);
        d.sale = address(sale);
        d.profiles = address(profiles);
        d.teamVesting = dist.teamVesting();
        d.teamVesting2 = dist.teamVesting2();
        d.advisorVesting = dist.advisorVesting();
    }

    function _handToTimelock(
        TimelockController tl,
        address escrow,
        address rewards,
        address sale,
        Config memory c,
        address deployer
    ) private {
        PoshEscrow(payable(escrow)).transferOwnership(address(tl));
        FMNYRewards(rewards).transferOwnership(address(tl));
        FMNYSale(payable(sale)).transferOwnership(address(tl));

        address[] memory targets = new address[](4);
        uint256[] memory values = new uint256[](4);
        bytes[] memory payloads = new bytes[](4);
        targets[0] = escrow;
        targets[1] = rewards;
        targets[2] = sale;
        targets[3] = address(tl);
        bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
        payloads[0] = accept;
        payloads[1] = accept;
        payloads[2] = accept;
        payloads[3] = abi.encodeCall(TimelockController.updateDelay, (c.adminDelay));
        bytes32 salt = keccak256("posh-v0.2-bootstrap");
        tl.scheduleBatch(targets, values, payloads, bytes32(0), salt, 0);
        tl.executeBatch(targets, values, payloads, bytes32(0), salt);

        // hand the timelock to the multisig; the deployer keeps nothing
        tl.grantRole(tl.PROPOSER_ROLE(), c.ownerMultisig);
        tl.grantRole(tl.CANCELLER_ROLE(), c.ownerMultisig);
        tl.grantRole(tl.EXECUTOR_ROLE(), c.ownerMultisig);
        tl.revokeRole(tl.PROPOSER_ROLE(), deployer);
        tl.revokeRole(tl.CANCELLER_ROLE(), deployer);
        tl.revokeRole(tl.EXECUTOR_ROLE(), deployer);
        tl.renounceRole(tl.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _q(string memory k, address a, bool last) private pure returns (string memory) {
        return string.concat('  "', k, '": "', vm.toString(a), last ? '"\n' : '",\n');
    }

    function _print(Deployed memory d, Config memory c) private view {
        string memory json = string.concat(
            "{\n  \"chainId\": ",
            vm.toString(block.chainid),
            ",\n",
            _q("escrowAddress", d.escrow, false),
            _q("vaultAddress", d.vault, false),
            _q("passportAddress", d.passport, false),
            _q("tokenAddress", d.token, false),
            _q("rewardsAddress", d.rewards, false),
            _q("saleAddress", d.sale, false),
            _q("profilesAddress", d.profiles, false)
        );
        json = string.concat(
            json,
            _q("usdcAddress", c.usdc, false),
            _q("treasuryAddress", c.treasury, false),
            _q("defaultArbiter", c.arbiter, false),
            _q("distributorAddress", d.distributor, false),
            _q("teamVestingAddress", d.teamVesting, false),
            _q("teamVesting2Address", d.teamVesting2, false),
            _q("advisorVestingAddress", d.advisorVesting, false),
            _q("timelockAddress", d.timelock, false),
            _q("ownerMultisig", c.ownerMultisig, false),
            _q("guardianAddress", c.guardian, false),
            _q("ethUsdFeed", c.ethUsdFeed, true),
            "}"
        );
        console2.log("===== POSH CONFIG (paste into the front end) =====");
        console2.log(json);
        console2.log("===== END CONFIG =====");
        console2.log("saleStart (unix):", c.saleStart);
        console2.log("adminDelay (s):", c.adminDelay);
    }
}
