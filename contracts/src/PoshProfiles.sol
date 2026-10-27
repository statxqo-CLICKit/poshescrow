// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPoshProfiles} from "./interfaces/IPosh.sol";

/// @title PoshProfiles
/// @notice On-chain profile sign-up: one unique lowercase username per address plus a metadata URI.
contract PoshProfiles is IPoshProfiles {
    struct Profile {
        string username;
        string metadataURI;
        uint64 createdAt;
    }

    uint256 public constant MIN_LEN = 3;
    uint256 public constant MAX_LEN = 20;
    uint256 public constant MAX_URI_BYTES = 512;

    mapping(address => Profile) private _profiles;
    mapping(bytes32 => address) private _ownerOf; // keccak256(username) => owner

    event ProfileRegistered(address indexed user, string username);
    event ProfileUpdated(address indexed user);

    error AlreadyRegistered();
    error NotRegistered();
    error UsernameTaken();
    error InvalidUsername();
    error URITooLong();

    function register(string calldata username, string calldata metadataURI) external {
        if (_profiles[msg.sender].createdAt != 0) revert AlreadyRegistered();
        if (!isValidUsername(username)) revert InvalidUsername();
        if (bytes(metadataURI).length > MAX_URI_BYTES) revert URITooLong();
        bytes32 key = keccak256(bytes(username));
        if (_ownerOf[key] != address(0)) revert UsernameTaken();
        _ownerOf[key] = msg.sender;
        _profiles[msg.sender] = Profile(username, metadataURI, uint64(block.timestamp));
        emit ProfileRegistered(msg.sender, username);
    }

    function update(string calldata metadataURI) external {
        Profile storage p = _profiles[msg.sender];
        if (p.createdAt == 0) revert NotRegistered();
        if (bytes(metadataURI).length > MAX_URI_BYTES) revert URITooLong();
        p.metadataURI = metadataURI;
        emit ProfileUpdated(msg.sender);
    }

    function usernameOf(address user) external view returns (string memory) {
        return _profiles[user].username;
    }

    function ownerOfUsername(string calldata username) external view returns (address) {
        return _ownerOf[keccak256(bytes(username))];
    }

    function profileOf(address user)
        external
        view
        returns (string memory username, string memory metadataURI, uint64 createdAt)
    {
        Profile storage p = _profiles[user];
        return (p.username, p.metadataURI, p.createdAt);
    }

    /// @notice 3–20 chars, only a-z, 0-9 and underscore.
    function isValidUsername(string calldata username) public pure returns (bool) {
        bytes calldata b = bytes(username);
        if (b.length < MIN_LEN || b.length > MAX_LEN) return false;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x5f;
            if (!ok) return false;
        }
        return true;
    }
}
