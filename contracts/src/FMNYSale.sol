// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FMNYSale (v0.2)
/// @notice Allowlisted FMNY pre-sale with soft/hard caps and a fixed [startTime, endTime) window.
///         On success buyers claim FMNY after a lock and the treasury PULLS the raised ETH; on failure or
///         cancellation buyers refund their ETH.
/// @dev Self-review M-4/M-5 fixes:
///      - immutable startTime/endTime; nobody can finalize before endTime unless the hard cap is reached;
///      - the only early stop is `cancel()` (owner or guardian), which makes the sale FAIL so every buyer
///        can refund; nobody can end the sale early as a success;
///      - finalize never transfers ETH, so a treasury that rejects ETH cannot freeze the sale; the treasury
///        withdraws with `withdrawRaised(to)` to any address it chooses.
contract FMNYSale is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable treasury;
    uint256 public immutable price; // wei per 1 FMNY (1e18 units)
    uint256 public immutable softCap;
    uint256 public immutable hardCap;
    uint256 public immutable minBuy;
    uint256 public immutable maxPerWallet;
    uint256 public immutable startTime;
    uint256 public immutable endTime;
    uint256 public immutable lockDuration;

    address public guardian; // allowlist manager; may pause buys and cancel (refund mode)
    uint256 public raised;
    uint256 public tokensSold;
    uint256 public tokensClaimed;
    uint256 public unlockTime;
    uint256 public raisedWithdrawn;
    bool public finalized;
    bool public succeeded;
    bool public cancelled;
    bool public paused;

    mapping(address => uint256) public contributions;
    mapping(address => bool) public approved;
    mapping(address => bool) public hasClaimed;

    event Approved(address indexed account, bool approved);
    event GuardianSet(address indexed guardian);
    event PausedSet(bool paused, address indexed by);
    event Bought(address indexed buyer, uint256 ethAmount, uint256 tokenAmount);
    event Finalized(bool succeeded, uint256 raised, uint256 unlockTime);
    event Cancelled(address indexed by, uint256 raised);
    event RaisedWithdrawn(address indexed to, uint256 amount);
    event Claimed(address indexed buyer, uint256 tokenAmount);
    event Refunded(address indexed buyer, uint256 ethAmount);
    event UnsoldReturned(uint256 amount);

    error NotApproved();
    error NotStarted();
    error SaleClosed();
    error SalePaused();
    error BelowMin();
    error AboveMax();
    error HardCapExceeded();
    error InsufficientTokens();
    error AlreadyFinalized();
    error NotFinalized();
    error CannotFinalizeYet();
    error SaleFailed();
    error SaleSucceeded();
    error Locked();
    error NothingToClaim();
    error NothingToRefund();
    error NothingToWithdraw();
    error TransferFailed();
    error BadParams();
    error NotAuthorized();
    error ZeroAddress();

    constructor(
        address token_,
        address treasury_,
        address owner_,
        uint256 price_,
        uint256 softCap_,
        uint256 hardCap_,
        uint256 minBuy_,
        uint256 maxPerWallet_,
        uint256 startTime_,
        uint256 duration_,
        uint256 lockDuration_
    ) Ownable(owner_) {
        if (
            token_ == address(0) || treasury_ == address(0) || price_ == 0 || softCap_ == 0 || softCap_ > hardCap_
                || minBuy_ == 0 || minBuy_ > maxPerWallet_ || duration_ == 0 || startTime_ < block.timestamp
        ) {
            revert BadParams();
        }
        token = IERC20(token_);
        treasury = treasury_;
        price = price_;
        softCap = softCap_;
        hardCap = hardCap_;
        minBuy = minBuy_;
        maxPerWallet = maxPerWallet_;
        startTime = startTime_;
        endTime = startTime_ + duration_;
        lockDuration = lockDuration_;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && (msg.sender != guardian || guardian == address(0))) revert NotAuthorized();
        _;
    }

    // ---------------- admin ----------------
    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    function setApproved(address[] calldata accounts, bool ok) external onlyOwnerOrGuardian {
        for (uint256 i; i < accounts.length; ++i) {
            approved[accounts[i]] = ok;
            emit Approved(accounts[i], ok);
        }
    }

    /// @notice Temporarily stop new buys (does not move the end time, does not affect refunds/claims).
    function setPaused(bool p) external onlyOwnerOrGuardian {
        paused = p;
        emit PausedSet(p, msg.sender);
    }

    /// @notice Emergency stop: ends the sale as FAILED so every contributor can refund in full.
    function cancel() external onlyOwnerOrGuardian {
        if (finalized) revert AlreadyFinalized();
        finalized = true;
        cancelled = true;
        emit Cancelled(msg.sender, raised);
        emit Finalized(false, raised, 0);
    }

    // ---------------- sale ----------------
    function tokensFor(uint256 ethAmount) public view returns (uint256) {
        return (ethAmount * 1e18) / price;
    }

    function buy() external payable nonReentrant {
        if (!approved[msg.sender]) revert NotApproved();
        if (block.timestamp < startTime) revert NotStarted();
        if (finalized || block.timestamp >= endTime) revert SaleClosed();
        if (paused) revert SalePaused();
        if (msg.value < minBuy) revert BelowMin();
        uint256 newContribution = contributions[msg.sender] + msg.value;
        if (newContribution > maxPerWallet) revert AboveMax();
        if (raised + msg.value > hardCap) revert HardCapExceeded();
        uint256 amount = tokensFor(msg.value);
        if (tokensSold + amount > token.balanceOf(address(this))) revert InsufficientTokens();

        contributions[msg.sender] = newContribution;
        raised += msg.value;
        tokensSold += amount;
        emit Bought(msg.sender, msg.value, amount);
    }

    /// @notice Anyone may finalize after endTime, or once the hard cap is reached. Never transfers ETH.
    function finalize() external nonReentrant {
        if (finalized) revert AlreadyFinalized();
        if (block.timestamp < endTime && raised < hardCap) revert CannotFinalizeYet();
        finalized = true;
        if (raised >= softCap) {
            succeeded = true;
            unlockTime = block.timestamp + lockDuration;
        }
        emit Finalized(succeeded, raised, unlockTime);
    }

    /// @notice Treasury pulls the raised ETH after a successful sale, to any address it chooses.
    function withdrawRaised(address to) external nonReentrant {
        if (msg.sender != treasury) revert NotAuthorized();
        if (to == address(0)) revert ZeroAddress();
        if (!succeeded) revert SaleFailed();
        uint256 amt = address(this).balance;
        if (amt == 0) revert NothingToWithdraw();
        raisedWithdrawn += amt;
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit RaisedWithdrawn(to, amt);
    }

    function claim() external nonReentrant {
        if (!finalized) revert NotFinalized();
        if (!succeeded) revert SaleFailed();
        if (block.timestamp < unlockTime) revert Locked();
        if (hasClaimed[msg.sender] || contributions[msg.sender] == 0) revert NothingToClaim();
        hasClaimed[msg.sender] = true;
        uint256 amount = tokensFor(contributions[msg.sender]);
        tokensClaimed += amount;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function refund() external nonReentrant {
        if (!finalized) revert NotFinalized();
        if (succeeded) revert SaleSucceeded();
        uint256 amt = contributions[msg.sender];
        if (amt == 0) revert NothingToRefund();
        contributions[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit Refunded(msg.sender, amt);
    }

    /// @notice After finalize, return FMNY not owed to buyers to the treasury. Callable by anyone.
    function returnUnsold() external nonReentrant {
        if (!finalized) revert NotFinalized();
        uint256 owed = succeeded ? tokensSold - tokensClaimed : 0;
        uint256 bal = token.balanceOf(address(this));
        uint256 extra = bal > owed ? bal - owed : 0;
        if (extra > 0) token.safeTransfer(treasury, extra);
        emit UnsoldReturned(extra);
    }
}
