# POSH Escrow Platform: Smart Contracts v0.2 (Base Sepolia, chainId 84532)

> **UNAUDITED. Testnet only.** v0.2 fixes every finding of the internal self-review
> (`compliance/audit/findings-selfreview.md`), but no third party has audited these contracts yet. Do not hold real
> value with them until a professional audit and legal review are complete.

Foundry project · Solidity 0.8.24 (pinned, `via_ir`, optimizer 200, `cancun`) · OpenZeppelin Contracts v5.1.0 ·
137 tests (unit, fuzz, invariant) · coverage: 99.86% lines, 98.68% statements, 92.94% branches, 100% functions.

## Contracts

| Contract | What it does |
|---|---|
| `FMNY.sol` | ERC20 "FMoney Protocol" / "FMNY", 18 decimals. Fixed 100,000,000 supply minted once to the distributor; no mint after that. |
| `FMNYDistributor.sol` | Deploys FMNY, then a one-time `distribute(rewards, sale, treasury, team1, team2, advisor)`: **40%** Rewards, **15%** Sale, **15% + 10%** (treasury + liquidity) to the treasury multisig, **15% team split equally between two developer beneficiaries: 7.5% each in two `VestingWallet`s (`teamVesting`, `teamVesting2`) with the same 12-month cliff then 24 months linear**, and **5%** advisor `VestingWallet` (6-month cliff, then 18 months linear). Team beneficiaries must be non-zero and different. Ownership is renounced after distribution. |
| `ProofVault.sol` | Commit-reveal filing of a `bytes32` fingerprint with a label (<= 64 bytes): `commitFiling(commitmentFor(hash, filer, salt))`, then in a later block (within 24h) `file(hash, label, salt)`. Co-sign once per wallet (not the holder). Only the holder, or the escrow while settling a handoff, can transfer a filing. `setEscrow` is set-once; ownership is renounced at deploy. |
| `TrustPassport.sol` | Per-wallet record: completed, disputes, refunds, on-time bps, member-since. Only the escrow writes (set-once); ownership renounced at deploy. |
| `FMNYRewards.sol` | Holds the 40M pool. Fee-rebate rewards for **undisputed releases only**, valued in ETH (USDC via Chainlink ETH/USD, failing closed), 25% of fee value at the sale price, split buyer/seller, with daily/lifetime caps, min deal size, one reward per pair per week, 3-day profile age, a weekly budget of 180,000 FMNY halving every ~2 years (max 37.44M), and a weekly unlock. See `docs/REWARDS-ECONOMICS.md`. |
| `FMNYSale.sol` | Allowlisted ETH pre-sale with immutable `startTime`/`endTime`, soft/hard cap, min buy, per-wallet max. **Anyone** may `finalize()` after the end or once the hard cap is reached (no owner early-finalize). Pull-based `withdrawRaised` so a bad treasury cannot freeze the sale. Claims 90 days after finalize; refunds if the soft cap is missed or the guardian cancels. |
| `PoshEscrow.sol` | ETH and allow-listed ERC20 (USDC) escrow with deliver/release, 72h review → `sellerClaim`, refund after deadline, seller refund, disputes with approved arbiters, escalation and timeout (no 50/50 split), mutual `settle`, ProofVault handoffs with seller "handed over" mark and 24h buyer confirm window, EIP-712 buyer receipts, gas-capped pushes with a pull fallback, guardian pause of new deals. 1% fee (max 5%, snapshotted per deal). |
| `PoshProfiles.sol` | On-chain sign-up: unique 3–20 char `a-z 0-9 _` usernames, one per address, plus a metadata URI and `createdAt` (used for the rewards profile-age check). |

### Escrow lifecycle (status enum: 0 None · 1 Funded · 2 Delivered · 3 Released · 4 Refunded · 5 Disputed · 6 Resolved)

- `createDeal(seller, termsHash, token, amount, deadline, arbiter)`: `token = 0x0` is ETH (`msg.value == amount`); for USDC approve the **exact** amount first. `deadline` is absolute unix time, now + 2h to now + 720h. `arbiter = 0x0` uses the default arbiter; any other arbiter must pass `isValidArbiter(arbiter, buyer, seller)` (default arbiter or owner-approved, never a party).
- `markDelivered(id)` / `markDeliveredWithProof(id, proofHash)` (seller, **only up to the deadline**) → `release` (buyer) or `sellerClaim` (seller) after the 72h review with no dispute.
- `refund` (buyer): after the deadline, only while still Funded. `sellerRefund` (seller): Funded, Delivered or Disputed.
- `dispute`: buyer while Funded or within the review window; seller while Funded up to the deadline, or Delivered. → `acceptDeal` + `rule(id, paySeller)` by the arbiter.
- `escalate(id)` (party): hand a dispute to the default arbiter if the custom arbiter was de-listed, did not accept within 7 days, or did not rule within 30 days. `resolveTimeout(id)` (party): if the default arbiter has not ruled 30 days after the dispute/escalation, the pre-dispute outcome applies (delivered on time → seller paid; never delivered → buyer refunded).
- `settle(id, paySeller)`: executes when both parties choose the same outcome; votes reset on every state change.
- Handoffs: `createHandoff(seller, termsHash, itemHash, window)` (ETH, window 2–24h in seconds; `itemHash` must be filed and held by the seller). The seller marks handed over (`markDelivered*`) before the window ends; the buyer then has **24h** to `releaseHandoff(id, itemHash)` or dispute, after which the seller can `sellerClaim` (filing moves to the buyer in the same tx). `releaseHandoffWithSig(id, buyerSig)` settles with a buyer-signed EIP-712 `HandoffReceipt`. The buyer can `refund` only if the seller never marked handed over before the window closed.
- Failed pushes go to `pendingWithdrawals[token][user]` (read as `pendingWithdrawals(token, user)`), collected with `withdraw(token)`.
- Rewards are notified only on `release`, `sellerClaim` and handoff releases. Never on `rule`, `settle`, `resolveTimeout` or refunds.

## Build and test

```bash
curl -L https://foundry.paradigm.xyz | bash && ~/.foundry/bin/foundryup
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git   # lib/ is not in the zip
forge build                      # full via_ir compile takes ~2-3 minutes
forge test                       # 137 tests
forge coverage --ir-minimum --report summary --no-match-coverage "(test|script/|mocks)"
python3 tools/export_abis.py     # regenerates abis.json and checks every front-end signature (incl. v0.2 additions)
```

## Deploy to Base Sepolia

1. `cp .env.example .env` and fill it in (never commit `.env`; it is in `.gitignore`):
   - `BASE_SEPOLIA_RPC=https://sepolia.base.org`
   - `PRIVATE_KEY=` (throwaway testnet deployer) or, better, `cast wallet import posh-deployer --interactive` and use `--account posh-deployer`.
   - `BASESCAN_API_KEY=` for `--verify`
   - **Required:**
     - `OWNER_MULTISIG=`: becomes sole proposer/executor/canceller of the 48h `TimelockController` that owns Escrow, Rewards and Sale. Must not be the deployer.
     - `TREASURY=`: multisig receiving fees, sale ETH and the 25% treasury + liquidity FMNY.
     - `DEFAULT_ARBITER=`
     - `TEAM_BENEFICIARY=`: Team 1 developer, 7.5% team vesting (`teamVesting`).
     - `TEAM_2_BENEFICIARY=`: Team 2 developer, 7.5% team vesting (`teamVesting2`). Must differ from `TEAM_BENEFICIARY`.
     - `ADVISOR_BENEFICIARY=`: 5% advisor vesting (currently the owner wallet on testnet).
   - Optional: `GUARDIAN` (default `OWNER_MULTISIG`), `USDC` (default Circle Base Sepolia `0x036CbD53842c5426634e7929541eC2318f3dCF7e`), `ETH_USD_FEED` (default Chainlink Base Sepolia ETH/USD), `SEQUENCER_FEED` (default none), `SALE_START` (default `1792944000` = Sun 2026-10-25 09:00 PDT), `ADMIN_DELAY` (default `172800` = 48h).
2. Fund the deployer with Base Sepolia ETH.
3. Dry run (no broadcast):
   ```bash
   set -a; source .env; set +a
   forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY
   ```
   Check the printed CONFIG: `teamVestingAddress` and `teamVesting2Address` must both be present.
4. Deploy and verify:
   ```bash
   forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC \
     --private-key $PRIVATE_KEY --broadcast \
     --verify --etherscan-api-key $BASESCAN_API_KEY --chain 84532
   # or: --account posh-deployer --sender <deployer address> instead of --private-key
   ```
5. Note: `SALE_START` must be in the future at deploy time (the sale constructor rejects a past start).

What the script does: Timelock (bootstrap) → Distributor (creates FMNY) → PoshProfiles, ProofVault, TrustPassport, FMNYRewards, PoshEscrow → set-once wiring (`setEscrow` ×3, `setProfiles(profiles, 3 days)`, guardians) → FMNYSale → `distribute(rewards, sale, TREASURY, TEAM_BENEFICIARY, TEAM_2_BENEFICIARY, ADVISOR_BENEFICIARY)` (creates the three VestingWallets) → ProofVault, TrustPassport and Distributor renounce ownership → Escrow, Rewards and Sale move to the timelock (two-step, accepted in one bootstrap batch), delay set to `ADMIN_DELAY`, all timelock roles handed to `OWNER_MULTISIG`; the deployer keeps nothing.

### After deploy
- Allowlist sale buyers: `sale.setApproved([addr1, ...], true)` (owner via timelock, or the guardian directly).
- Approve extra arbiters: `escrow.setArbiterApproved(addr, true)` via a timelock proposal (48h).
- `sale.finalize()`: anyone, after `endTime` or once the hard cap is reached. Then `sale.withdrawRaised(treasury)` and `returnUnsold()`.
- Vesting: beneficiaries call `release(fmny)` on their `VestingWallet` after the cliff.

## Pasting the CONFIG into the page

The script prints:

```
===== POSH CONFIG (paste into the front end) =====
{
  "chainId": 84532,
  "escrowAddress": "0x…", "vaultAddress": "0x…", "passportAddress": "0x…", "tokenAddress": "0x…",
  "rewardsAddress": "0x…", "saleAddress": "0x…", "profilesAddress": "0x…",
  "usdcAddress": "0x036CbD53842c5426634e7929541eC2318f3dCF7e", "treasuryAddress": "0x…", "defaultArbiter": "0x…",
  "distributorAddress": "0x…", "teamVestingAddress": "0x…", "teamVesting2Address": "0x…", "advisorVestingAddress": "0x…",
  "timelockAddress": "0x…", "ownerMultisig": "0x…", "guardianAddress": "0x…", "ethUsdFeed": "0x…"
}
===== END CONFIG =====
```

Paste it in the site with More → Paste CONFIG (unknown keys are ignored), or replace the `CONFIG` object in the page
script. Addresses are also in `broadcast/Deploy.s.sol/84532/run-latest.json`. ABIs: `abis.json`, keyed by contract
name (e.g. `abis.PoshEscrow`).

## Known limitations
- **Unaudited.** No formal verification. Self-review findings are fixed with regression tests, but an external audit is still required.
- Arbiters are trusted for the deals they rule on; the registry is curated by the timelocked owner. There is no arbiter fee or staking yet.
- Rewards: sybil resistance relies on profile age, pair-per-week, caps and fee cost (farming loses 75% of fees at the sale price; see `docs/REWARDS-ECONOMICS.md`).
- USDC can be paused/blacklisted by Circle; affected payouts defer to `pendingWithdrawals`. Fee-on-transfer and rebasing tokens are rejected or unsupported; allow-list standard tokens only.
- `fee = amount * bps / 10000` rounds down, so tiny deals may pay no fee (and earn no reward).
- `OWNER_MULTISIG` is an EOA on testnet; use a Safe before mainnet.

## Live deployment: Base Sepolia testnet (chain 84532)

> **Testnet only.** Deployed 2026-10-24 to Base Sepolia. Test ETH has no value. No real-money sale, deposit or investment is offered; FMNY is a test reward token, not an investment, and no return, price or listing is promised. Round One (testnet) opens Sun 2026-10-25 09:00 PT (`startTime` 1792944000), ends 2026-11-24 16:00 UTC.
>
> **Audit status: unaudited.** Self-reviewed: 137/137 Foundry tests, Slither static analysis, tag `v0.2-audit-ready`. Independent audit and legal review required before any mainnet use.

| Contract | Address | Explorer |
|---|---|---|
| PoshEscrow | `0x5600c38d7f00dd06719ecd7a4d5b5cd9f40f340d` | [Basescan](https://sepolia.basescan.org/address/0x5600c38d7f00dd06719ecd7a4d5b5cd9f40f340d) |
| ProofVault | `0xeac142c2836ea70cdfb8237b20d7e58291a869b5` | [Basescan](https://sepolia.basescan.org/address/0xeac142c2836ea70cdfb8237b20d7e58291a869b5) |
| TrustPassport | `0x80412d3d359892fd383419848ea8dc24d76d60db` | [Basescan](https://sepolia.basescan.org/address/0x80412d3d359892fd383419848ea8dc24d76d60db) |
| PoshProfiles | `0x94991a934164013dab8e3fe1b92676267b86a114` | [Basescan](https://sepolia.basescan.org/address/0x94991a934164013dab8e3fe1b92676267b86a114) |
| FMNY (test token) | `0x6ea28bc7e57b4032fa673bacf6d794d8c68dca75` | [Basescan](https://sepolia.basescan.org/address/0x6ea28bc7e57b4032fa673bacf6d794d8c68dca75) |
| FMNYRewards | `0x3784091fc0063a567f11c90dfcbe4f1e1f6cff67` | [Basescan](https://sepolia.basescan.org/address/0x3784091fc0063a567f11c90dfcbe4f1e1f6cff67) |
| FMNYSale | `0xbf5a6455204ee6b69e263bb55c93b64fee4f48ae` | [Basescan](https://sepolia.basescan.org/address/0xbf5a6455204ee6b69e263bb55c93b64fee4f48ae) |
| FMNYDistributor | `0xc88bd7742d0edac28488a7952d4169e3e719ef57` | [Basescan](https://sepolia.basescan.org/address/0xc88bd7742d0edac28488a7952d4169e3e719ef57) |
| TimelockController | `0xdd172a2f322b20281cbf6d50869e5ae6292280d8` | [Basescan](https://sepolia.basescan.org/address/0xdd172a2f322b20281cbf6d50869e5ae6292280d8) |
| Team vesting 1 | `0x62303500ab0610a9798b094532c7242de5ba8776` | [Basescan](https://sepolia.basescan.org/address/0x62303500ab0610a9798b094532c7242de5ba8776) |
| Team vesting 2 | `0x3587c6b104f417c51c3d989c1b4dd9aa2efc31c1` | [Basescan](https://sepolia.basescan.org/address/0x3587c6b104f417c51c3d989c1b4dd9aa2efc31c1) |
| Advisor vesting | `0x84b2e5c1b596ddef146fefb2ebf5de907186b4f3` | [Basescan](https://sepolia.basescan.org/address/0x84b2e5c1b596ddef146fefb2ebf5de907186b4f3) |
| Treasury | `0xaDF3F583C3E093A133EEcfF977573C3e4AA9851d` | [Basescan](https://sepolia.basescan.org/address/0xaDF3F583C3E093A133EEcfF977573C3e4AA9851d) |
| Default arbiter | `0x108595a5D7CE3e46027ee2DaD62f4780F7fE34aF` | [Basescan](https://sepolia.basescan.org/address/0x108595a5D7CE3e46027ee2DaD62f4780F7fE34aF) |
| Owner/guardian multisig | `0x1e4460d71eE59AbC307967D13C95d1874F2adb52` | [Basescan](https://sepolia.basescan.org/address/0x1e4460d71eE59AbC307967D13C95d1874F2adb52) |
| USDC (Circle test) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | [Basescan](https://sepolia.basescan.org/address/0x036CbD53842c5426634e7929541eC2318f3dCF7e) |

Ownership: PoshEscrow, FMNYRewards and FMNYSale are owned by the TimelockController; the guardian multisig can pause only. Front-end CONFIG: `deployed-config.json`. Broadcast record: `broadcast/Deploy.s.sol/84532/run-latest.json`.
