// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFMNYRewards, IAggregatorV3, IPoshProfiles} from "./interfaces/IPosh.sol";

/// @title FMNYRewards (v0.2, fee-rebate model)
/// @notice Holds the 40M FMNY rewards pool. PoshEscrow notifies it when an undisputed deal is RELEASED
///         to the seller and a protocol fee was charged. The reward is a REBATE of part of the fee:
///
///             feeWei      = fee valued in ETH-wei (ETH: as is; USDC: via Chainlink ETH/USD)
///             reward FMNY = feeWei * rebateBps(era) / 10_000 * 1e18 / refPriceWei
///
///         split 50/50 between buyer and seller. `refPriceWei` (wei per FMNY) can never be set below
///         `floorPriceWei` (the pre-sale price), and `rebateBps` can never exceed 50% (deployed at 25%), so at
///         the sale price a reward is always worth at most 50% (deployed: 25%) of the fee that paid for it.
///
///         Hard emission limits enforced on every credit, whatever the parameters:
///         - global budget per 7-day epoch: BASE_EPOCH_BUDGET, halving every 104 epochs (~2 years);
///           the sum of all budgets is 37.44M FMNY < 40M pool, so the schedule can never empty the pool;
///         - per-address daily cap and lifetime cap;
///         - the same buyer/seller pair is rewarded at most once per epoch;
///         - minimum deal size (ETH-equivalent);
///         - optional: both wallets must hold a PoshProfiles profile at least `minProfileAge` old;
///         - rewards earned in an epoch become claimable when that epoch ends (settlement delay).
/// @dev notifyDeal never reverts for business reasons; it emits RewardSkipped instead, so it can never
///      block an escrow payout (escrow also wraps the call in try/catch).
///      Oracle choice: Chainlink ETH/USD with staleness, sanity-band and optional L2 sequencer-uptime checks,
///      failing CLOSED (a USDC deal earns nothing while the price is unusable). ETH-paid fees need no oracle
///      because the reference price is denominated in ETH. See docs/REWARDS-ECONOMICS.md.
contract FMNYRewards is Ownable2Step, ReentrancyGuard, IFMNYRewards {
    using SafeERC20 for IERC20;

    // ---------------- immutable schedule & hard bounds ----------------
    uint256 public constant EPOCH = 7 days;
    uint256 public constant EPOCHS_PER_ERA = 104; // ~2 years
    uint256 public constant BASE_EPOCH_BUDGET = 180_000 ether; // era 0, per epoch
    uint256 public constant MAX_ERAS = 64;
    uint256 public constant MAX_REBATE_BPS = 5_000; // 50% of fee value, hard ceiling
    uint256 public constant MAX_DAILY_CAP = 10_000 ether;
    uint256 public constant MAX_LIFETIME_CAP = 250_000 ether;
    uint256 public constant MIN_DEAL_LOWER = 0.001 ether;
    uint256 public constant MIN_DEAL_UPPER = 10 ether;
    uint256 public constant PRICE_AGE_LOWER = 60;
    uint256 public constant PRICE_AGE_UPPER = 1 days;
    uint256 public constant SEQUENCER_GRACE = 1 hours;
    uint256 public constant MAX_PROFILE_AGE = 30 days;

    enum Skip {
        None,
        Paused,
        Ended,
        NoFee,
        SameWallet,
        UnsupportedToken,
        PriceUnavailable,
        BelowMinDeal,
        NoProfile,
        PairAlreadyRewarded,
        CapReached
    }

    struct Config {
        address token; // FMNY
        address owner;
        address treasury; // receives the unallocated pool if rewards are ended
        address usdc; // the only ERC20 valued for rewards (address(0) = none)
        address ethUsdFeed; // Chainlink ETH/USD (address(0) = USDC deals earn nothing)
        address sequencerFeed; // Chainlink L2 sequencer uptime feed (address(0) = skip check, e.g. Base Sepolia)
        int256 minEthUsd; // sanity band, in feed decimals
        int256 maxEthUsd;
        uint256 floorPriceWei; // wei per FMNY that refPriceWei can never go below (sale price)
        uint256 rebateBps;
        uint256 refPriceWei;
        uint256 minDealWei;
        uint256 dailyCap;
        uint256 lifetimeCap;
        uint256 maxPriceAge;
    }

    IERC20 public immutable token;
    address public immutable treasury;
    address public immutable usdc;
    uint8 public immutable usdcDecimals;
    IAggregatorV3 public immutable ethUsdFeed;
    uint8 public immutable feedDecimals;
    IAggregatorV3 public immutable sequencerFeed;
    int256 public immutable minEthUsd;
    int256 public immutable maxEthUsd;
    uint256 public immutable floorPriceWei;
    uint256 public immutable startTime;

    // ---------------- bounded parameters ----------------
    address public escrow; // set once
    address public guardian; // may pause (never unpause)
    IPoshProfiles public profiles; // optional
    uint256 public minProfileAge;
    uint256 public rebateBps;
    uint256 public refPriceWei;
    uint256 public minDealWei;
    uint256 public dailyCap;
    uint256 public lifetimeCap;
    uint256 public maxPriceAge;
    bool public paused;
    bool public ended;

    // ---------------- accounting ----------------
    uint256 public totalOwed; // earned but not yet claimed
    uint256 public totalEmitted; // lifetime credited
    mapping(uint256 => uint256) public emittedInEpoch;
    mapping(address => uint256) public earned; // lifetime earned
    mapping(address => uint256) public claimed; // lifetime claimed
    mapping(address => mapping(uint256 => uint256)) public earnedOnDay; // user => day => amount
    mapping(bytes32 => uint256) public pairLastEpoch; // pair key => epoch + 1 it was last rewarded in
    mapping(address => uint256) public pendingAmount; // earned in `pendingEpoch`, locked until it ends
    mapping(address => uint256) public pendingEpoch;

    event EscrowSet(address indexed escrow);
    event GuardianSet(address indexed guardian);
    event ProfilesSet(address indexed profiles, uint256 minProfileAge);
    event ParamsSet(uint256 rebateBps, uint256 refPriceWei, uint256 minDealWei, uint256 dailyCap, uint256 lifetimeCap);
    event MaxPriceAgeSet(uint256 maxPriceAge);
    event PausedSet(bool paused, address indexed by);
    event RewardsEnded(address indexed to, uint256 swept);
    event Rewarded(
        address indexed buyer,
        address indexed seller,
        address indexed token,
        uint256 fee,
        uint256 feeWei,
        uint256 buyerReward,
        uint256 sellerReward
    );
    event RewardSkipped(address indexed buyer, address indexed seller, Skip reason);
    event Claimed(address indexed user, uint256 amount);

    error OnlyEscrow();
    error NothingToClaim();
    error AlreadyEnded();
    error ZeroAddress();
    error EscrowAlreadySet();
    error OutOfBounds();
    error NotAuthorized();

    constructor(Config memory c) Ownable(c.owner) {
        if (c.token == address(0) || c.treasury == address(0)) revert ZeroAddress();
        if (c.floorPriceWei == 0 || c.minEthUsd <= 0 || c.maxEthUsd <= c.minEthUsd) revert OutOfBounds();
        token = IERC20(c.token);
        treasury = c.treasury;
        usdc = c.usdc;
        usdcDecimals = c.usdc == address(0) ? 0 : IERC20Metadata(c.usdc).decimals();
        if (usdcDecimals > 18) revert OutOfBounds();
        ethUsdFeed = IAggregatorV3(c.ethUsdFeed);
        feedDecimals = c.ethUsdFeed == address(0) ? 0 : IAggregatorV3(c.ethUsdFeed).decimals();
        if (feedDecimals > 18) revert OutOfBounds();
        sequencerFeed = IAggregatorV3(c.sequencerFeed);
        minEthUsd = c.minEthUsd;
        maxEthUsd = c.maxEthUsd;
        floorPriceWei = c.floorPriceWei;
        startTime = block.timestamp;
        _setParams(c.rebateBps, c.refPriceWei, c.minDealWei, c.dailyCap, c.lifetimeCap);
        _setMaxPriceAge(c.maxPriceAge);
    }

    // ---------------- admin (owner = timelock in production) ----------------
    function setEscrow(address escrow_) external onlyOwner {
        if (escrow_ == address(0)) revert ZeroAddress();
        if (escrow != address(0)) revert EscrowAlreadySet();
        escrow = escrow_;
        emit EscrowSet(escrow_);
    }

    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    function setProfiles(address profiles_, uint256 minAge) external onlyOwner {
        if (minAge > MAX_PROFILE_AGE) revert OutOfBounds();
        profiles = IPoshProfiles(profiles_);
        minProfileAge = minAge;
        emit ProfilesSet(profiles_, minAge);
    }

    function setParams(uint256 rebateBps_, uint256 refPriceWei_, uint256 minDealWei_, uint256 dailyCap_, uint256 lifetimeCap_)
        external
        onlyOwner
    {
        _setParams(rebateBps_, refPriceWei_, minDealWei_, dailyCap_, lifetimeCap_);
    }

    function setMaxPriceAge(uint256 age) external onlyOwner {
        _setMaxPriceAge(age);
    }

    /// @notice Owner or guardian can pause new credits. Only the owner can unpause. Claims are never paused.
    function setPaused(bool p) external {
        if (msg.sender != owner() && !(p && msg.sender == guardian && guardian != address(0))) revert NotAuthorized();
        paused = p;
        emit PausedSet(p, msg.sender);
    }

    /// @notice Permanently end rewards and return the unallocated pool to the immutable treasury.
    ///         Earned rewards stay claimable.
    function endRewards() external onlyOwner {
        if (ended) revert AlreadyEnded();
        ended = true;
        uint256 free = remainingPool();
        if (free > 0) token.safeTransfer(treasury, free);
        emit RewardsEnded(treasury, free);
    }

    function _setParams(uint256 r, uint256 ref, uint256 minDeal, uint256 daily, uint256 life) private {
        if (
            r > MAX_REBATE_BPS || ref < floorPriceWei || minDeal < MIN_DEAL_LOWER || minDeal > MIN_DEAL_UPPER
                || daily > MAX_DAILY_CAP || life > MAX_LIFETIME_CAP || daily > life
        ) revert OutOfBounds();
        rebateBps = r;
        refPriceWei = ref;
        minDealWei = minDeal;
        dailyCap = daily;
        lifetimeCap = life;
        emit ParamsSet(r, ref, minDeal, daily, life);
    }

    function _setMaxPriceAge(uint256 age) private {
        if (age < PRICE_AGE_LOWER || age > PRICE_AGE_UPPER) revert OutOfBounds();
        maxPriceAge = age;
        emit MaxPriceAgeSet(age);
    }

    // ---------------- views ----------------
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - startTime) / EPOCH;
    }

    function eraOf(uint256 epoch) public pure returns (uint256) {
        return epoch / EPOCHS_PER_ERA;
    }

    /// @notice Hard cap on FMNY credited in `epoch` (immutable schedule).
    function epochBudget(uint256 epoch) public pure returns (uint256) {
        uint256 era = eraOf(epoch);
        if (era >= MAX_ERAS) return 0;
        return BASE_EPOCH_BUDGET >> era;
    }

    /// @notice Rebate in bps of fee value that applies now (halves every era, like the budget).
    function currentRebateBps() public view returns (uint256) {
        uint256 era = eraOf(currentEpoch());
        if (era >= MAX_ERAS) return 0;
        return rebateBps >> era;
    }

    function remainingPool() public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        return bal > totalOwed ? bal - totalOwed : 0;
    }

    /// @notice Rewards not yet claimable because the epoch they were earned in has not ended.
    function locked(address user) public view returns (uint256) {
        return pendingEpoch[user] == currentEpoch() ? pendingAmount[user] : 0;
    }

    function claimable(address user) public view returns (uint256) {
        return earned[user] - claimed[user] - locked(user);
    }

    /// @notice ETH/USD price, or ok=false when unusable (sequencer down/grace, stale, out of band, reverts).
    function ethUsdPrice() public view returns (bool ok, uint256 price) {
        if (address(ethUsdFeed) == address(0)) return (false, 0);
        if (address(sequencerFeed) != address(0)) {
            try sequencerFeed.latestRoundData() returns (uint80, int256 status, uint256 startedAt, uint256, uint80) {
                if (status != 0 || startedAt == 0 || block.timestamp - startedAt <= SEQUENCER_GRACE) return (false, 0);
            } catch {
                return (false, 0);
            }
        }
        try ethUsdFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer < minEthUsd || answer > maxEthUsd) return (false, 0);
            if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge) {
                return (false, 0);
            }
            return (true, uint256(answer));
        } catch {
            return (false, 0);
        }
    }

    /// @notice Converts a token amount to ETH-wei. ok=false for unsupported tokens or an unusable price.
    function valueInWei(address tok, uint256 amt) public view returns (bool ok, uint256 wei_) {
        if (tok == address(0)) return (true, amt);
        if (tok != usdc || usdc == address(0)) return (false, 0);
        (bool pOk, uint256 p) = ethUsdPrice();
        if (!pOk) return (false, 0);
        // amt / 10^usdcDec USD  /  (p / 10^feedDec) USD per ETH  * 1e18 wei
        return (true, (amt * (10 ** (18 - usdcDecimals)) * (10 ** feedDecimals)) / p);
    }

    function pairKey(address a, address b) public pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @notice What notifyDeal would credit right now (for front ends and tests).
    function previewDeal(address buyer, address seller, address tok, uint256 fee, uint256 amount)
        public
        view
        returns (uint256 buyerReward, uint256 sellerReward, Skip reason, uint256 feeWei)
    {
        if (paused) return (0, 0, Skip.Paused, 0);
        if (ended) return (0, 0, Skip.Ended, 0);
        if (fee == 0) return (0, 0, Skip.NoFee, 0);
        if (buyer == seller) return (0, 0, Skip.SameWallet, 0);
        if (tok != address(0) && (tok != usdc || usdc == address(0))) return (0, 0, Skip.UnsupportedToken, 0);
        bool ok;
        uint256 amountWei;
        (ok, feeWei) = valueInWei(tok, fee);
        if (ok) (ok, amountWei) = valueInWei(tok, amount);
        if (!ok) return (0, 0, Skip.PriceUnavailable, 0);
        if (amountWei < minDealWei) return (0, 0, Skip.BelowMinDeal, feeWei);
        if (!_profileOk(buyer) || !_profileOk(seller)) return (0, 0, Skip.NoProfile, feeWei);
        uint256 epoch = currentEpoch();
        if (pairLastEpoch[pairKey(buyer, seller)] == epoch + 1) return (0, 0, Skip.PairAlreadyRewarded, feeWei);

        uint256 total = (feeWei * currentRebateBps() * 1e18) / (10_000 * refPriceWei);
        uint256 half = total / 2;
        uint256 day = block.timestamp / 1 days;
        buyerReward = _capUser(buyer, day, half);
        sellerReward = _capUser(seller, day, total - half);

        uint256 budget = epochBudget(epoch);
        uint256 used = emittedInEpoch[epoch];
        uint256 room = budget > used ? budget - used : 0;
        uint256 pool = remainingPool();
        if (pool < room) room = pool;
        uint256 sum = buyerReward + sellerReward;
        if (sum > room) {
            buyerReward = room == 0 ? 0 : (buyerReward * room) / sum;
            sellerReward = room == 0 ? 0 : (sellerReward * room) / sum;
        }
        if (buyerReward + sellerReward == 0) return (0, 0, Skip.CapReached, feeWei);
        reason = Skip.None;
    }

    // ---------------- escrow hook ----------------
    function notifyDeal(address buyer, address seller, address tok, uint256 fee, uint256 amount) external {
        if (msg.sender != escrow || escrow == address(0)) revert OnlyEscrow();
        (uint256 b, uint256 s, Skip reason, uint256 feeWei) = previewDeal(buyer, seller, tok, fee, amount);
        if (reason != Skip.None) {
            emit RewardSkipped(buyer, seller, reason);
            return;
        }
        uint256 epoch = currentEpoch();
        uint256 day = block.timestamp / 1 days;
        pairLastEpoch[pairKey(buyer, seller)] = epoch + 1;
        emittedInEpoch[epoch] += b + s;
        totalEmitted += b + s;
        if (b > 0) _credit(buyer, epoch, day, b);
        if (s > 0) _credit(seller, epoch, day, s);
        emit Rewarded(buyer, seller, tok, fee, feeWei, b, s);
    }

    function claim() external nonReentrant {
        uint256 amt = claimable(msg.sender);
        if (amt == 0) revert NothingToClaim();
        claimed[msg.sender] += amt;
        totalOwed -= amt;
        token.safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, amt);
    }

    // ---------------- internal ----------------
    function _profileOk(address user) private view returns (bool) {
        if (address(profiles) == address(0)) return true;
        try profiles.profileOf(user) returns (string memory, string memory, uint64 createdAt) {
            return createdAt != 0 && block.timestamp >= uint256(createdAt) + minProfileAge;
        } catch {
            return false;
        }
    }

    function _capUser(address user, uint256 day, uint256 amt) private view returns (uint256) {
        uint256 usedDay = earnedOnDay[user][day];
        uint256 roomDay = usedDay >= dailyCap ? 0 : dailyCap - usedDay;
        uint256 life = earned[user];
        uint256 roomLife = life >= lifetimeCap ? 0 : lifetimeCap - life;
        uint256 room = roomDay < roomLife ? roomDay : roomLife;
        return amt > room ? room : amt;
    }

    function _credit(address user, uint256 epoch, uint256 day, uint256 amt) private {
        if (pendingEpoch[user] != epoch) {
            // anything pending from an earlier epoch is now unlocked (it stays inside `earned`)
            pendingEpoch[user] = epoch;
            pendingAmount[user] = 0;
        }
        pendingAmount[user] += amt;
        earned[user] += amt;
        earnedOnDay[user][day] += amt;
        totalOwed += amt;
    }
}
