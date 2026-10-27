// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FMNY — FMoney Protocol token
/// @notice Fixed supply of 100,000,000 FMNY (18 decimals) minted once, at deploy, to the distributor.
///         There is no mint function after construction.
contract FMNY is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 100_000_000 ether;

    error ZeroAddress();

    constructor(address distributor) ERC20("FMoney Protocol", "FMNY") {
        if (distributor == address(0)) revert ZeroAddress();
        _mint(distributor, TOTAL_SUPPLY);
    }
}
