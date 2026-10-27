// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IProofVault, ITrustPassport, IFMNYRewards} from "./interfaces/IPosh.sol";

/// @title PoshEscrow (v0.2)
/// @notice Buyer-funded escrow for ETH and allow-listed ERC20s (USDC), with delivery, review period,
///         disputes and ProofVault "handoff" deals that atomically pay the seller and move the filed item
///         to the buyer.
/// @dev v0.2 changes (see compliance/audit/findings-selfreview.md):
///      H-1 arbiters must be the default arbiter or on the owner-curated allowlist, and never a party.
///          The seller sees the arbiter before delivering and can decline the deal with sellerRefund.
///      H-3 handoffs: seller can mark handed-off (optionally with a proof hash) before the window ends, which
///          blocks the buyer's refund; the buyer then releases, or disputes within HANDOFF_CONFIRM, or the
///          seller claims after HANDOFF_CONFIRM. A buyer-signed EIP-712 receipt lets the seller settle at
///          the meetup. Either side can dispute a handoff (default arbiter).
///      M-1 markDelivered only up to the deadline.
///      M-2 no 50/50 split. Idle custom arbiter -> escalate to the default arbiter; idle default arbiter ->
///          after DISPUTE_TIMEOUT the pre-dispute outcome applies (delivered => seller, else buyer refund).
///      L-2/L-3/L-4 gas-capped ETH push, strict ERC20 return decoding, settle votes reset on state change.
///      Rewards are notified only for undisputed releases (release / sellerClaim / handoff release).
contract PoshEscrow is Ownable2Step, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Funded,
        Delivered,
        Released,
        Refunded,
        Disputed,
        Resolved
    }

    struct Deal {
        address buyer;
        address seller;
        address arbiter;
        address token;
        uint256 amount;
        bytes32 termsHash;
        uint64 deadline;
        uint64 deliveredAt;
        uint64 disputedAt; // start of the current arbiter's clock (reset on escalation)
        uint16 feeBps; // fee snapshot at creation
        Status status;
        bool sellerAgreedSettle;
        bool buyerAgreedSettle;
        bool sellerSettleChoice;
        bool buyerSettleChoice;
        bool arbiterAccepted;
        bool isHandoff;
        bool escalated;
        bytes32 itemHash;
        bytes32 deliveryProof;
    }

    uint64 public constant MIN_DURATION = 2 hours;
    uint64 public constant MAX_DURATION = 720 hours;
    uint64 public constant REVIEW_PERIOD = 72 hours;
    uint64 public constant HANDOFF_MIN = 2 hours;
    uint64 public constant HANDOFF_MAX = 24 hours;
    uint64 public constant HANDOFF_CONFIRM = 24 hours;
    uint64 public constant ARBITER_ACCEPT_WINDOW = 7 days;
    uint64 public constant DISPUTE_TIMEOUT = 30 days;
    uint16 public constant MAX_FEE_BPS = 500;
    uint256 public constant ETH_PUSH_GAS = 100_000;
    bytes32 public constant HANDOFF_RECEIPT_TYPEHASH =
        keccak256("HandoffReceipt(uint256 dealId,bytes32 itemHash,address buyer)");

    IProofVault public immutable vault;
    ITrustPassport public passport;
    IFMNYRewards public rewards;
    address public treasury;
    address public defaultArbiter;
    address public guardian;
    bool public creationPaused;
    uint16 public feeBps = 100;

    uint256 public nextDealId = 1;
    mapping(uint256 => Deal) private _deals;
    mapping(address => bool) public allowedToken;
    mapping(address => uint8) public tokenDecimals;
    mapping(address => bool) public approvedArbiter;
    /// @notice Payouts that could not be pushed (recipient reverted / token blocked). token(0) = ETH.
    mapping(address => mapping(address => uint256)) public pendingWithdrawals;
    /// @notice Accounting for invariants: escrowed in open deals, and owed via pendingWithdrawals, per token.
    mapping(address => uint256) public totalLocked;
    mapping(address => uint256) public totalPending;

    // ---------------- events ----------------
    event DealCreated(uint256 indexed id, address indexed buyer, address indexed seller);
    event DealFunded(
        uint256 indexed id, address token, uint256 amount, uint64 deadline, address indexed arbiter, bytes32 termsHash
    );
    event HandoffCreated(
        uint256 indexed id, address indexed buyer, address indexed seller, bytes32 itemHash, uint64 deadline
    );
    event Delivered(uint256 indexed id, uint64 deliveredAt);
    event DeliveryProof(uint256 indexed id, bytes32 indexed proofHash);
    event Released(uint256 indexed id, address indexed seller, uint256 payout, uint256 fee);
    event SellerClaimed(uint256 indexed id, address indexed seller, uint256 payout, uint256 fee);
    event Refunded(uint256 indexed id, address indexed buyer, uint256 amount);
    event SellerRefunded(uint256 indexed id, address indexed buyer, uint256 amount);
    event Disputed(uint256 indexed id, address indexed by);
    event ArbiterAccepted(uint256 indexed id, address indexed arbiter);
    event Escalated(uint256 indexed id, address indexed from, address indexed to);
    event Ruled(uint256 indexed id, address indexed arbiter, bool paySeller);
    event TimeoutResolved(uint256 indexed id, bool paySeller);
    event SettleProposed(uint256 indexed id, address indexed by, bool paySeller);
    event Settled(uint256 indexed id, bool paySeller);
    event HandoffReleased(uint256 indexed id, bytes32 indexed itemHash, address indexed buyer);
    event PaymentDeferred(address indexed token, address indexed to, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event FeeSet(uint16 bps);
    event TreasurySet(address indexed treasury);
    event DefaultArbiterSet(address indexed arbiter);
    event ArbiterApproved(address indexed arbiter, bool approved);
    event GuardianSet(address indexed guardian);
    event CreationPausedSet(bool paused, address indexed by);
    event TokenAllowed(address indexed token, bool allowed, uint8 decimals);
    event HooksSet(address indexed passport, address indexed rewards);

    // ---------------- errors ----------------
    error InvalidSeller();
    error InvalidAmount();
    error InvalidDeadline();
    error InvalidArbiter();
    error TokenNotAllowed();
    error WrongValue();
    error TransferMismatch();
    error NotBuyer();
    error NotSeller();
    error NotParty();
    error NotArbiter();
    error BadStatus();
    error TooEarly();
    error TooLate();
    error NotAccepted();
    error AlreadyAccepted();
    error IsHandoff();
    error NotHandoff();
    error InvalidWindow();
    error ItemNotOwnedBySeller();
    error ItemMismatch();
    error FeeTooHigh();
    error ZeroAddress();
    error NothingToWithdraw();
    error CreationPaused();
    error NotAuthorized();
    error BadSignature();
    error CannotEscalate();

    constructor(
        address vault_,
        address passport_,
        address rewards_,
        address treasury_,
        address defaultArbiter_,
        address usdc_,
        address owner_
    ) Ownable(owner_) EIP712("PoshEscrow", "2") {
        if (vault_ == address(0) || treasury_ == address(0) || defaultArbiter_ == address(0)) {
            revert ZeroAddress();
        }
        vault = IProofVault(vault_);
        passport = ITrustPassport(passport_);
        rewards = IFMNYRewards(rewards_);
        treasury = treasury_;
        defaultArbiter = defaultArbiter_;
        if (usdc_ != address(0)) _allowToken(usdc_, true);
    }

    // ---------------- admin (owner = timelock in production) ----------------
    function setFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = bps;
        emit FeeSet(bps);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    function setDefaultArbiter(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        defaultArbiter = a;
        emit DefaultArbiterSet(a);
    }

    /// @notice Curated arbiter registry (H-1). Removing an arbiter lets parties of its open disputes
    ///         escalate to the default arbiter immediately.
    function setArbiterApproved(address a, bool ok) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        approvedArbiter[a] = ok;
        emit ArbiterApproved(a, ok);
    }

    function setHooks(address passport_, address rewards_) external onlyOwner {
        passport = ITrustPassport(passport_);
        rewards = IFMNYRewards(rewards_);
        emit HooksSet(passport_, rewards_);
    }

    function setAllowedToken(address token, bool allowed) external onlyOwner {
        _allowToken(token, allowed);
    }

    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    /// @notice Owner or guardian can pause NEW deals; only the owner can unpause. Existing deals are never
    ///         affected (every exit path stays open).
    function setCreationPaused(bool p) external {
        if (msg.sender != owner() && !(p && msg.sender == guardian && guardian != address(0))) revert NotAuthorized();
        creationPaused = p;
        emit CreationPausedSet(p, msg.sender);
    }

    function _allowToken(address token, bool allowed) private {
        if (token == address(0)) revert ZeroAddress();
        uint8 dec = IERC20Metadata(token).decimals();
        require(dec <= 18, "decimals>18");
        allowedToken[token] = allowed;
        tokenDecimals[token] = dec;
        emit TokenAllowed(token, allowed, dec);
    }

    function isValidArbiter(address a, address buyer, address seller) public view returns (bool) {
        if (a == address(0) || a == buyer || a == seller) return false;
        return a == defaultArbiter || approvedArbiter[a];
    }

    // ---------------- create ----------------
    function createDeal(
        address seller,
        bytes32 termsHash,
        address token,
        uint256 amount,
        uint64 deadline,
        address arbiter
    ) external payable nonReentrant returns (uint256 id) {
        if (creationPaused) revert CreationPaused();
        if (seller == address(0) || seller == msg.sender) revert InvalidSeller();
        if (amount == 0) revert InvalidAmount();
        if (deadline < block.timestamp + MIN_DURATION || deadline > block.timestamp + MAX_DURATION) {
            revert InvalidDeadline();
        }
        if (arbiter == address(0)) arbiter = defaultArbiter;
        if (!isValidArbiter(arbiter, msg.sender, seller)) revert InvalidArbiter();

        id = nextDealId++;
        Deal storage d = _deals[id];
        d.buyer = msg.sender;
        d.seller = seller;
        d.arbiter = arbiter;
        d.token = token;
        d.amount = amount;
        d.termsHash = termsHash;
        d.deadline = deadline;
        d.feeBps = feeBps;
        d.status = Status.Funded;

        if (token == address(0)) {
            if (msg.value != amount) revert WrongValue();
        } else {
            if (msg.value != 0) revert WrongValue();
            if (!allowedToken[token]) revert TokenNotAllowed();
            uint256 before = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            if (IERC20(token).balanceOf(address(this)) - before != amount) revert TransferMismatch();
        }
        totalLocked[token] += amount;

        emit DealCreated(id, msg.sender, seller);
        emit DealFunded(id, token, amount, deadline, arbiter, termsHash);
    }

    function createHandoff(address seller, bytes32 termsHash, bytes32 itemHash, uint64 window)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (creationPaused) revert CreationPaused();
        if (seller == address(0) || seller == msg.sender) revert InvalidSeller();
        if (msg.value == 0) revert InvalidAmount();
        if (window < HANDOFF_MIN || window > HANDOFF_MAX) revert InvalidWindow();
        if (!isValidArbiter(defaultArbiter, msg.sender, seller)) revert InvalidArbiter();
        (address itemOwner,,,) = vault.recordOf(itemHash);
        if (itemOwner != seller) revert ItemNotOwnedBySeller();

        id = nextDealId++;
        Deal storage d = _deals[id];
        d.buyer = msg.sender;
        d.seller = seller;
        d.arbiter = defaultArbiter;
        d.amount = msg.value;
        d.termsHash = termsHash;
        d.deadline = uint64(block.timestamp) + window;
        d.feeBps = feeBps;
        d.status = Status.Funded;
        d.isHandoff = true;
        d.itemHash = itemHash;
        totalLocked[address(0)] += msg.value;

        emit DealCreated(id, msg.sender, seller);
        emit HandoffCreated(id, msg.sender, seller, itemHash, d.deadline);
    }

    // ---------------- delivery ----------------
    /// @notice Seller marks delivered (or, for a handoff, handed over). Only up to the deadline (M-1).
    function markDelivered(uint256 id) external {
        _markDelivered(id, bytes32(0));
    }

    /// @notice Same as markDelivered, plus a delivery-proof fingerprint (e.g. tracking receipt, meetup photo,
    ///         or a ProofVault filing) recorded for the arbiter.
    function markDeliveredWithProof(uint256 id, bytes32 proofHash) external {
        _markDelivered(id, proofHash);
    }

    function _markDelivered(uint256 id, bytes32 proofHash) private {
        Deal storage d = _deals[id];
        if (msg.sender != d.seller) revert NotSeller();
        if (d.status != Status.Funded) revert BadStatus();
        if (block.timestamp > d.deadline) revert TooLate();
        d.status = Status.Delivered;
        d.deliveredAt = uint64(block.timestamp);
        _resetSettle(d);
        emit Delivered(id, d.deliveredAt);
        if (proofHash != bytes32(0)) {
            d.deliveryProof = proofHash;
            emit DeliveryProof(id, proofHash);
        }
    }

    // ---------------- happy path ----------------
    function release(uint256 id) external nonReentrant {
        Deal storage d = _deals[id];
        if (msg.sender != d.buyer) revert NotBuyer();
        if (d.isHandoff) revert IsHandoff();
        if (d.status != Status.Funded && d.status != Status.Delivered) revert BadStatus();
        d.status = Status.Released;
        (uint256 payout, uint256 fee) = _paySeller(d, d.amount);
        _complete(d);
        emit Released(id, d.seller, payout, fee);
        _notifyRewards(d, fee);
    }

    /// @notice Seller collects after the buyer's review window (72h; 24h for handoffs) with no dispute.
    ///         For a handoff the ProofVault filing moves to the buyer in the same transaction.
    function sellerClaim(uint256 id) external nonReentrant {
        Deal storage d = _deals[id];
        if (msg.sender != d.seller) revert NotSeller();
        if (d.status != Status.Delivered) revert BadStatus();
        if (block.timestamp < uint256(d.deliveredAt) + _reviewPeriod(d)) revert TooEarly();
        d.status = Status.Released;
        if (d.isHandoff) _moveItem(d, true);
        (uint256 payout, uint256 fee) = _paySeller(d, d.amount);
        _complete(d);
        if (d.isHandoff) emit HandoffReleased(id, d.itemHash, d.buyer);
        emit SellerClaimed(id, d.seller, payout, fee);
        _notifyRewards(d, fee);
    }

    function releaseHandoff(uint256 id, bytes32 itemHash) external nonReentrant {
        Deal storage d = _deals[id];
        if (msg.sender != d.buyer) revert NotBuyer();
        _releaseHandoff(id, d, itemHash);
    }

    /// @notice Anyone (normally the seller, at the meetup) submits the buyer's signed EIP-712
    ///         HandoffReceipt(dealId, itemHash, buyer). Supports EOAs and ERC-1271 smart wallets.
    function releaseHandoffWithSig(uint256 id, bytes calldata buyerSig) external nonReentrant {
        Deal storage d = _deals[id];
        bytes32 digest = handoffReceiptDigest(id);
        if (!SignatureChecker.isValidSignatureNow(d.buyer, digest, buyerSig)) revert BadSignature();
        _releaseHandoff(id, d, d.itemHash);
    }

    function handoffReceiptDigest(uint256 id) public view returns (bytes32) {
        Deal storage d = _deals[id];
        return _hashTypedDataV4(keccak256(abi.encode(HANDOFF_RECEIPT_TYPEHASH, id, d.itemHash, d.buyer)));
    }

    function _releaseHandoff(uint256 id, Deal storage d, bytes32 itemHash) private {
        if (!d.isHandoff) revert NotHandoff();
        if (d.status != Status.Funded && d.status != Status.Delivered) revert BadStatus();
        if (itemHash != d.itemHash) revert ItemMismatch();
        d.status = Status.Released;
        _moveItem(d, true); // reverts the whole tx if the seller no longer holds the filing => atomic
        (, uint256 fee) = _paySeller(d, d.amount);
        _complete(d);
        emit HandoffReleased(id, itemHash, d.buyer);
        emit Released(id, d.seller, d.amount - fee, fee);
        _notifyRewards(d, fee);
    }

    // ---------------- refunds ----------------
    /// @notice Buyer refund after the deadline, only if the seller never marked delivered / handed over and
    ///         nobody opened a dispute (status still Funded).
    function refund(uint256 id) external nonReentrant {
        Deal storage d = _deals[id];
        if (msg.sender != d.buyer) revert NotBuyer();
        if (d.status != Status.Funded) revert BadStatus();
        if (block.timestamp <= d.deadline) revert TooEarly();
        d.status = Status.Refunded;
        _refundBuyer(d);
        emit Refunded(id, d.buyer, d.amount);
    }

    function sellerRefund(uint256 id) external nonReentrant {
        Deal storage d = _deals[id];
        if (msg.sender != d.seller) revert NotSeller();
        if (d.status != Status.Funded && d.status != Status.Delivered && d.status != Status.Disputed) {
            revert BadStatus();
        }
        d.status = Status.Refunded;
        _refundBuyer(d);
        emit SellerRefunded(id, d.buyer, d.amount);
    }

    // ---------------- disputes ----------------
    /// @notice Buyer: while Funded, or while Delivered within the review window.
    ///         Seller: while Funded up to the deadline (e.g. buyer took the item at a handoff and went silent),
    ///         or while Delivered.
    function dispute(uint256 id) external nonReentrant {
        Deal storage d = _deals[id];
        if (msg.sender == d.buyer) {
            if (d.status == Status.Delivered && block.timestamp >= uint256(d.deliveredAt) + _reviewPeriod(d)) {
                revert TooLate();
            }
        } else if (msg.sender == d.seller) {
            if (d.status == Status.Funded && block.timestamp > d.deadline) revert TooLate();
        } else {
            revert NotParty();
        }
        if (d.status != Status.Funded && d.status != Status.Delivered) revert BadStatus();
        d.status = Status.Disputed;
        d.disputedAt = uint64(block.timestamp);
        _resetSettle(d);
        _passportDispute(d.buyer);
        _passportDispute(d.seller);
        emit Disputed(id, msg.sender);
    }

    function acceptDeal(uint256 id) external {
        Deal storage d = _deals[id];
        if (msg.sender != d.arbiter) revert NotArbiter();
        if (d.arbiterAccepted) revert AlreadyAccepted();
        if (d.status != Status.Funded && d.status != Status.Delivered && d.status != Status.Disputed) {
            revert BadStatus();
        }
        d.arbiterAccepted = true;
        emit ArbiterAccepted(id, msg.sender);
    }

    function rule(uint256 id, bool paySeller) external nonReentrant {
        Deal storage d = _deals[id];
        if (msg.sender != d.arbiter) revert NotArbiter();
        if (!d.arbiterAccepted) revert NotAccepted();
        if (d.status != Status.Disputed) revert BadStatus();
        d.status = Status.Resolved;
        _resolve(d, paySeller);
        emit Ruled(id, msg.sender, paySeller);
    }

    /// @notice Hand an idle or de-listed custom arbiter's dispute to the default arbiter (fresh clock).
    ///         Allowed when the arbiter was removed from the registry, did not accept within
    ///         ARBITER_ACCEPT_WINDOW, or did not rule within DISPUTE_TIMEOUT.
    function escalate(uint256 id) external {
        Deal storage d = _deals[id];
        if (msg.sender != d.buyer && msg.sender != d.seller) revert NotParty();
        if (d.status != Status.Disputed) revert BadStatus();
        address to = defaultArbiter;
        if (d.arbiter == to || !isValidArbiter(to, d.buyer, d.seller)) revert CannotEscalate();
        bool delisted = !approvedArbiter[d.arbiter];
        bool idleAccept = !d.arbiterAccepted && block.timestamp >= uint256(d.disputedAt) + ARBITER_ACCEPT_WINDOW;
        bool idleRule = block.timestamp >= uint256(d.disputedAt) + DISPUTE_TIMEOUT;
        if (!(delisted || idleAccept || idleRule)) revert TooEarly();
        address from = d.arbiter;
        d.arbiter = to;
        d.arbiterAccepted = false;
        d.escalated = true;
        d.disputedAt = uint64(block.timestamp);
        _resetSettle(d);
        emit Escalated(id, from, to);
    }

    /// @notice Last resort when the (default) arbiter has not ruled DISPUTE_TIMEOUT after the dispute or
    ///         escalation: the outcome the deal would have had without the dispute applies.
    ///         Delivered/handed over on time => seller is paid; never delivered => buyer is refunded.
    function resolveTimeout(uint256 id) external nonReentrant {
        Deal storage d = _deals[id];
        if (msg.sender != d.buyer && msg.sender != d.seller) revert NotParty();
        if (d.status != Status.Disputed) revert BadStatus();
        if (block.timestamp < uint256(d.disputedAt) + DISPUTE_TIMEOUT) revert TooEarly();
        // a custom arbiter must first be escalated to the default arbiter, when that is possible
        if (d.arbiter != defaultArbiter && isValidArbiter(defaultArbiter, d.buyer, d.seller)) {
            revert CannotEscalate();
        }
        bool paySeller = d.deliveredAt != 0;
        d.status = Status.Resolved;
        _resolve(d, paySeller);
        emit TimeoutResolved(id, paySeller);
    }

    /// @notice Mutual settlement. Executes when buyer and seller have both called with the same choice.
    ///         Votes are cleared whenever the deal changes state (delivery, dispute, escalation).
    function settle(uint256 id, bool paySeller) external nonReentrant {
        Deal storage d = _deals[id];
        if (d.status != Status.Funded && d.status != Status.Delivered && d.status != Status.Disputed) {
            revert BadStatus();
        }
        if (msg.sender == d.buyer) {
            d.buyerAgreedSettle = true;
            d.buyerSettleChoice = paySeller;
        } else if (msg.sender == d.seller) {
            d.sellerAgreedSettle = true;
            d.sellerSettleChoice = paySeller;
        } else {
            revert NotParty();
        }
        emit SettleProposed(id, msg.sender, paySeller);

        if (!(d.buyerAgreedSettle && d.sellerAgreedSettle && d.buyerSettleChoice == d.sellerSettleChoice)) return;

        bool wasDisputed = d.status == Status.Disputed;
        if (paySeller) {
            d.status = wasDisputed ? Status.Resolved : Status.Released;
        } else {
            d.status = wasDisputed ? Status.Resolved : Status.Refunded;
        }
        _resolve(d, paySeller);
        emit Settled(id, paySeller);
    }

    // ---------------- pull fallback ----------------
    function withdraw(address token) external nonReentrant {
        uint256 amt = pendingWithdrawals[token][msg.sender];
        if (amt == 0) revert NothingToWithdraw();
        pendingWithdrawals[token][msg.sender] = 0;
        totalPending[token] -= amt;
        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amt}("");
            require(ok, "eth send failed");
        } else {
            IERC20(token).safeTransfer(msg.sender, amt);
        }
        emit Withdrawn(token, msg.sender, amt);
    }

    // ---------------- views ----------------
    function getDeal(uint256 id)
        external
        view
        returns (
            address buyer,
            address seller,
            address arbiter,
            address token,
            uint256 amount,
            bytes32 termsHash,
            uint64 deadline,
            uint64 deliveredAt,
            uint8 status,
            bool sellerAgreedSettle,
            bool buyerAgreedSettle
        )
    {
        Deal storage d = _deals[id];
        return (
            d.buyer,
            d.seller,
            d.arbiter,
            d.token,
            d.amount,
            d.termsHash,
            d.deadline,
            d.deliveredAt,
            uint8(d.status),
            d.sellerAgreedSettle,
            d.buyerAgreedSettle
        );
    }

    /// @notice Extra deal fields not in getDeal (kept separate so getDeal's ABI is unchanged).
    function getDealExtra(uint256 id)
        external
        view
        returns (
            bool isHandoff,
            bytes32 itemHash,
            bool arbiterAccepted,
            uint64 disputedAt,
            uint16 dealFeeBps,
            bool escalated,
            bytes32 deliveryProof
        )
    {
        Deal storage d = _deals[id];
        return (d.isHandoff, d.itemHash, d.arbiterAccepted, d.disputedAt, d.feeBps, d.escalated, d.deliveryProof);
    }

    // ---------------- internal ----------------
    function _reviewPeriod(Deal storage d) private view returns (uint256) {
        return d.isHandoff ? HANDOFF_CONFIRM : REVIEW_PERIOD;
    }

    function _resetSettle(Deal storage d) private {
        d.sellerAgreedSettle = false;
        d.buyerAgreedSettle = false;
        d.sellerSettleChoice = false;
        d.buyerSettleChoice = false;
    }

    /// @dev Terminal payout for rule / settle / timeout. No FMNY rewards on these paths.
    function _resolve(Deal storage d, bool paySeller) private {
        if (paySeller) {
            if (d.isHandoff) _moveItem(d, false);
            _paySeller(d, d.amount);
            _complete(d);
        } else {
            _refundBuyer(d);
        }
    }

    /// @dev Moves the handoff filing to the buyer. strict=true reverts if the seller no longer holds it.
    function _moveItem(Deal storage d, bool strict) private {
        (address itemOwner,,,) = vault.recordOf(d.itemHash);
        if (itemOwner != d.seller) {
            if (strict) revert ItemNotOwnedBySeller();
            return;
        }
        vault.transfer(d.itemHash, d.buyer);
    }

    function _refundBuyer(Deal storage d) private {
        totalLocked[d.token] -= d.amount;
        _pay(d.token, d.buyer, d.amount);
        _passportRefund(d.buyer);
        _passportRefund(d.seller);
    }

    function _paySeller(Deal storage d, uint256 gross) private returns (uint256 payout, uint256 fee) {
        totalLocked[d.token] -= gross;
        fee = (gross * d.feeBps) / 10_000;
        payout = gross - fee;
        if (fee > 0) _pay(d.token, treasury, fee);
        _pay(d.token, d.seller, payout);
    }

    function _pay(address token, address to, uint256 amt) private {
        if (amt == 0) return;
        bool ok;
        if (token == address(0)) {
            (ok,) = to.call{value: amt, gas: ETH_PUSH_GAS}("");
        } else {
            (bool success, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amt));
            if (success) {
                if (ret.length == 0) ok = token.code.length > 0;
                else if (ret.length == 32) ok = abi.decode(ret, (uint256)) == 1;
            }
        }
        if (!ok) {
            pendingWithdrawals[token][to] += amt;
            totalPending[token] += amt;
            emit PaymentDeferred(token, to, amt);
        }
    }

    function _notifyRewards(Deal storage d, uint256 fee) private {
        if (address(rewards) == address(0) || fee == 0) return;
        try rewards.notifyDeal(d.buyer, d.seller, d.token, fee, d.amount) {} catch {}
    }

    function _complete(Deal storage d) private {
        uint256 delivered = d.deliveredAt != 0 ? d.deliveredAt : block.timestamp;
        bool onTime = delivered <= d.deadline;
        _passportCompletion(d.seller, onTime);
        _passportCompletion(d.buyer, true);
    }

    function _passportCompletion(address u, bool onTime) private {
        if (address(passport) == address(0)) return;
        try passport.recordCompletion(u, onTime) {} catch {}
    }

    function _passportDispute(address u) private {
        if (address(passport) == address(0)) return;
        try passport.recordDispute(u) {} catch {}
    }

    function _passportRefund(address u) private {
        if (address(passport) == address(0)) return;
        try passport.recordRefund(u) {} catch {}
    }
}
