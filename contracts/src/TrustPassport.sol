// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ITrustPassport} from "./interfaces/IPosh.sol";

/// @title TrustPassport
/// @notice On-chain reputation per wallet, written only by PoshEscrow.
/// @dev The escrow writer is set exactly once (self-review M-3 / L-1); afterwards the owner cannot
///      repoint the writer, so it cannot fabricate reputation.
contract TrustPassport is Ownable2Step, ITrustPassport {
    struct Passport {
        uint256 completed;
        uint256 onTime;
        uint256 disputes;
        uint256 refunds;
        uint64 since;
    }

    mapping(address => Passport) private _p;
    address public escrow;

    event EscrowSet(address indexed escrow);
    event Completed(address indexed user, bool onTime);
    event DisputeRecorded(address indexed user);
    event RefundRecorded(address indexed user);

    error OnlyEscrow();
    error ZeroAddress();
    error EscrowAlreadySet();

    modifier onlyEscrow() {
        if (msg.sender != escrow || escrow == address(0)) revert OnlyEscrow();
        _;
    }

    constructor(address owner_) Ownable(owner_) {}

    function setEscrow(address escrow_) external onlyOwner {
        if (escrow_ == address(0)) revert ZeroAddress();
        if (escrow != address(0)) revert EscrowAlreadySet();
        escrow = escrow_;
        emit EscrowSet(escrow_);
    }

    function recordCompletion(address user, bool onTime) external onlyEscrow {
        Passport storage p = _touch(user);
        p.completed++;
        if (onTime) p.onTime++;
        emit Completed(user, onTime);
    }

    function recordDispute(address user) external onlyEscrow {
        _touch(user).disputes++;
        emit DisputeRecorded(user);
    }

    function recordRefund(address user) external onlyEscrow {
        _touch(user).refunds++;
        emit RefundRecorded(user);
    }

    function getPassport(address user)
        external
        view
        returns (uint256 completed, uint256 disputes, uint256 refunds, uint256 onTimeBps, uint64 since)
    {
        Passport storage p = _p[user];
        completed = p.completed;
        disputes = p.disputes;
        refunds = p.refunds;
        onTimeBps = p.completed == 0 ? 0 : (p.onTime * 10_000) / p.completed;
        since = p.since;
    }

    function _touch(address user) private returns (Passport storage p) {
        p = _p[user];
        if (p.since == 0) p.since = uint64(block.timestamp);
    }
}
