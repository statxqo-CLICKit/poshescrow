// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IProofVault {
    function recordOf(bytes32 hash)
        external
        view
        returns (address owner, uint64 filedAt, string memory label, uint256 cosigns);
    function transfer(bytes32 hash, address to) external;
}

interface ITrustPassport {
    function recordCompletion(address user, bool onTime) external;
    function recordDispute(address user) external;
    function recordRefund(address user) external;
}

interface IFMNYRewards {
    /// @param token address(0) for ETH, otherwise the ERC20 the deal was paid in
    /// @param fee   protocol fee actually charged, in the token's own decimals
    /// @param amount gross deal amount, in the token's own decimals
    function notifyDeal(address buyer, address seller, address token, uint256 fee, uint256 amount) external;
}

/// @notice Minimal Chainlink AggregatorV3Interface subset.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IPoshProfiles {
    function profileOf(address user)
        external
        view
        returns (string memory username, string memory metadataURI, uint64 createdAt);
}
