<p align="center"><img src="assets/posh-logo.png" width="160" alt="POSH Escrow logo"></p>

<h1 align="center">POSH Escrow</h1>

**Escrow Platform on Base** with the FMoney Protocol (**FMNY**) reward token.
A Racer X project by Team C.L.I.C.K.it. Co-founders: Stan Redick and Andrea Holmes.

> **Test & audit phase.** Everything here runs on **Base Sepolia testnet** (chain ID 84532). Test tokens have no real value. The contracts have not had a third-party audit yet. Nothing here is an offer to sell or a promise of returns.

- **Live app:** https://poshescrow.pages.dev
- **Contracts:** https://poshescrow.pages.dev/#contracts
- **X:** https://x.com/poshescrow
- **Discord:** https://discord.gg/7DbFqrymk

## What it does
- **Deals**: buyer funds escrow; seller delivers; funds release on confirmation, with dispute escalation, approved arbiters and timeout resolution.
- **Handoff Mode**: in-person handoffs with a "mark handed over" step.
- **Proof Vault**: commit-reveal SHA-256 proofs of documents and photos (only the hash goes on-chain).
- **Trust Passport**: on-chain reputation from completed deals.
- **Rewards**: fee-bounded, capped FMNY rewards with streaks and levels.
- **Pre-sale (testnet)**: FMNYSale with soft/hard caps and a 90-day lock.

## Repository layout
| Folder | Contents |
|---|---|
| `contracts/` | Foundry project: Solidity sources, tests, deploy script, ABIs, live addresses |
| `site/` | The web app (static HTML/JS PWA, ethers v6) served at poshescrow.pages.dev |
| `assistant-worker/` | Cloudflare Worker behind the in-app POSH Assistant |
| `treasury-worker/` | One-page helper used to move test FMNY from the treasury |
| `whitepaper/` | FMNY white paper (draft) |

## Base Sepolia deployment
Token **FMNY** `0x6ea28bc7e57b4032fa673bacf6d794d8c68dca75` (100,000,000 supply, 18 decimals).
All 12 contracts are verified (exact match) on Basescan and Sourcify. Admin functions on Escrow, Sale and Rewards sit behind a **48-hour timelock**; Distributor, Passport and Vault ownership is renounced.
Full address list: [`contracts/DEPLOYED-base-sepolia.md`](contracts/DEPLOYED-base-sepolia.md).

Testnet liquidity: Uniswap v3 FMNY/WETH 0.3% pool `0x664CC7C53a5bf05d5bfF6FF2DD20c560B2b3b3c9`.

## Build and test
```bash
cd contracts
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std@v1.17.0 --no-git
forge build
forge test
```

## Security
See [SECURITY.md](SECURITY.md). Report issues privately to statxqo@gmail.com.

## License
MIT
