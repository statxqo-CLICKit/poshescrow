// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {FMNY} from "./FMNY.sol";

/// @title FMNYDistributor
/// @notice Deploys FMNY (receiving the full supply) and performs the one-time genesis allocation:
///         40% Rewards, 15% Sale, 15% Treasury multisig, 10% Liquidity (to the same multisig),
///         15% Team vesting split equally between two developer beneficiaries (7.5% each, two
///         VestingWallets with the same 12-month cliff, then 24 months linear),
///         5% Advisor vesting (6-month cliff, then 18 months linear).
/// @dev "Cliff then linear" is implemented with OZ VestingWallet whose start = deploy + cliff and
///      duration = linear period, so nothing vests before the cliff and vesting is linear after it.
contract FMNYDistributor is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant REWARDS_BPS = 4000;
    uint256 public constant SALE_BPS = 1500;
    uint256 public constant TREASURY_BPS = 1500;
    uint256 public constant TEAM_BPS = 1500;
    uint256 public constant LIQUIDITY_BPS = 1000;
    uint256 public constant ADVISOR_BPS = 500;

    uint64 public constant TEAM_CLIFF = 365 days;
    uint64 public constant TEAM_LINEAR = 730 days;
    uint64 public constant ADVISOR_CLIFF = 182 days;
    uint64 public constant ADVISOR_LINEAR = 547 days;

    FMNY public immutable token;
    bool public distributed;
    address public teamVesting; // Team 1 (7.5%)
    address public teamVesting2; // Team 2 (7.5%)
    address public advisorVesting;

    event Distributed(
        address indexed rewards,
        address indexed sale,
        address indexed treasury,
        address teamVesting,
        address teamVesting2,
        address advisorVesting
    );

    error AlreadyDistributed();
    error ZeroAddress();
    error DuplicateTeamBeneficiary();

    constructor(address owner_) Ownable(owner_) {
        token = new FMNY(address(this));
    }

    function distribute(
        address rewards,
        address sale,
        address treasuryMultisig,
        address teamBeneficiary,
        address teamBeneficiary2,
        address advisorBeneficiary
    ) external onlyOwner {
        if (distributed) revert AlreadyDistributed();
        if (
            rewards == address(0) || sale == address(0) || treasuryMultisig == address(0)
                || teamBeneficiary == address(0) || teamBeneficiary2 == address(0)
                || advisorBeneficiary == address(0)
        ) revert ZeroAddress();
        if (teamBeneficiary == teamBeneficiary2) revert DuplicateTeamBeneficiary();
        distributed = true;

        uint256 total = token.TOTAL_SUPPLY();
        uint64 nowTs = uint64(block.timestamp);

        teamVesting = address(new VestingWallet(teamBeneficiary, nowTs + TEAM_CLIFF, TEAM_LINEAR));
        teamVesting2 = address(new VestingWallet(teamBeneficiary2, nowTs + TEAM_CLIFF, TEAM_LINEAR));
        advisorVesting = address(new VestingWallet(advisorBeneficiary, nowTs + ADVISOR_CLIFF, ADVISOR_LINEAR));

        IERC20 t = IERC20(address(token));
        t.safeTransfer(rewards, total * REWARDS_BPS / 10_000);
        t.safeTransfer(sale, total * SALE_BPS / 10_000);
        t.safeTransfer(treasuryMultisig, total * (TREASURY_BPS + LIQUIDITY_BPS) / 10_000);
        uint256 teamTotal = total * TEAM_BPS / 10_000; // exactly 15%
        uint256 team1 = teamTotal / 2;
        t.safeTransfer(teamVesting, team1);
        t.safeTransfer(teamVesting2, teamTotal - team1);
        t.safeTransfer(advisorVesting, total * ADVISOR_BPS / 10_000);

        emit Distributed(rewards, sale, treasuryMultisig, teamVesting, teamVesting2, advisorVesting);
    }
}
