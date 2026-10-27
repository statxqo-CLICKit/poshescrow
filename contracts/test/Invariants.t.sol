// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {PoshEscrow} from "../src/PoshEscrow.sol";
import {FMNYRewards} from "../src/FMNYRewards.sol";
import {MockUSDC, MockAggregator} from "./mocks/MockUSDC.sol";

/// @notice Random-walk handler over the escrow state machine.
contract EscrowHandler is Test {
    PoshEscrow public escrow;
    MockUSDC public usdc;
    address public arbiter;
    address[4] public actors;
    uint256[] public ids;
    bool public doubleTerminal; // set if a terminal deal ever changed status again
    uint256 public calls;

    constructor(PoshEscrow e, MockUSDC u, address arb) {
        escrow = e;
        usdc = u;
        arbiter = arb;
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(0xC000 + i));
            vm.deal(actors[i], 1_000_000 ether);
            u.mint(actors[i], 1e15);
            vm.prank(actors[i]);
            u.approve(address(e), type(uint256).max);
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function _status(uint256 id) internal view returns (uint8 s) {
        (,,,,,,,, s,,) = escrow.getDeal(id);
    }

    function _terminal(uint8 s) internal pure returns (bool) {
        return s == 3 || s == 4 || s == 6;
    }

    function _pick(uint256 seed) internal view returns (uint256 id, address b, address s) {
        id = ids[seed % ids.length];
        (b, s,,,,,,,,,) = escrow.getDeal(id);
    }

    function _guard(uint256 id, uint8 before) internal {
        if (_terminal(before) && _status(id) != before) doubleTerminal = true;
    }

    function create(uint256 a, uint256 bi, uint256 si, bool useUsdc) external {
        address b = actors[bi % 4];
        address s = actors[si % 4];
        if (b == s) s = actors[(si + 1) % 4];
        uint64 dl = uint64(vm.getBlockTimestamp() + 3 days);
        uint256 id;
        vm.startPrank(b);
        if (useUsdc) {
            a = bound(a, 1e6, 1e12);
            id = escrow.createDeal(s, bytes32(a), address(usdc), a, dl, address(0));
        } else {
            a = bound(a, 1e9, 100 ether);
            id = escrow.createDeal{value: a}(s, bytes32(a), address(0), a, dl, address(0));
        }
        vm.stopPrank();
        ids.push(id);
        calls++;
    }

    function act(uint256 seed, uint8 action, bool flag) external {
        if (ids.length == 0) return;
        (uint256 id, address b, address s) = _pick(seed);
        uint8 before = _status(id);
        action = action % 10;
        address who;
        bytes memory data;
        if (action == 0) (who, data) = (s, abi.encodeCall(PoshEscrow.markDelivered, (id)));
        else if (action == 1) (who, data) = (b, abi.encodeCall(PoshEscrow.release, (id)));
        else if (action == 2) (who, data) = (b, abi.encodeCall(PoshEscrow.refund, (id)));
        else if (action == 3) (who, data) = (s, abi.encodeCall(PoshEscrow.sellerClaim, (id)));
        else if (action == 4) (who, data) = (s, abi.encodeCall(PoshEscrow.sellerRefund, (id)));
        else if (action == 5) (who, data) = (flag ? b : s, abi.encodeCall(PoshEscrow.dispute, (id)));
        else if (action == 6) (who, data) = (arbiter, abi.encodeCall(PoshEscrow.acceptDeal, (id)));
        else if (action == 7) (who, data) = (arbiter, abi.encodeCall(PoshEscrow.rule, (id, flag)));
        else if (action == 8) (who, data) = (seed % 2 == 0 ? b : s, abi.encodeCall(PoshEscrow.settle, (id, flag)));
        else (who, data) = (flag ? b : s, abi.encodeCall(PoshEscrow.resolveTimeout, (id)));
        vm.prank(who);
        (bool ok,) = address(escrow).call(data);
        ok; // reverts are expected for invalid transitions
        _guard(id, before);
        calls++;
    }

    function warp(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1, 20 days));
    }

    /// @dev Sum of amounts of all non-terminal deals in `token`.
    function openSum(address token) external view returns (uint256 sum) {
        for (uint256 i; i < ids.length; ++i) {
            (,,, address t, uint256 amt,,,, uint8 st,,) = escrow.getDeal(ids[i]);
            if (t == token && !_terminal(st)) sum += amt;
        }
    }
}

contract EscrowInvariants is BaseTest {
    EscrowHandler h;

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        escrow.setHooks(address(passport), address(0)); // isolate escrow accounting
        h = new EscrowHandler(escrow, usdc, arbiter);
        targetContract(address(h));
    }

    function invariant_ethBalanceEqualsOpenDealsPlusPending() public view {
        assertEq(address(escrow).balance, escrow.totalLocked(address(0)) + escrow.totalPending(address(0)));
        assertEq(escrow.totalLocked(address(0)), h.openSum(address(0)));
    }

    function invariant_usdcBalanceEqualsOpenDealsPlusPending() public view {
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalLocked(address(usdc)) + escrow.totalPending(address(usdc)));
        assertEq(escrow.totalLocked(address(usdc)), h.openSum(address(usdc)));
    }

    function invariant_noDoubleRelease() public view {
        assertFalse(h.doubleTerminal());
    }
}

/// @notice Random-walk handler that hammers the rewards hook as the escrow would (sybils, big fees, time).
contract RewardsHandler is Test {
    FMNYRewards public rewards;
    MockAggregator public feed;
    address public usdc;
    uint256 public calls;

    constructor(FMNYRewards r, MockAggregator f, address u) {
        rewards = r;
        feed = f;
        usdc = u;
    }

    function notify(uint256 bi, uint256 si, uint256 amount, bool useUsdc) external {
        address b = address(uint160(0xD000 + (bi % 200)));
        address s = address(uint160(0xD000 + (si % 200)));
        address tok = useUsdc ? usdc : address(0);
        amount = useUsdc ? bound(amount, 1, 1e13) : bound(amount, 1, 10_000 ether);
        vm.prank(rewards.escrow());
        rewards.notifyDeal(b, s, tok, amount / 100, amount);
        calls++;
    }

    function claim(uint256 ui) external {
        address u = address(uint160(0xD000 + (ui % 200)));
        if (rewards.claimable(u) == 0) return;
        vm.prank(u);
        rewards.claim();
    }

    function warp(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1 hours, 120 days));
        feed.set(3000e8, vm.getBlockTimestamp());
    }
}

contract RewardsInvariants is BaseTest {
    RewardsHandler h;

    function setUp() public override {
        super.setUp();
        // most generous parameters the bounds allow
        vm.prank(owner);
        rewards.setParams(5_000, PRICE, 0.001 ether, 10_000 ether, 250_000 ether);
        h = new RewardsHandler(rewards, feed, address(usdc));
        targetContract(address(h));
    }

    function invariant_emittedWithinSchedule() public view {
        uint256 cur = rewards.currentEpoch();
        uint256 maxAllowed;
        for (uint256 e; e <= cur; ++e) {
            assertLe(rewards.emittedInEpoch(e), rewards.epochBudget(e));
            maxAllowed += rewards.epochBudget(e);
        }
        assertLe(rewards.totalEmitted(), maxAllowed);
        assertLe(rewards.totalEmitted(), 37_440_000 ether);
    }

    function invariant_owedCoveredByBalance() public view {
        assertLe(rewards.totalOwed(), fmny.balanceOf(address(rewards)));
        assertEq(fmny.balanceOf(address(rewards)) + (rewards.totalEmitted() - rewards.totalOwed()), 40_000_000 ether);
    }
}
