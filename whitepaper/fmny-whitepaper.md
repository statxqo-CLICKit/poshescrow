---
title: "POSH Escrow Platform and the FMoney Protocol (FMNY)"
subtitle: "White Paper, Draft v0.2: Tokenomics, Rewards, Records, 30-Day Launch Window, and How It Works"
author: "A Racer X project by Team C.L.I.C.K.it"
date: "23 October 2026 (draft v0.2 for review)"
geometry: margin=1in
fontsize: 11pt
colorlinks: true
---

> **Draft notice.** This is a working draft (v0.2). The tokenomics in section 5 are confirmed by the team and match the v0.2 smart contracts (tag `v0.2-audit-ready`). Nothing in this paper is an offer to sell or a solicitation to buy any token. Final legal language is to be supplied by securities counsel. The current contracts are test versions on Base Sepolia; they have had an internal self-review with all findings fixed, but no external audit yet.

# 1. Summary

POSH is an escrow platform for trading things between people who do not know each other. It does three jobs:

1. **Holds the money** until the seller delivers (Protected Deals and Handoff Mode).
2. **Records a timestamped fingerprint** (hash) of a document or asset record on-chain, showing which wallet filed or now holds it (Proof Vault).
3. **Shows how a wallet behaves** over many deals, with a portable record anyone can check (Trust Passport).

**FMNY (FMoney Protocol token)** is the reward token for using the platform. When an undisputed deal is released, buyer and seller share an FMNY rebate worth part of the protocol fee, within strict caps, from a limited pool. A pre-sale gives approved, eligible wallets an early allocation. Deal records can be exported in ISO 20022-aligned formats for recordkeeping (section 6).

# 2. The problem

- Online and in-person trades between strangers depend on trust neither side can verify. One side always goes first and carries the risk.
- Payment apps offer little protection for goods traded person to person, and chargebacks can be abused by buyers.
- Counterfeits and stolen goods are hard to spot because ownership history rarely travels with the item.
- A good reputation on one marketplace cannot be carried to another.

# 3. The solution: how the platform works

## 3.1 Protected Deals (shipped or delivered goods and services)

1. **Create and fund.** The buyer enters the seller's wallet, the agreed terms, the amount (ETH or USDC), a deadline (2 to 720 hours) and an arbiter: the POSH default arbiter, or an arbiter on the POSH approved list (never the buyer or the seller; the app checks this before funding). The funds move into the escrow contract. Only a hash of the terms goes on-chain, so the terms stay private but provable. The seller sees the arbiter before delivering and can decline the deal by refunding the buyer.
2. **Deliver.** The seller delivers and marks the deal as delivered, optionally with a proof fingerprint. This must happen before the deadline.
3. **Release.** The buyer releases payment, or, if the buyer does nothing for 72 hours after delivery, the seller can claim it. A 1% protocol fee is taken and both sides can earn FMNY (section 5.4).
4. **If something goes wrong.** No delivery by the deadline means the buyer can take a refund. If the two disagree, either can open a dispute; the arbiter rules, or the parties settle between themselves. There is no 50/50 split. If a custom arbiter goes quiet (does not accept within 7 days or rule within 30 days) or is removed from the approved list, either side can escalate to the default arbiter. If the default arbiter has not ruled 30 days after the dispute, either side can close it with the pre-dispute outcome: delivered on time means the seller is paid; never delivered means the buyer is refunded. Arbiter rulings and settlements do not earn FMNY.
5. **Certificate.** Every finished deal produces a shareable Deal Certificate.

## 3.2 Handoff Mode (new: in-person meetups)

Most escrow is built for shipping. Handoff Mode brings protected payment and proof of ownership to face-to-face deals, where scams actually happen.

1. Check the seller's Trust Passport before agreeing to meet.
2. The buyer funds the deal with a short meetup window (2 to 24 hours). The item must already be filed in the Proof Vault and held by the seller.
3. At the meetup the seller shows a Handoff QR code (valid 10 minutes). The buyer scans it, and the app checks the item's Proof Vault fingerprint (serial number, receipt or authenticity card) against the listing.
4. The seller taps **Mark handed over** (optionally with a proof fingerprint such as a meetup photo) before the window closes. From that moment the buyer can no longer take the money back unilaterally.
5. The buyer taps **Release and take ownership**: payment goes to the seller and the Proof Vault filing transfers to the buyer in the same transaction. The buyer can also sign a free receipt at the meetup that lets the seller settle on the spot.
6. **24-hour confirm window.** After the seller marks it handed over, the buyer has 24 hours to release or to open a dispute (for example, wrong item). If the buyer does neither, the seller can claim the payment and the filing moves to the buyer in the same transaction. Either side can dispute a handoff; disputes go to the default arbiter.
7. **No-show.** The buyer can take the money back only if the seller never marked it handed over before the window closed. This is not automatic: the buyer taps *Refund* after the window.

## 3.3 Proof Vault

The user's device computes a SHA-256 fingerprint of a file or text. Only the hash, a public label, the wallet and the time are recorded on-chain; the file never leaves the device. Filing takes two quick steps so nobody can copy a fingerprint from the network and file it first: the app first seals the fingerprint with a secret salt kept on the device, then files it in a later block (within 24 hours). Filings can be co-signed (for example by an appraiser or retailer) and transferred by their holder, and every action stays in a permanent audit trail. A filing proves that a wallet filed (or was handed) a fingerprint at a given time; on its own it is not legal proof of ownership.

## 3.4 Trust Passport

A wallet's history in protected deals (completed deals, disputes, refunds, on-time delivery) is summarised as a passport that anyone can check without an account. A wallet can sign a credential to prove it controls the passport it shares.

## 3.5 Safety by design

- Exact-amount token approvals only, never unlimited approvals, with a one-click revoke.
- A plain-English review appears before the wallet opens; if the wallet shows anything different, the user should reject it.
- Address checks to defeat copy-paste look-alike scams.
- No admin can move escrowed funds or Proof Vault filings. Parameter changes go through a 48-hour public timelock controlled by the owner multisig; a guardian can only pause new deals, pause reward credits or cancel the sale into refund mode.

# 4. Real-world uses

| Use | How POSH helps |
|---|---|
| Luxury resale (bags, watches, sneakers) | Proof Vault carries the authenticity card and receipt; ownership transfers with payment. |
| Marketplace meetups (bikes, phones, consoles) | Handoff Mode: no cash, no "I'll send it later"; the buyer can take the money back if the seller never marks it handed over. |
| Freelance and creative work | Funds held until delivery; milestone terms hashed on-chain; arbiter for disputes. |
| Vehicle and equipment private sales | Title or service-record fingerprints in the vault; buyer verifies before release. |
| Event ticket resale | Payment released only after the ticket transfer is confirmed. |
| Rental and security deposits | Deposit held in escrow and returned or paid out by agreement or arbiter ruling. |
| Collectibles and art | Co-signatures from appraisers build a provenance chain that travels with the piece. |
| Small business B2B orders | Supplier gets paid on delivery; both sides build a portable Trust Passport. |

# 5. FMNY tokenomics

The figures in this section are confirmed by the team and are enforced by the v0.2 contracts on Base Sepolia. They will be re-confirmed after the external audit and legal review, before any mainnet deployment.

## 5.1 Token basics

| Item | Value |
|---|---|
| Name / ticker | FMoney Protocol / FMNY |
| Network | Base (Base Sepolia for testing) |
| Standard | ERC-20, 18 decimals |
| Total supply | 100,000,000 FMNY, fixed, minted once at deployment, no further minting |
| Purpose | Reward for using the platform; utility features listed in 5.5 |

## 5.2 Allocation

| Bucket | Share | Tokens | Unlock |
|---|---|---|---|
| Platform rewards pool | 40% | 40,000,000 | Earned only through released deals; weekly budget halving every ~2 years; at most 37,440,000 can ever be emitted (5.4) |
| Pre-sale | 15% | 15,000,000 | Locked after finalize, then claimable (see 5.3) |
| Ecosystem and treasury | 15% | 15,000,000 | Treasury multisig; grants, arbiter incentives, partnerships |
| Team (two developers, equal shares) | 15% (7.5% + 7.5%) | 15,000,000 (7,500,000 each) | Two vesting contracts on the same schedule: 12-month cliff, then linear over 24 months |
| Liquidity | 10% | 10,000,000 | Held by the treasury multisig; paired at launch if and when listed; no listing is guaranteed |
| Advisors and partners | 5% | 5,000,000 | Vesting contract: 6-month cliff, then linear over 18 months |
| **Total** | **100%** | **100,000,000** | |

Vesting is enforced on-chain by OpenZeppelin VestingWallet contracts created at deployment; nothing vests before the cliff. The team allocation is split equally between the two developers, each with their own vesting contract.

## 5.3 Pre-sale terms

| Term | Value |
|---|---|
| Tokens offered | 15,000,000 FMNY |
| Price | 0.00001 ETH per FMNY |
| Soft cap | 50 ETH (if not reached, every contributor can take a full refund) |
| Hard cap | 150 ETH (sale closes early if reached) |
| Minimum / maximum per wallet | 0.01 ETH / 5 ETH |
| Eligibility | Wallets approved in advance (allowlist), only where the law allows |
| Opening and duration | Opens Sunday 25 October 2026, 9:00 AM PT (fixed start time on-chain); runs 30 days |
| Phases | Buy, Finalize, Lock, Claim |
| Lock after finalize | 90 days; may carry resale restrictions after that |

**How the phases work.** *Buy:* approved wallets contribute ETH between the on-chain start and end times. *Finalize:* anyone can finalize once the sale has ended or the hard cap is reached; the owner cannot end the sale early. If the soft cap was missed (or the guardian cancelled the sale), refunds open instead. *Lock:* tokens are locked for 90 days. *Claim:* contributors claim their FMNY. Raised ETH is withdrawn to the treasury separately, so a treasury problem can never freeze contributions.

## 5.4 Reward mechanics (v0.2)

FMNY rewards are a **rebate of part of the protocol fee**, paid from the 40M rewards pool (no new supply).

- **Fee:** 1% of each deal (can be changed within a 5% maximum through the 48-hour timelock; each deal keeps the fee from when it was created), paid to the treasury.
- **When rewards are earned:** only when an undisputed deal is released to the seller (buyer release, seller claim after the review window, or a handoff release). No rewards on refunds, arbiter rulings, settlements or timeout resolutions.
- **Formula:** reward = fee value in ETH x rebate / reference price, split 50/50 between buyer and seller. The rebate is 25% at launch (hard maximum 50%) and the reference price is the pre-sale price, 0.00001 ETH per FMNY, which can never be set lower. So, at the sale price, a reward is worth at most a quarter of the fee that paid for it. USDC fees are valued with the Chainlink ETH/USD price; if the price is stale or unusable, USDC deals earn nothing until it recovers.
- **Example:** a 100 USDC deal pays a 1 USDC fee. At 3,000 USD per ETH that fee is worth 0.000333 ETH, and the rebate is about 8.33 FMNY in total (about 4.17 each).
- **Caps (per wallet):** 1,000 FMNY per day and 50,000 FMNY lifetime. The same buyer and seller pair is rewarded at most once per week, deals under 0.01 ETH (or its USDC value) earn nothing, and both wallets need a POSH profile at least 3 days old.
- **Weekly unlock:** rewards earned during a week become claimable when that week ends.
- **Emission schedule:** a fixed global budget of 180,000 FMNY per week, halving every 104 weeks (about 2 years); the rebate halves on the same schedule. The most that can ever be emitted is 37,440,000 FMNY, less than the 40M pool. Actual emission depends on real fee volume and is usually far below the budget.
- **Wash trading does not pay at the sale price:** trading with yourself through two wallets costs the full fee and returns rewards worth 25% of it, a 75% loss plus gas. It would only pay if FMNY traded above 4 times the sale price, and even then caps, pair limits, profile age and the weekly budget limit the total. The full cost model is in the contracts documentation (REWARDS-ECONOMICS.md).
- **Changes:** parameters can only be changed within hard limits through the 48-hour timelock; a guardian can pause new credits. Rewards can change or end and have no guaranteed value. Earned rewards stay claimable.

## 5.5 Planned utility (not yet implemented in the v0.2 contracts)

- Fee discounts when fees are paid in, or a balance is held in, FMNY.
- Arbiter staking: arbiters stake FMNY to be listed and can lose part of it for proven bad rulings.
- Passport boosts: verified, long-standing wallets earn a visible badge.
- Governance signalling on fee levels and reward schedules, once the platform is live.

These features need further design, audit and legal review and may change or not happen.

# 6. Records and interoperability (ISO 20022-aligned)

ISO 20022 is the financial messaging standard used by many banks and payment systems. POSH does not send payment messages, but it can **format its deal records the same way**, so that businesses, accountants and, in future, regulated partners can read and reconcile them with familiar tools.

**What POSH exports.** For a deal (from the Deals tab, a handoff receipt, or a batch of completed deals), the app downloads:

- a **camt.054-style XML** debit/credit notification (`BkToCstmrDbtCdtNtfctn`), and
- a **CSV** file with the same fields, for spreadsheets and accounting software.

| POSH data | ISO 20022-aligned field (camt.054-style) | CSV column |
|---|---|---|
| Deal ID | `EndToEndId` (and `NtryRef`) | `end_to_end_id` |
| Amount and currency | `Amt Ccy="USD"`: USDC is booked 1:1 as USD; ETH is shown with a proprietary-currency note and an indicative USD value | `amount_usd`, `asset`, `asset_amount` |
| Parties | `Dbtr` = buyer wallet, `Cdtr` = seller wallet (wallet IDs under a proprietary `WALLET` scheme) | `debtor_wallet`, `creditor_wallet` |
| Timestamps | `CreDtTm` (export time), `BookgDt/DtTm`; deadline and delivery time in the entry notes | `booking_datetime_utc`, `deadline_utc`, `delivered_utc` |
| Status | `Sts/Cd`: `BOOK` for final deals (released, refunded, resolved), `PDNG` for open deals; POSH status (FUNDED, DELIVERED, RELEASED, REFUNDED, DISPUTED, RESOLVED) as a proprietary transaction code | `status`, `posh_status` |
| Transaction hash | `AcctSvcrRef` | `tx_hash` |
| Item or delivery proof | Proof Vault fingerprint in structured remittance information | `proof_vault_hash` |

**Why.** Interoperability (records in a widely used, structured layout) and recordkeeping (a clean, consistent history of each deal for the user's own books and tax records). Exports are produced on the user's device from on-chain data; no personal data beyond wallet addresses is included unless a business user adds it.

**What this is not.** This is **ISO 20022-aligned formatting only**. It is **not ISO 20022 certification** (no such certification exists for a product like POSH), POSH is **not a bank or payment institution**, and POSH has **no regulatory approval** of any kind. Using ISO 20022-style formats does not make POSH, FMNY or any transaction legal, safe or bank-approved. Moving money over real payment rails in ISO 20022 messages would require a regulated partner, identity checks and other obligations that POSH does not have today.

# 7. 30-day launch window

Day 0 is Sunday 25 October 2026, 9:00 AM PT, when the pre-sale opens on-chain (Base Sepolia testnet round).

| When | Milestone |
|---|---|
| Day -14 to -1 | Self-review fixes (done in v0.2); finalize this paper with counsel; open allowlist applications; publish contract addresses |
| Day 0 | Pre-sale opens; platform beta (Protected Deals, Handoff Mode, Proof Vault, Passport) live on Base Sepolia |
| Days 1 to 7 | Community onboarding: tutorial videos, first test deals, bug bounty opens |
| Day 7 | First progress update: amount raised, deals completed, issues fixed |
| Days 8 to 14 | Handoff Mode pilot with local sellers; partner announcements |
| Day 14 | Mid-sale update; soft-cap status |
| Days 15 to 21 | Rewards dashboard live with test rewards; arbiter applications open |
| Days 22 to 29 | Final push; mainnet deployment rehearsal on testnet |
| Day 30 | Sale closes; anyone can Finalize (or refunds open if soft cap missed); lock period begins |
| Day 31 onward | Mainnet planning, audit report, Claim opens after the lock |

# 8. Quick tutorial

**Connect.** Tap *Connect Wallet*. The page asks your wallet (for example MetaMask) to connect and to switch to Base Sepolia, adding it if needed.

**Run a protected deal.**

1. Open *Deals*. Paste the seller's wallet and check it character by character.
2. Write the agreed terms, pick ETH or USDC, enter the amount and deadline, and keep the default arbiter or enter an approved one.
3. Tap *Create deal*. Read the plain-English review, then confirm in your wallet.
4. When the seller marks *I delivered* and you are happy, tap *Release payment* (you have 72 hours to release or dispute). You can both earn FMNY.
5. Need a record? Load the deal and tap *Export loaded deal* for an ISO 20022-aligned XML or CSV file.

**Run a meetup (Handoff Mode).**

1. Check the seller's passport. Fund the deal with a short window.
2. At the meetup, scan the seller's QR. Confirm the fingerprint match. The seller taps *Mark handed over*.
3. Only when the item is in your hands, tap *Release and take ownership*. If something is wrong, dispute within 24 hours.

**File a fingerprint.** Open *Proof Vault*, drop in a file or paste text, add a label, tap *File it* (step 1 seals it), then after the next block tap *File it* again (step 2 files it). Share the hash or transfer the filing when you sell.

**Join the pre-sale.** Open *FMNY Pre-sale\**, read the disclosures, tick the eligibility box, enter an amount and tap *Buy FMNY*. Return after the sale to *Claim*, or *Get refund* if the soft cap was missed.

# 9. Risks and important disclosures

- FMNY may be treated as a security. It is offered only to wallets that have been approved in advance, and only where the law allows.
- Claimed tokens are locked for a set period and may carry resale restrictions after that.
- You can lose everything you contribute. No price, listing, trading volume or liquidity is guaranteed.
- The smart contracts are test versions that have not had an external audit. This paper is not an offer where one would be unlawful.
- Rewards are paid in FMNY from a limited pool, can change or end at any time, and have no guaranteed value.
- Smart contract bugs, wallet compromise, oracle failure, regulatory change and arbiter error are all possible.
- ISO 20022-aligned exports are formatting only: not ISO 20022 certification, and POSH is not a bank or payment institution and has no regulatory approval.
- [Final wording to be supplied by securities counsel.]

# 10. Open decisions for the team

Confirmed in v0.2: total supply and allocation (including the equal two-developer team split), pre-sale price, caps, per-wallet limits, start time and lock, the 1% protocol fee and the reward schedule.

Still open:

1. Default arbiter for mainnet, the approved-arbiter list and arbiter staking rules.
2. Replace the testnet owner wallet with a Safe multisig before mainnet.
3. Mainnet oracle settings (Chainlink ETH/USD and sequencer feed).
4. Engage securities counsel and an external auditor before any mainnet deployment or real-value sale.
