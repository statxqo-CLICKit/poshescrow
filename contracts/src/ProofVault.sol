// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IProofVault} from "./interfaces/IPosh.sol";

/// @title ProofVault
/// @notice Records a timestamped fingerprint (hash) of a document/item with a label, lets other wallets
///         co-sign it, and tracks which wallet currently holds the filing. The filing proves "this wallet
///         filed (or was handed) this fingerprint at this time"; it is not, by itself, legal proof of ownership.
/// @dev Front-running protection (self-review M-6): filing is commit-reveal. The filer first calls
///      `commitFiling(keccak256(abi.encode(hash, filer, salt)))`, then in a LATER block calls
///      `file(hash, label, salt)`. A watcher who copies the reveal from the mempool has no matching
///      commitment of its own and cannot file first. Clients should also fingerprint files with a secret
///      salt so public documents cannot be pre-filed by someone who merely knows the plain hash.
///      Owner powers (self-review M-3): the owner can only set the escrow ONCE. After that the owner has
///      no power over filings; only the filing holder (or the escrow, during a handoff it settles) can move one.
contract ProofVault is Ownable2Step, IProofVault {
    struct Record {
        address owner;
        uint64 filedAt;
        string label;
        uint256 cosigns;
    }

    uint256 public constant MAX_LABEL_BYTES = 64;
    /// @notice A commitment can be revealed only in a block strictly after the one it was made in,
    ///         and at most this long after it was made.
    uint256 public constant COMMIT_MAX_AGE = 1 days;

    mapping(bytes32 => Record) private _records;
    mapping(bytes32 => mapping(address => bool)) public hasCosigned;
    /// @notice commitment => (block number, timestamp) it was made in. 0 = none.
    mapping(bytes32 => uint256) public commitBlock;
    mapping(bytes32 => uint256) public commitTime;
    address public escrow;

    event Committed(bytes32 indexed commitment, address indexed filer);
    event Filed(bytes32 indexed hash, address indexed owner, string label);
    event CoSigned(bytes32 indexed hash, address indexed signer);
    event Transferred(bytes32 indexed hash, address indexed from, address indexed to);
    event EscrowSet(address indexed escrow);

    error AlreadyFiled();
    error NotFiled();
    error LabelTooLong();
    error ZeroHash();
    error OwnerCannotCosign();
    error AlreadyCosigned();
    error NotAuthorized();
    error ZeroAddress();
    error EscrowAlreadySet();
    error NoCommitment();
    error CommitTooFresh();
    error CommitExpired();
    error AlreadyCommitted();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice One-time wiring of the escrow allowed to move a filing when it settles a handoff.
    function setEscrow(address escrow_) external onlyOwner {
        if (escrow_ == address(0)) revert ZeroAddress();
        if (escrow != address(0)) revert EscrowAlreadySet();
        escrow = escrow_;
        emit EscrowSet(escrow_);
    }

    /// @notice Helper so clients compute the same commitment the contract checks.
    function commitmentFor(bytes32 hash, address filer, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(hash, filer, salt));
    }

    function commitFiling(bytes32 commitment) external {
        if (commitment == bytes32(0)) revert ZeroHash();
        if (commitBlock[commitment] != 0) revert AlreadyCommitted();
        commitBlock[commitment] = block.number;
        commitTime[commitment] = block.timestamp;
        emit Committed(commitment, msg.sender);
    }

    function file(bytes32 hash, string calldata label, bytes32 salt) external {
        if (hash == bytes32(0)) revert ZeroHash();
        if (bytes(label).length > MAX_LABEL_BYTES) revert LabelTooLong();
        bytes32 c = commitmentFor(hash, msg.sender, salt);
        uint256 cb = commitBlock[c];
        if (cb == 0) revert NoCommitment();
        if (block.number <= cb) revert CommitTooFresh();
        if (block.timestamp > commitTime[c] + COMMIT_MAX_AGE) revert CommitExpired();
        Record storage r = _records[hash];
        if (r.owner != address(0)) revert AlreadyFiled();
        delete commitBlock[c];
        delete commitTime[c];
        r.owner = msg.sender;
        r.filedAt = uint64(block.timestamp);
        r.label = label;
        emit Filed(hash, msg.sender, label);
    }

    function cosign(bytes32 hash) external {
        Record storage r = _records[hash];
        if (r.owner == address(0)) revert NotFiled();
        if (msg.sender == r.owner) revert OwnerCannotCosign();
        if (hasCosigned[hash][msg.sender]) revert AlreadyCosigned();
        hasCosigned[hash][msg.sender] = true;
        unchecked {
            r.cosigns++;
        }
        emit CoSigned(hash, msg.sender);
    }

    function transfer(bytes32 hash, address to) external {
        Record storage r = _records[hash];
        address from = r.owner;
        if (from == address(0)) revert NotFiled();
        if (to == address(0)) revert ZeroAddress();
        if (msg.sender != from && (msg.sender != escrow || escrow == address(0))) revert NotAuthorized();
        r.owner = to;
        emit Transferred(hash, from, to);
    }

    function recordOf(bytes32 hash)
        external
        view
        returns (address owner, uint64 filedAt, string memory label, uint256 cosigns)
    {
        Record storage r = _records[hash];
        return (r.owner, r.filedAt, r.label, r.cosigns);
    }
}
