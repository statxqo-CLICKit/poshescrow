# FMNY Rewards Economics (v0.2)

Contract: `src/FMNYRewards.sol`. Deploy parameters: `script/Deploy.s.sol`. Tests: `test/Rewards.t.sol`,
`test/SelfReviewRegression.t.sol` (H-2), `test/Invariants.t.sol` (`invariant_emittedWithinSchedule`,
`invariant_owedCoveredByBalance`). Testnet only until audit and legal review are complete.

FMNY rewards are a **rebate of part of the protocol fee**, not a yield on deposits. A reward is credited only when an
**undisputed** deal is released to the seller and a fee was charged:

- `PoshEscrow.release` (buyer releases), `sellerClaim` (seller collects after the review window), and handoff
  releases (`releaseHandoff`, `releaseHandoffWithSig`, handoff `sellerClaim`).
- **No reward** for refunds, arbiter rulings (`rule`), mutual settlement (`settle`), or timeout resolutions
  (`resolveTimeout`). Regression: `test_L10_noRewardsOnSettleOrRule`.
- The escrow calls `notifyDeal` inside `try/catch`, and `notifyDeal` never reverts for business reasons (it emits
  `RewardSkipped(reason)`), so rewards can never block a payout.

## 1. Formula

```
feeWei        = fee valued in ETH-wei
                  ETH deal:  fee as is (no oracle needed: the reference price is in ETH)
                  USDC deal: fee * 10^(18-6) * 10^feedDecimals / ETHUSD   (Chainlink ETH/USD)
rebate(era)   = rebateBps >> era                      (halves every era, like the budget)
total FMNY    = feeWei * rebate(era) / 10_000 * 1e18 / refPriceWei
buyer reward  = total / 2 ; seller reward = total - total/2   (then caps below)
```

Deployed values: protocol fee `feeBps = 100` (1%, max 5%), `rebateBps = 2_500` (25%),
`refPriceWei = floorPriceWei = 1e13` (0.00001 ETH per FMNY = the pre-sale price).

**Value bound.** At the sale price, the FMNY credited for a deal is worth `rebate(era) x fee`, i.e. at most
25% of the fee at deploy (hard ceiling 50%, `MAX_REBATE_BPS`), and less every era. `refPriceWei` can never be set
below `floorPriceWei`, so governance cannot make rewards cheaper than the sale price.
Fuzz test: `testFuzz_rewardValueNeverExceedsRebateOfFee`.

Example (era 0, ETH/USD 3,000): a 100 USDC deal pays a 1 USDC fee = 0.000333 ETH; 25% of that at 0.00001 ETH/FMNY
= 8.33 FMNY in total (4.17 buyer, 4.17 seller). In v0.1 the same fee earned 100,000 FMNY
(`test_H2_usdcWashTradeNoLongerProfitable`).

## 2. Caps and eligibility (enforced on every credit, whatever the parameters)

| Guard | Deployed | Hard bound in code |
|---|---|---|
| Rebate share of fee value | 25% | <= 50% (`MAX_REBATE_BPS`) |
| Reference price (wei/FMNY) | 1e13 | >= `floorPriceWei` (1e13, immutable) |
| Per-wallet daily cap (UTC day) | 1,000 FMNY | <= 10,000 (`MAX_DAILY_CAP`), <= lifetime cap |
| Per-wallet lifetime cap | 50,000 FMNY | <= 250,000 (`MAX_LIFETIME_CAP`) |
| Minimum deal size (ETH-equivalent) | 0.01 ETH | 0.001 - 10 ETH |
| Same buyer/seller pair | rewarded at most once per 7-day epoch | fixed |
| Same wallet as buyer and seller | never rewarded | fixed (escrow also rejects it) |
| PoshProfiles profile, both wallets | at least 3 days old | <= 30 days (`MAX_PROFILE_AGE`) |
| Global budget per epoch | 180,000 FMNY in era 0 | immutable schedule, see 3 |
| Pool | 40,000,000 FMNY | credits pro-rata if the epoch budget or pool is short |
| Oracle (USDC deals only) | Chainlink ETH/USD, 1h staleness, $100 - $100,000 band, optional L2 sequencer check | fails **closed**: no reward while the price is unusable |

Settlement delay (**weekly unlock**): FMNY earned during an epoch is `locked` until that epoch ends, then becomes
`claimable`. Claims are never paused. Parameters are changed only by the owner, which on deploy is a
48-hour `TimelockController` controlled by `OWNER_MULTISIG`; the guardian can only pause new credits.

## 3. Emission schedule

```
EPOCH            = 7 days
EPOCHS_PER_ERA   = 104            (~2 years)
epochBudget(e)   = 180,000 FMNY >> (e / 104)     for era < 64, else 0
```

| Era | Years (approx.) | Per week | Per era |
|---|---|---|---|
| 0 | 0 - 2 | 180,000 | 18,720,000 |
| 1 | 2 - 4 | 90,000 | 9,360,000 |
| 2 | 4 - 6 | 45,000 | 4,680,000 |
| 3 | 6 - 8 | 22,500 | 2,340,000 |
| ... | ... | halves | halves |

Maximum total emission = 104 x 180,000 x (1 + 1/2 + 1/4 + ... , 64 terms) = **37,440,000 FMNY**
(the 64-term sum computed in wei rounds to 37.44M). This is below the 40M pool, so the schedule can never empty the
pool; at least ~2.56M FMNY is never emitted by the schedule and returns to the treasury if `endRewards()` is called.
Tests: `test_scheduleHalvesAndSumsBelowPool`, `test_epochBudgetEnforcedAcrossSybils`,
`invariant_emittedWithinSchedule`.

Note: these are **ceilings**. Actual emission is driven by real fee volume; at a 1% fee and 25% rebate, emitting a
full era-0 week (180,000 FMNY) requires 7.2 ETH of fees, i.e. ~720 ETH of eligible deal volume in that week.

## 4. Farming (wash-trading) cost math

An attacker controls both buyer and seller wallets (so collects 100% of `total`) and pays the fee.

```
FMNY earned per unit of fee     = rebate / refPrice = 0.25 / 0.00001 ETH = 25,000 FMNY per 1 ETH of fee
Value at the sale price         = 0.25 x fee            -> loses 75% of every fee, plus gas
Break-even market price         = refPrice / rebate = 0.00001 / 0.25 = 0.00004 ETH per FMNY (4x the sale price)
Deal volume per FMNY            = (1 / 25,000) / 1% = 0.004 ETH of volume per FMNY
```

| Target | Fee needed | Deal volume (1% fee) | Value at sale price | Net at sale price |
|---|---|---|---|---|
| 1,000 FMNY (one wallet's daily cap) | 0.04 ETH | 4 ETH | 0.01 ETH | -0.03 ETH |
| 2,000 FMNY (one pair, both wallets at daily cap) | 0.08 ETH | 8 ETH | 0.02 ETH | -0.06 ETH |
| 180,000 FMNY (an entire era-0 weekly budget) | 7.2 ETH | 720 ETH | 1.8 ETH | -5.4 ETH |
| 50,000 FMNY (one wallet's lifetime cap) | 2 ETH | 200 ETH | 0.5 ETH | -1.5 ETH |

Additional friction that the table ignores:

- **One reward per pair per week**: to take a 180,000 FMNY weekly budget at 2,000 FMNY per pair needs 90 distinct
  wallet pairs, each with a PoshProfiles profile at least 3 days old, each deal at least 0.01 ETH.
- **Weekly unlock**: rewards cannot be dumped in the same week they are farmed.
- **Halving**: in era 1 the rebate is 12.5%, so the break-even price doubles to 0.00008 ETH; era 2: 0.00016 ETH.
- **Governance response**: if FMNY trades well above the sale price, the timelocked owner can raise `refPriceWei`
  (never lower than the floor) or lower `rebateBps`, moving break-even up; the guardian can pause credits at once.
- Even if farming became profitable, losses to the protocol are bounded by the weekly budget and the per-wallet
  caps (`test_H2_poolDrainBoundedByEpochBudget`).

Conclusion: at or near the pre-sale price, farming is strictly loss-making (it buys FMNY at 4x the sale price via
fees that go to the treasury). It only pays if the market price exceeds 4x the sale price in era 0, and even then
emission is capped per wallet, per pair, per week and in total.

## 5. Open items for the auditor / legal review

- Whether a fee rebate in a token is treated as a rebate, a reward, or something else in each target jurisdiction
  (see `compliance/legal/LEGAL-REVIEW-BRIEF.md`).
- Oracle choice and band values for Base mainnet (sequencer feed `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`).
- Sybil resistance beyond profile age (e.g. Trust Passport history) if real-value farming appears.
