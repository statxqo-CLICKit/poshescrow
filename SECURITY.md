# Security

POSH Escrow is in a **test and audit phase** on Base Sepolia. The contracts are **unaudited** by a third party. Do not use them with real funds.

## Official addresses
The only official contract addresses are listed in [`contracts/DEPLOYED-base-sepolia.md`](contracts/DEPLOYED-base-sepolia.md) and on https://poshescrow.pages.dev/#contracts. All are source-verified on Basescan and Sourcify. Treat any other address claiming to be FMNY or POSH as fake.

## Reporting a vulnerability
Please email **statxqo@gmail.com** with the subject "POSH security". Do not open a public issue for vulnerabilities.

## Notes
- No private keys, API keys or signing keys are stored in this repository.
- OpenZeppelin Contracts v5.1.0 (unmodified) and forge-std v1.17.0 (tests only) are the only dependencies.
