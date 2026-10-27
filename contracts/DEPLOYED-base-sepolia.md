# Base Sepolia deployment (2026-10-24)

- TimelockController: 0xdd172a2f322b20281cbf6d50869e5ae6292280d8
- FMNYDistributor: 0xc88bd7742d0edac28488a7952d4169e3e719ef57
- PoshProfiles: 0x94991a934164013dab8e3fe1b92676267b86a114
- ProofVault: 0xeac142c2836ea70cdfb8237b20d7e58291a869b5
- TrustPassport: 0x80412d3d359892fd383419848ea8dc24d76d60db
- FMNYRewards: 0x3784091fc0063a567f11c90dfcbe4f1e1f6cff67
- PoshEscrow: 0x5600c38d7f00dd06719ecd7a4d5b5cd9f40f340d
- FMNYSale: 0xbf5a6455204ee6b69e263bb55c93b64fee4f48ae

## Testnet liquidity (2026-10-26)

Test tokens only, no real value.

- Pool: Uniswap v3 WETH/FMNY 0.3%, 0x664CC7C53a5bf05d5bfF6FF2DD20c560B2b3b3c9 (token0 = WETH 0x4200…0006, token1 = FMNY 0x6ea2…ca75, tickSpacing 60, factory 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24)
- Pool price at mint: tick 115135, about 100,000 FMNY per WETH (0.00001 ETH per FMNY)
- NonfungiblePositionManager (Uniswap docs, Base Sepolia): 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2
- Approve 100,000 FMNY to the position manager: 0xdfb7ef468d6e5ec562600d9669a1895d6d237b24175cfba3be7d134ddb59aa45
- Mint: 0xcb473600974d62a00c3a693d2ff853bf5a7847a0aab5799afbfb568eed9b9ccb
- Position NFT tokenId 83432, owned by the deployer 0xEE70ed9B63cFcfB633ae4D2358C86020a4475d9F
- Range: ticks 92100 to 115080, FMNY only (single-sided). That is about 0.00001006 to 0.0001001 ETH per FMNY (about 99,451 down to 9,992 FMNY per WETH).
- Deposited: 99,999.999999999999999983 FMNY, 0 WETH. Position liquidity 464254195716709195991.
- Pool FMNY balance after mint: about 100,000.
- pool.liquidity() reads 0 right after mint, which is expected: the current tick (115135) sits just above the range's upper tick (115080), so the position is out of range. The first ETH-to-FMNY swap pushes the price across tick 115080 (no liquidity in between, so it moves there at no cost) and the position becomes active. The pool can only sell FMNY for ETH; there is no WETH side, so FMNY-to-ETH swaps fail until someone adds WETH.
- Leftover allowance: 17 wei FMNY (rounding).
- Activation swap (2026-10-26): 1,000 wei ETH to FMNY, exact input, through SwapRouter02 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4 (Uniswap docs, Base Sepolia). The router wrapped the ETH to WETH itself (sent as msg.value), so it took one transaction. amountOutMinimum 0, no price limit. Tx: 0x3da45f825f3626bff233af163a35461861d940145cbd1217002534281a62a091 (status 1, gas used 185,037)
  - Received 99,153,073 wei FMNY (about 0.000000000099 FMNY)
  - After the swap: tick 115079 (inside the 92100 to 115080 range), sqrtPriceX96 24985330261802305702077694290404, about 99,451 FMNY per WETH. pool.liquidity() = 464254195716709195991, so the position is now active.
  - Pool holds 1,000 wei WETH and about 99,999.9999999999999 FMNY. Deployer after: about 0.0000519 ETH, 0 WETH, about 900,000.0000000001 FMNY.
