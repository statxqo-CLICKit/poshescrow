# POSH Escrow — Test Report, 2026-10-31

Run: Sat 2026-10-31 ~18:40–19:05 PDT. Contracts at tag `v0.2-audit-ready` (working tree: README.md modified, DEPLOYED-base-sepolia.md and deployed-config.json untracked; no `src/` or `test/` changes). Toolchain: forge 1.8.7 (reinstalled via foundryup), solc 0.8.24, via_ir. Node v22.23.3.

**Overall: PASS.** Every functional check passed. The only red lines are three expected reverts in the e2e script itself (see 2).

| # | Suite | Result | Counts |
|---|-------|--------|--------|
| 1 | Foundry unit, fuzz and invariant tests (`forge test`) | PASS | 137/137 passed, 0 failed, 0 skipped (13 suites) |
| 1b | Coverage (`forge coverage --report summary --ir-minimum`) | Done | `src/` only: 92.9% branch (237/255), all `src` lines 100% except FMNYRewards 99.4%. The table's Total row, which counts script/ and tests too: 97.91% lines, 97.02% stmts, 89.68% branch, 97.37% funcs |
| 2 | Base Sepolia live e2e (`work/e2e/e2e.sh`) | PASS (core flows) | 15/15 contract-flow transactions succeeded (status 0x1); 3 expected reverts |
| 3 | Assistant worker (`node --test test/worker.test.js`) | PASS | 9/9 passed, 0 failed (no deps needed) |
| 4 | Live HTTP checks | PASS | 3/3 |

## 1. Contracts
- 137 tests passed, matching the expected 137. Logs: `compliance/audit/raw/forge-test-2026-10-31.log`, `compliance/audit/raw/forge-coverage-2026-10-31.log`.
- Per-contract branch coverage: PoshEscrow 92.17% (106/115), FMNYRewards 93.06%, FMNYSale 100%, ProofVault 100%, FMNYDistributor 100%, TrustPassport 85.71%, PoshProfiles 75% (6/8), FMNY 0/1 (one trivial branch). The `src/` aggregate of 92.9% matches the earlier ~92.5% figure. The lower 89.68% Total also counts script/Deploy.s.sol (44%) and test mocks.

## 2. Base Sepolia e2e
The script ran as buyer A `0xEE70…5d9F` (deployer) and seller B `0xAc10…1cf1`. Log: `work/e2e/e2e.log`; the previous run's log is saved as `work/e2e/e2e.prev.log`.
- Passed: fundB, createDeal → markDelivered → release (deal 5), createDeal2 → sellerRefund (deal 6), createDeal3 → dispute (deal 7), ProofVault commitFiling → file (record owner = seller B), createHandoff → markDelivered → releaseHandoff (deal 8; vault record moved to buyer A). The TrustPassport for B went from 2/1/1 to 4/2/2 at a score of 10000.
- Expected reverts. These come from the script, not the contracts:
  - `profileRegister` → `AlreadyRegistered`: seller B registered a profile in an earlier run, and the contract allows one profile per address.
  - `withdrawB` / `withdrawA` → `NothingToWithdraw`: ETH payouts are pushed directly, and `pendingWithdrawals` only fills when a push fails. pendingB = 0, so the revert is correct. The previous run showed the same thing.
- Gas: before the run, the deployer had 0.0000519 ETH and seller B had 0.0000376 ETH. The run cost about 0.0000478 (0.00004 sent to B plus about 0.0000078 in fees, at a gas price of about 0.006 gwei). **The deployer now holds 0.0000058 ETH, which is not enough for another e2e run. A full run needs about 0.000048.** It needs test ETH before the next run, or the script's 0.00004 `fundB` top-up could be dropped (B has enough for its own gas). No faucets were tried.

## 3. Assistant worker
All 9 node:test cases passed in about 0.5 s, including the AI-error fallback and the non-POST rejection.

## 4. Live checks
- https://poshescrow.pages.dev → HTTP 200.
- https://poshescrow.pages.dev/token/tokenlist.json → HTTP 200 and contains `"symbol": "FMNY"`.
- POST https://posh-assistant.statxqo.workers.dev with `{"messages":[{"role":"user","content":"What is POSH?"}]}` → HTTP 200 with a non-empty reply describing POSH as a P2P escrow on Base, testnet, unaudited.

## Actions taken
No deploys and no contract, site or worker edits. The only on-chain activity was e2e.sh's own testnet transactions. No private keys were printed.
