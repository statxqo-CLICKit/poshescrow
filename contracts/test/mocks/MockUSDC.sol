// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("no");
    }
}

/// @notice Chainlink-style aggregator mock (AggregatorV3 subset).
contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    bool public broken;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 updated) external {
        answer = a;
        updatedAt = updated;
    }

    function setStartedAt(uint256 s) external {
        startedAt = s;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed down");
        return (1, answer, startedAt, updatedAt, 1);
    }
}

/// @notice ERC20 that returns garbage from transfer (for L-3) or can be switched to return false.
contract WeirdToken {
    string public name = "Weird";
    string public symbol = "WRD";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public mode; // 0 normal(true), 1 return false, 2 return 2 (malformed bool), 3 return nothing

    function setMode(uint8 m) external {
        mode = m;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }

    function transfer(address t, uint256 a) external returns (uint256) {
        if (mode == 1) return 0;
        if (mode == 2) return 2;
        balanceOf[msg.sender] -= a;
        balanceOf[t] += a;
        if (mode == 3) assembly { return(0, 0) }
        return 1;
    }
}

/// @notice Burns all forwarded gas on receive (L-2 griefing check).
contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}

/// @notice ERC-1271 smart wallet that approves digests signed by its EOA owner.
contract Mock1271Wallet {
    address public immutable signer;

    constructor(address s) {
        signer = s;
    }

    receive() external payable {}

    function call(address to, uint256 v, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == signer, "only signer");
        (bool ok, bytes memory r) = to.call{value: v}(data);
        require(ok, "call failed");
        return r;
    }

    function isValidSignature(bytes32 h, bytes calldata sig) external view returns (bytes4) {
        (bytes32 r, bytes32 s) = abi.decode(sig[:64], (bytes32, bytes32));
        uint8 v = uint8(sig[64]);
        return ecrecover(h, v, r, s) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
