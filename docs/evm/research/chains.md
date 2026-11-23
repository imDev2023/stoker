# EVM research: Quote Assets, venues and rivals on the later chains (#233)

Research for #231 (Stoker on EVM chains), on the six chains after Robinhood Chain: Base, Arbitrum, BSC, Polygon, Ethereum and HyperEVM.
Every figure was read on 2026-11-22 unless it says otherwise, and each carries its source.
Nothing here was deployed or sent to any chain; every on-chain figure is a read through a public RPC.
Corrected on 2026-11-23 after the review of PR #238: Polygon's cost, what "listable" means for a stock token, what Base's stock tokens report as code, and four more lines of #231 in the closing list.

## The answer in short

1. **Uniswap v4 is live on all six chains, HyperEVM included.**
   Uniswap's official feed (generated 2026-11-09) lists a HyperEVM PoolManager deployed on 2026-09-15, which the September capture #231 relied on predates.
   No chain needs a venue adapter to host the one contract set.
2. **Where coin launches actually trade differs sharply.**
   On Base and Ethereum nearly all launch trading is on Uniswap v4; on BSC it is on PancakeSwap (V2, V3 and Infinity) and almost none is on v4; on HyperEVM it is on HyperSwap and Project X; Arbitrum and Polygon have no launch market to speak of.
3. **Stock tokens that pass #231's two listing tests exist on Base, BSC, Ethereum and HyperEVM, not on Arbitrum or Polygon.**
   Coinbase's B20 stock tokens on Base use the same display-only multiplier as Robinhood Chain's (ERC-8056); Ondo Global Markets tokens (Ethereum, BSC, HyperEVM) and Binance's bStocks (BSC) do not rebase.
   Backed's xStocks and Dinari's dShares rebase, so #231's listing rule excludes them on every chain.
   "Listable" in this report means no more than passing those two tests (no transfer fee, no rebasing balance): every one of the three passing issuers can refuse, freeze or seize, which #231's rule does not test, so whether each is listed is the owner's call at #235 (line 6 of the closing list).
4. **Our launch shape and our wedge are already on the market.**
   o1 Launchpad (Base, BSC, Robinhood Chain), BaseStonk (Base), Stockereum and fusi.ng (Ethereum) each seed a whole supply single-sided into a locked Uniswap v4 position with a fee hook, and each pairs coins with stock tokens.
5. **Recommended order after Robinhood Chain: Base, BSC, Ethereum, HyperEVM, Arbitrum, Polygon** (the reasons are under "Recommended order").
6. **HyperEVM had no security profile; one is now written** (`evm-security-standards/profiles/hyperevm.md`, committed locally there).
   The Base and Polygon profiles carried stale facts that matter to this design, corrected there on 2026-11-23 (under "The security profiles").

## Method and sources

- **Uniswap deployments:** the live feed `https://developers.uniswap.org/deployments.json` (generatedAt 2026-11-09T21:49:59Z, `Uniswap/contracts@3b872969`), compared with the knowledge base's capture (`resources/uniswap/DEPLOYMENTS.md`, generatedAt 2026-07-15, refreshed 2026-09-03); then every address's bytecode read with `cast codesize` on each chain's public RPC.
  The knowledge base's copy was brought up to this feed on 2026-11-23 (`resources/uniswap/DEPLOYMENTS.md`, "Refresh of 2026-11-23"), with every address read again that day.
- **Volumes and fees:** DefiLlama's free API, `https://api.llama.fi/overview/dexs/<chain>` and `https://api.llama.fi/overview/fees/<chain>`, 30-day totals read 2026-11-22.
  DefiLlama tracks some launchpads' bonding curve only and some not at all; a volume worked out from fees is marked "inferred".
- **Quote Assets:** addresses from CoinGecko's free `coins/list?include_platform=true` and the issuers' own lists, then `symbol`, `decimals`, `totalSupply` and the proxy slots read on-chain.
  Transfer restrictions were found by scanning each token's runtime code (and its implementation's) for the function selectors of `isBlacklisted`, `isBlocked`, `paused`, `basisPointsRate`, `multiplier`, `balancePerShare` and `compliance`: a heuristic that shows a function exists, not that it is used.
- **Rivals:** the launchpads' own documentation and GitHub repositories, cited per row; read and written in our own words.
- **Public RPCs:** `ethereum-rpc.publicnode.com`, `base-rpc.publicnode.com`, `arbitrum-one-rpc.publicnode.com`, `bsc-rpc.publicnode.com`, `polygon-bor-rpc.publicnode.com`, `rpc.hyperliquid.xyz/evm`.
- No paid source was used.
  What only a paid source would answer is listed under "Gaps".

## Uniswap v4 on the six chains, read fresh

The PoolManager, PositionManager and StateView addresses match the September capture on the five chains it covered.
The V4Quoter and the current Universal Router are new on every chain: the feed now lists a v2.1.2 router (and on some chains a v2.2), and V4Quoter addresses that differ from the capture's.

| Chain | PoolManager | PositionManager | StateView | V4Quoter | UniversalRouter (v2.1.2) |
| --- | --- | --- | --- | --- | --- |
| Ethereum (1) | `0x000000000004444c5dc75cB358380D2e3dE08A90` | `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` | `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227` | `0x99bd42B2B22e531f283b7F8a86dFf631EB16A9D1` | `0x23617e59A5925b2A4Bf75d73ff6711cD0b29De85` |
| Base (8453) | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` | `0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71` | `0xE1A6C5803e3c44368b171BD680c7D32dfc92CA47` | `0xd6145b2D3F379919E8CdEda7B97e37c4b2Ca9c40` |
| Arbitrum (42161) | `0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32` | `0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869` | `0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990` | `0x8928074CA1b241D8Ec02815881c1Af11E8bC5219` | `0x2d01411773c8C24805306E89A41F7855C3c4Fe65` |
| BSC (56) | `0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF` | `0x7A4a5c919aE2541AeD11041A1AEeE68f1287f95b` | `0xd13Dd3D6E93f276FAfc9Db9E6BB47C1180aeE0c4` | `0x95C086d7fE28AdD842ee220fef225a777474d781` | `0xDc264714F68d84CF29BC605589405E78bDBE7C9f` |
| Polygon (137) | `0x67366782805870060151383F4BbFF9daB53e5cD6` | `0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9` | `0x5eA1bD7974c8A611cBAB0bDCAFcB1D9CC9b3BA5a` | `0x31AB0Dea31FC0ad5A54F03cD59C896eCD067447B` | `0xDc264714F68d84CF29BC605589405E78bDBE7C9f` |
| HyperEVM (999) | `0x12D4Fd9C5DeDd00ab8a0bCe2CF0167bbf94b6B1F` | `0x0d7Ab5B3db668128Aff6F70C4eBC71D7d4DA9bf9` | `0x1656326235cb9E34Cb58CaDe53AE30789AB32A1A` | `0x108Bfe38532C98f8Cd8D7Ab49c9dDAa3675a1c5e` | `0xeD270A1Bcdc63cf1356D695e7f40961d4819d6bF` |

Every PoolManager has 24,009 bytes of code, every StateView 3,531 and every new V4Quoter 6,118; Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) is on all six.
The Universal Router v2.2, where listed, is `0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB` (Ethereum), `0xBE2257d1aAfBE6B73F67A9ac971C2F0B344Bb3c5` (Base) and `0xE783DE89a7F0408687f051e3E6D0BEb62719EbAd` (HyperEVM).
The Universal Router struct-layout trap the knowledge base records for Robinhood Chain applies to whichever version the fork tests pin, so they should pin one by address per chain.

**A protocol fee can be switched on under our pools.**
`protocolFeeController()` on the PoolManager is set on Ethereum (`0x89A5D5bF00a27D55c02951E49078a5C5771051dB`), Base (`0xc53DD825dedBE7814562528A1A30e8e5BCbB4b55`), Arbitrum (`0x6b3C04567CC62fc5D6AB8D50f1bc1Dee161eb2Cc`), BSC (`0x66276D2e80784180E4B9b859e4327b9C5646B87c`) and Polygon (`0x59e84309Afa65F084F9c03668583d231afB12cc6`), and is the zero address on HyperEVM.
v4 lets that controller set a protocol fee of up to 0.1% per direction on any pool, hooked or not, so a pool with a zero LP fee can still carry one.
The quote in #231's user story 24 must read the pool's protocol fee from the chain rather than assume zero.

Read again on 2026-11-23, the fee is already charged, not only possible.
Each of those controllers is the `V4FeeAdapter` that Uniswap's feed of 2026-11-09 lists under `protocol-fees`, with a `V4FeePolicy` and a `TokenJar` beside it, on Robinhood Chain too (`0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`).
Of 40 pools that had just traded, 15 on Base and 25 on Robinhood Chain carried a protocol fee (`getSlot0` on each chain's StateView), on a schedule that follows the pool's LP fee: 25 pips on a 0.01% pool, 500 on a 0.3% pool, and v4's ceiling of 1,000 pips (0.1%) from 0.8% up.
One pool on Robinhood Chain with an LP fee of zero carried 1 pip (0.0001%) in each direction, so a zero LP fee is not a zero protocol fee.
Why the other pools read zero, and who may set a pool's fee through the adapter, was not established; the figures and the method are in the knowledge base (`resources/uniswap/DEPLOYMENTS.md`, "Refresh of 2026-11-23").

**How much of each chain's trading is on v4** (DefiLlama, 30 days to 2026-11-22):

| Chain | All DEX volume | Uniswap v4 | v4 share | Largest venue |
| --- | --- | --- | --- | --- |
| Ethereum | $56.86B | $17.17B | 30.2% | Uniswap v4 |
| Base | $31.96B | $1.13B | 3.5% | Aerodrome Slipstream ($14.32B and $3.90B under two listings) |
| BSC | $28.81B | $0.96B | 3.3% | PancakeSwap: V3 $16.47B, Infinity $3.97B, V2 $1.06B (74.6% together) |
| Polygon | $5.23B | $0.75B | 14.4% (29.8% without Polymarket) | Polymarket ($2.67B), then Uniswap v4 |
| Arbitrum | $6.10B | $0.68B | 11.1% | Uniswap v3 ($3.26B) |
| HyperEVM | $8.78B (with HyperCore's spot book) | not tracked | see below | Hyperliquid spot book ($5.27B), Project X ($2.01B) |

DefiLlama does not track Uniswap v4 on HyperEVM.
Read from the chain instead: 344 `Initialize` events on its PoolManager since deployment (241 of the pools with a hook, 109 of them one hook, `0x6227f0...2aec`) and about 2,283 `Swap` events in total, counted through the free Etherscan v2 logs API for chain 999.
v4 exists there but is barely used.

Overall DEX share is the wrong measure for a launchpad, because stablecoin and ETH pairs dominate it.
The launch-trading share is in each chain's section.

## Stock tokens: which issuers can be listed

#231 lists a Quote Asset only when it is an ERC-20 with no transfer fee and no rebasing balance.
Read on-chain on 2026-11-22:

| Issuer | Chains (counts from CoinGecko, 2026-11-22) | Decimals | Balance model, read on-chain | Transfer controls | Under #231's listing rule |
| --- | --- | --- | --- | --- | --- |
| Coinbase (B20, Base) | Base: 415 in Coinbase's API, 90 with supply | 8 | display-only multiplier: `multiplier()` = `uiMultiplier()` = 1.0005 on AAPLc while `balanceOf` stays raw (ERC-8056, as on Robinhood Chain) | issuer policies (blocklist or allowlist per token), pause per feature, seize; native precompiles whose code is one marker byte | **passes** the fee and rebase tests; the issuer controls are the owner's call at #235 |
| Ondo Global Markets | Ethereum 462, BSC 460, HyperEVM 35 | 18 | plain balances; no multiplier found | every transfer checked by a `compliance` contract the issuer controls (`checkIsCompliant(address,address)`) | **passes** the fee and rebase tests; the issuer controls are the owner's call at #235, with the compliance risk below |
| Binance bStocks | BSC 111 | 18 | display-only `uiMultiplier()` (1.00078 on NVDAB) | `compliance` contract, same interface as Ondo's | **passes** the fee and rebase tests; the issuer controls are the owner's call at #235, with the compliance risk below |
| Backed xStocks | Ethereum 111, Arbitrum 90, BSC 77, HyperEVM 12 | 18 | **rebasing**: `balanceOf` = `sharesOf` x `multiplier` (a holder of NVDAx read 78,250.68 against 78,117.79 shares at multiplier 1.0017) | upgradeable proxy, mint and burn by the issuer | **fails** (rebasing), except through an ERC-4626 wrapper (o1 lists wrapped xStocks on Monad this way) |
| Dinari dShares | Ethereum, Base, Arbitrum 253 each; HyperEVM 18 | 18 | **rebasing** by `balancePerShare()` (10.0 on NVDA after its 10-for-1 split) | `transferRestrictor` blacklist, pause | **fails** (rebasing) |

The v4 PoolManager already holds Ondo, xStocks and bStocks coins on Ethereum and BSC (for example 75.5 CRCLon on Ethereum, 79.2 NVDAB on BSC) and Coinbase's AAPLc and AMDc on Base, so their compliance policies do not refuse the PoolManager today.
The risk is that each issuer can refuse an address later: a policy that refused our hook, a Destination contract or the distributor would freeze that coin's fees or rewards in that stock token.
A Launch paired with a compliance-checked stock token should be able to pay out somewhere else if a payout reverts, or the site should say the risk in words.

**Passing the two tests is not the same as being listed.**
#231's rule asks only for no transfer fee and no rebasing balance, and its custody line says no key of ours can reach a coin's liquidity.
Coinbase can seize a B20 stock token, block or allowlist its holders one stock token at a time and pause it; Ondo and Binance check every transfer against a contract they control.
So on a coin paired with any of the three an issuer's key can reach the Quote Asset side of the pool and every payout in it, exactly as #232 found for Robinhood Chain's Stock Tokens (a blocklist, `adminBurn`, a pause and one beacon).
The rule needs a third clause for issuer controls, and whether each issuer's stock tokens are listed is the owner's call at #235, issuer by issuer (line 6 of the closing list).
The same clause reaches the stablecoins in the tables below: USDC (blacklist, pause, upgradeable), USDT0 (blocklist), USDH (blocklist and pause), USD1 (freeze and pause) and Ethereum's USDT (blacklist, pause, `destroyBlackFunds`).

Base's B20 tokens are precompiles, and each reports the single byte `0xef` as its code: AAPLc's `extcodesize` is 1 and its code hash is `keccak256(0xef)` (`0x309b8896...48d2a3`), read again on 2026-11-23.
A check that an address has code therefore passes on them (corrected 2026-11-23; this line said that any check of `token.code.length` fails), but nothing can be learned from that code: every B20 token has the same byte and the same hash, so our own code must never tell one from another, or from a contract, by code size or code hash.
OpenZeppelin's `SafeERC20` only reads code length when a call returns no data, and B20 returns a bool.

## Base (8453)

**Quote Assets**

| Asset | Address | Decimals | Notes |
| --- | --- | --- | --- |
| ETH (native) / WETH | `0x4200000000000000000000000000000000000006` | 18 | predeploy, no controls |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | 6 | Circle FiatToken proxy: blacklist, pause, upgradeable |
| USDT (bridged) | `0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2` | 6 | OP standard bridged token, 30.1M supply; no blacklist found |
| Coinbase stock tokens (B20) | `0xb2000000...` vanity addresses, for example AAPLc `0xb200000000000000000000C2e324d24d7eEcd1fb`, AMDc `0xb2000000000000000000000d8Ce462E99ee7A47B` | 8 | 415 listed by `https://api.coinbase.com/v1/tokenized-stocks` (no key), 90 with supply; live since 2026-08-24; not offered to US persons; Chainlink feeds 24/5 that freeze off-hours |

**Venue.** Uniswap v4 carries only 3.5% of Base's DEX volume, but nearly all of its coin-launch trading.
Clanker, o1, Umia, BaseStonk, Zora Coins and Flaunch all trade on v4; Virtuals ($182k of 30-day volume on Base) is the only launch venue found off it (a curve, then Uniswap v2).
Inferred from DefiLlama fees: about $50M a month of launch trading, 95% or more of it on v4.

**Rivals** (ranked by DefiLlama 30-day fees, 2026-11-22):

1. **Clanker**, $364,906 of fees.
   The supply is seeded straight into single-sided v4 positions under Clanker's hooks, with no curve; v4 coins take a 1% to 3% LP fee plus 20% on top for Clanker, and v5 coins take creator buy and sell taxes of 1% to 10% with an opening sniper fee that falls from 99% over 20 s (`clanker.gitbook.io/documentation`, "Creator rewards and fees" and "Deployed contracts").
2. **o1 Launchpad**, $185,028.
   One transaction mints 1B coins and places all of them in one locked, hook-owned v4 range at about $4,000 FDV; 1% of the paired asset per swap (0.5% creator, 0.3% platform, 0.2% referrer), 0.001 ETH to create, and pairs that include 341 Coinbase stock tokens (`docs.o1.exchange/launchpad`, catalog dated 2026-11-13).
3. **Umia**, $45,029 of fees and $4.48M of volume.
   A venture-style raise through Uniswap's Continuous Clearing Auction, after which the raise is paired with reserved coins in a v4 pool under its own hook; the pool charges 1%, half to the protocol (`github.com/umiafinance/protocol`).

Also on Base: **BaseStonk** ($679k of volume), a v4 hook launchpad whose coins are priced in a stock token, an ETF, a major coin or a stablecoin, and in its advanced mode in any coin from an approved launchpad (`docs.basestonk.io`).

**Security profile.** `profiles/base.md` was stale on two points when this was read (see "The security profiles"): Base now makes a block every 0.2 s, and B20 stock tokens are an ERC-8056 asset class the profile did not mention.
Both are corrected there as of 2026-11-23.

**Cost.** Gas price 0.006 gwei: about $0.01 of execution per million gas at $1,710.71 per ETH (DefiLlama coins API), plus an L1 data fee.

## Arbitrum (42161)

**Quote Assets**

| Asset | Address | Decimals | Notes |
| --- | --- | --- | --- |
| ETH (native) / WETH | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | 18 | upgradeable proxy (the bridge's) |
| USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | 6 | Circle FiatToken proxy: blacklist, pause, upgradeable |
| USDT0 | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | 6 | upgradeable proxy with a blocklist (`isBlocked`, `addToBlockedList`) |
| Stock tokens | xStocks (90) and Dinari (253) only | 18 | both rebase; none listable |

CoinGecko lists none of Robinhood's earlier Arbitrum stock tokens on 2026-11-22; Robinhood's stock tokens are listed on Robinhood Chain.

**Venue.** Uniswap v4 carries 11.1% of DEX volume; there is no launch trading to route.

**Rivals.** No meaningful coin launchpad: Printr had $414 of 30-day volume and StonkBrokers Safe Launch $13 on Arbitrum (its activity is on Robinhood Chain); Clanker and Uniswap's auctions list Arbitrum with $0.
Camelot's launchpad sells project tokens by auction rather than launching coins (not re-verified for 2026).

**Security profile.** `profiles/arbitrum-one.md` exists (2026-08-06) and shares the Nitro clock rules with Robinhood Chain, so a deployment here is cheap technically.
Measured block interval: 0.297 s.

**Cost.** Gas price 0.0208 gwei: about $0.04 per million gas.

## BSC (56)

**Quote Assets**

| Asset | Address | Decimals | Notes |
| --- | --- | --- | --- |
| BNB (native) / WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` | 18 | no controls |
| USDT (Binance-Peg) | `0x55d398326f99059fF775485246999027B3197955` | **18** | owner-minted; no blacklist found |
| USDC (Binance-Peg) | `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` | **18** | upgradeable proxy |
| USD1 (World Liberty) | `0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d` | 18 | upgradeable proxy with freeze and pause; a quote on Flap and four.meme |
| Binance bStocks | for example NVDAB `0x02fca66c1d1afb4e2a7884261eb00f63598a7436` | 18 | 111; display-only multiplier; compliance contract |
| Ondo Global Markets | for example CRCLon `0x992879cd8ce0c312d98648875b5a8d6d042cbf34` | 18 | 460; compliance contract |
| xStocks | for example NVDAx `0xc845b2894dbddd03858fd2d643b4ef725fe0849d` | 18 | 77; rebasing, not listable |

BSC's stablecoins have 18 decimals, unlike every other chain here: no figure may assume a stablecoin has 6.

**Venue.** PancakeSwap takes 74.6% of DEX volume, and the launch market graduates there.
Flap's curve migrates by default to PancakeSwap V3 (tax coins to V2), with Uniswap v4 or PancakeSwap Infinity as opt-ins; four.meme seeds PancakeSwap; Genius.fun graduates into locked PancakeSwap Infinity liquidity under its own hook.
Inferred: 0% to 1% of BSC's launch trading reaches Uniswap v4 (o1 earned $20 of fees on BSC in 30 days).

PancakeSwap Infinity is itself a hooked singleton design on BSC: its Vault `0x238a358808379702088667322f80aC48bAd5e6c4`, CL pool manager `0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b` and Bin pool manager `0xC697d2898e0D09264376196696c51D7aBbbAA4a9` are live, each with an owner (read 2026-11-22).
A Stoker pool on Uniswap v4 would hold the coin's whole supply, so the coin still trades there; what is lost is the flow of traders and bots that only watch PancakeSwap.

**Rivals** (DefiLlama, 30 days):

1. **Flap**, $15.81M of fees and $209.8M of curve volume.
   A curve that graduates at 80% sold into PancakeSwap V3 by default, with BNB, USD1 and lisUSD quotes, a 1% curve fee and optional creator taxes of 1% to 10% (`docs.flap.sh`, "Protocol economics").
2. **Genius.fun**, $295,784 of fees and $4.14M of volume.
   A curve that graduates at 15 BNB into locked PancakeSwap Infinity liquidity, with BNB, stablecoin, Ondo, bStocks, xStocks and 4Stock quotes; up to 1.25% to the creator (DefiLlama's listing and the launch announcement of 2026-09-17; no official docs found).
3. **four.meme**, $186,705 of fees and $17.96M of curve volume.
   A 1B-coin curve that seeds PancakeSwap at about $10k raised, with BNB, USDT, USD1, bStocks and its own 4Stock quotes, a 1% fee and free creation (`four-meme.gitbook.io`).

**Security profile.** `profiles/bnb-chain.md` exists (2026-08-06) and is current on the clock: it records Fermi's 0.45 s blocks, and the measured interval was 0.450 s.

**Cost.** Gas price 0.05 gwei: about $0.03 per million gas at $555.86 per BNB.

## Polygon (137)

**Quote Assets**

| Asset | Address | Decimals | Notes |
| --- | --- | --- | --- |
| POL (native) / WPOL | `0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270` | 18 | no controls |
| USDC | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | 6 | Circle FiatToken proxy: blacklist, pause, upgradeable |
| USDT0 | `0xc2132D05D31c914a87C6611C10748AEb04B58e8F` | 6 | proxy (Polygon's own slot), implementation with a blocklist |
| Stock tokens | none found | | |

**Venue.** Uniswap v4 carries 14.4% of DEX volume (29.8% leaving out Polymarket); there is no launch trading to route.

**Rivals.** None meaningful: wen markets and Fjord show $0 of fees on DefiLlama; WhaleCom and Mintz appear only in their own posts and listings (unverified).

**Security profile.** `profiles/polygon-pos.md` exists (2026-08-06) and said blocks come about every 2 s; the measured interval is 1.5 s, at every sample back to 2026-08-10.
It is corrected there as of 2026-11-23.

**Cost.** Gas price 278 gwei of POL: a million gas is 0.278 POL, about $0.02 at $0.0756 per POL.
That is what a million gas costs on Base ($0.01), BSC ($0.03) and Arbitrum ($0.04), not a thousandth of it (corrected 2026-11-23; this line said $0.00002, a slip of three decimal places).
The gas price read 280 gwei again on 2026-11-23.

## Ethereum (1)

**Quote Assets**

| Asset | Address | Decimals | Notes |
| --- | --- | --- | --- |
| ETH (native) / WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | 18 | no controls |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 | Circle FiatToken proxy: blacklist, pause, upgradeable |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | 6 | blacklist, pause, `destroyBlackFunds`, and a **dormant transfer fee**: `basisPointsRate()` and `maximumFee()` read 0, but Tether can raise them |
| Ondo Global Markets | for example CRCLon `0x3632dea96a953c11dac2f00b4a05a32cd1063fae` | 18 | 462; compliance contract |
| xStocks, Dinari | for example NVDAx `0xc845b2894dbddd03858fd2d643b4ef725fe0849d` | 18 | rebasing, not listable |

USDT on Ethereum fails #231's "no transfer fee" rule in principle: its fee is zero today and settable by its owner.
Listing it is a judgment for the grilling; if listed, the factory should refuse it while `basisPointsRate()` is not zero.

**Venue.** Uniswap v4 is the largest venue on Ethereum (30.2% of DEX volume), and the launch market is on it.
Inferred: about 99% of Ethereum's coin-launch trading is on v4, roughly $5M to $15M a month (from Stockereum's and fusi.ng's fees); Printr's $6.5k curve volume is the only non-v4 launch volume measured.

**Rivals:**

1. **Stockereum**, $140,130 of 30-day fees.
   1B coins in one hook-owned, single-sided v4 position that cannot be pulled, no curve, quotes from a curated list of ETH, USDC and "on"-suffixed stock tokens (Ondo's naming); a 1%, 2% or 3% fee fixed at launch, of which the platform takes 0.5% or 1%, and an opening anti-snipe fee from 99% over 20 s (`stockereum.com/docs`).
2. **fusi.ng**, $16,009.
   A v4 pool with a fee hook and a locker, priced in ETH, a coin or a stock token; 1.1% per trade, 60% to the creator and 40% to the protocol, paid in ETH (`github.com/fusinglabs/fusing-v3b`).
3. **Uniswap's Liquidity Launchpad**, $4,220 of auction volume.
   A permissionless auction that then seeds a v4 pool; its Instant Launch strategy seeds a whole 1B supply single-sided into a hookless 0.25% ETH pool held by a fee splitter (`developers.uniswap.org`, "Instant launch"); it is live on Ethereum, Base and Arbitrum (`LiquidityLauncher` `0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0`).

**Security profile.** `profiles/ethereum-l1.md` is the baseline; measured block interval 12.04 s.

**Cost.** The base fee read 0.122 gwei on 2026-11-22: about $0.21 per million gas at $1,710.71 per ETH.
It is volatile: twelve samples over 90 days ranged from 0.044 gwei to 1.998 gwei, so a launch of three million gas would have cost between about $0.23 and $10.25.

## HyperEVM (999)

**Quote Assets**

| Asset | Address | Decimals | Notes |
| --- | --- | --- | --- |
| HYPE (native) / WHYPE | `0x5555555555555555555555555555555555555555` | 18 | immutable WETH9 copy; HYPE has 8 decimals on HyperCore |
| USDC (native) | `0xb88339CB7199b77E23DB6E890353E22632Ba630f` | 6 | Circle FiatToken proxy: blacklist, pause, upgradeable; 8 decimals on HyperCore |
| USDT0 | `0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb` | 6 | upgradeable proxy with a blocklist |
| USDH | `0x111111a1a0667d36bd57c0a9f569b98057111111` | 6 | upgradeable proxy with a blocklist and pause |
| Ondo Global Markets | for example CRCLon `0x13a81c5e8b4ab05fc721dff7ba95e250b29458f8` | 18 | 35; compliance contract |
| xStocks, Dinari | 12 and 18 | 18 | rebasing, not listable |

**Venue.** Official Uniswap v4 since 2026-09-15 (PoolManager block 45,998,366; in Uniswap's feed of 2026-11-09), little used (344 pools, about 2,283 swaps).
The trading is elsewhere: Hyperliquid's own spot book ($5.27B over 30 days, on HyperCore, not the EVM), Project X ($2.01B), nest, Ramses and HyperSwap.
None of those is confirmed from its own docs to offer hooks; Kittenswap and HyperCat run Algebra Integral, whose plugins are the nearest equivalent (third-party sources only).
Launch trading on v4: 0% found.

**Rivals** (DefiLlama, which files this chain as "Hyperliquid L1"):

1. **Alt Fun**, $2.36M of 30-day volume and $17,683 of fees.
   A curve whose reserve is a leveraged perp coin, graduating at $9k of reserve into a HyperSwap V2 pool; 0.75% per trade, 0.25% to the creator (`docs.alt.fun`).
2. **LiquidLaunch**, $17,457 of volume.
   A curve with a 1% fee and a 20 HYPE bond, then a pool on an unverified DEX (DefiLlama's methodology).
3. **PerpMe**, not tracked.
   One transaction mints 1B coins into a single-sided, locked v3-style position on Project X, with HYPE, USDC, USDT0 and PURR quotes (third-party listings only; unverified).

hypurr.fun, the best-known Hyperliquid launcher, launches on HyperCore's spot book, not on HyperEVM (`hfun.gitbook.io`).

**Security profile.** There was none; `profiles/hyperevm.md` is now written in `evm-security-standards` (commit `806ddb1`, local, not pushed).
What it changes for this design: `prevrandao` is the constant 0; `block.timestamp` repeats when a big block follows a fast one; a fast block caps any transaction at 3M gas, so a launch transaction must fit under it or the deployer must opt into big blocks through a HyperCore action; headers carry a zero `stateRoot`; a transfer to a system address (`0x2222...2222` or `0x20...`) moves value to HyperCore instead of transferring it, so every Destination and payout must refuse those addresses; and the Hyper Foundation holds 47.5% of stake.

**Cost.** Base fee 0.1 gwei: about $0.006 per million gas at $62.80 per HYPE.

## The security profiles

The six chains against `evm-security-standards/profiles` on 2026-11-22:

| Chain | Profile | State |
| --- | --- | --- |
| Base | `base.md` (2026-08-06) | **stale**: says 2 s blocks; measured 0.200 s over the last 100,000 blocks, with three to five consecutive blocks sharing one timestamp, at every sample back to 2026-11-11; and says nothing of B20, whose stock tokens are an ERC-8056 class, so its gate fact `asset-semantics` should be `erc-8056`, not the inherited `standard` |
| Arbitrum | `arbitrum-one.md` (2026-08-06) | current on what was checked (0.297 s blocks) |
| BSC | `bnb-chain.md` (2026-08-06) | current on the clock (0.450 s, as recorded for Fermi) |
| Polygon | `polygon-pos.md` (2026-08-06) | **stale**: says about 2 s blocks; measured 1.5 s |
| Ethereum | `ethereum-l1.md` | current (12.04 s) |
| HyperEVM | none | **written**: `hyperevm.md` |

The table is the state found on 2026-11-22, when this lane could add only the HyperEVM profile.
Both stale profiles were corrected in `evm-security-standards` on 2026-11-23, after the review of PR #238, from fresh reads that day.
Base: 0.2000 s a block over the last 100,000 and the last 1,000,000 blocks, five consecutive blocks sharing each timestamp, since block 53,556,127 (2026-11-05 18:00:01 UTC), before which blocks came every 2 s; AAPLc answers `uiMultiplier()`, `multiplier()`, `newUIMultiplier()` and `effectiveAt()`, so Base's `asset-semantics` gate fact is now `erc-8056`.
Polygon: 1.5000 s a block over the last 100,000, 1,000,000 and 5,000,000 blocks, the timestamps stepping by 1 s and 2 s in turn.
The Base correction changes a gate verdict: a project on Base must now simulate a multiplier change or waive the rule with a reason.

## Recommended order after Robinhood Chain

1. **Base.**
   The one chain where everything lines up: Uniswap v4 is where its launches trade, so traders, bots and screeners there already handle hooked v4 coins; Coinbase's stock tokens use the same display-only multiplier as Robinhood Chain's, so the Asset Pairing code ports unchanged; gas is negligible.
   Against it: o1 and BaseStonk already offer stock-paired v4 launches there, so Stoker competes on its accountable fee split and Creator Earnings rather than on pairing alone.
2. **BSC.**
   The largest coin-launch market by far (Flap alone took $15.81M of fees in 30 days, more than every launchpad on the other five chains together) and two listable stock-token families (Ondo and bStocks).
   Against it: the market trades on PancakeSwap, so a v4 pool there starts outside the flow; whether to build a PancakeSwap Infinity adapter (Infinity has hooks) or to rely on aggregators reaching v4 is a question for the grilling (#235).
3. **Ethereum.**
   v4's home and the deepest liquidity, with 462 Ondo stock tokens; gas is cheaper than #231 assumed (0.04 to 2 gwei in the samples).
   Against it: a small launch market ($5M to $15M a month) already served by Stockereum and fusi.ng in our exact shape.
4. **HyperEVM.**
   Official v4 now exists, so no venue adapter is needed, and 35 Ondo stock tokens are there.
   Against it: v4 is barely used, launches trade on HyperSwap and Project X, the chain's semantics differ most from the others (section above), and one party holds 47.5% of stake.
5. **Arbitrum.**
   Technically the cheapest addition (the same Nitro clock rules as Robinhood Chain), but no launch market and no listable stock token.
6. **Polygon.**
   No launch market, no stock token, and v4 a minority of its volume.

If the owner weighs market size above fit, BSC goes before Base; nothing else in the evidence would reorder the list.

## Lines of #231 the evidence contradicts

1. "Base, Arbitrum, BSC, Polygon and Ethereum follow, each as a deployment plus a chain profile."
   Arbitrum and Polygon have no launch market and no listable stock token, and Ethereum and BSC have both; the order above replaces it (corrected in #231 on 2026-11-22).
2. "HyperEVM follows them with a venue adapter, since the knowledge base's Uniswap deployment capture lists no Uniswap v4 there."
   Uniswap v4 is officially deployed on HyperEVM (2026-09-15), so it needs no venue adapter; it still follows on market grounds (corrected in #231 on 2026-11-22).
3. "Robinhood Chain is first, because its 194 stock tokens are Stoker's Asset Pairing wedge; the other chains follow as a deployment and a chain profile each."
   Pairing with stock tokens is no longer a wedge on Base, BSC or Ethereum, where o1, BaseStonk, Stockereum, fusi.ng, four.meme and Genius.fun already offer it, and o1 does so on Robinhood Chain too; and "a deployment and a chain profile each" undercounts Base, whose profile needs the B20 asset class, and HyperEVM, whose semantics need their own handling (system addresses, the 3M gas ceiling).
   Not corrected in #231: positioning is the owner's to restate at the grilling.
4. "The pool's own LP fee is zero" together with user story 24 ("quote what reaches my wallet after every fee").
   Uniswap's protocol fee controller is set on five of the six chains and may put up to 0.1% on any pool, so the quote must read it from the chain.
   On 2026-11-23 the fee was found already charged on live pools on Base and Robinhood Chain, a pool with a zero LP fee among them (the section on Uniswap v4 above).
5. "The native asset is a Quote Asset on every chain" stands, but "a listing needs an ERC-20 with no transfer fee" excludes Ethereum's USDT in principle (a dormant, settable fee) and the rebasing rule excludes xStocks and Dinari everywhere; those are consequences for the Quote Registry, not contradictions.

Lines 6 to 9 were added on 2026-11-23 from the review of PR #238.
None of them is corrected in #231 here: each is a decision for the grilling (#235).

6. "A listing needs an ERC-20 with no transfer fee and no rebasing balance" together with "No key can reach a coin's liquidity" (since 2026-11-22, "No key of ours", after #232).
   The rule has two tests and needs a third, for issuer controls.
   Every stock token that passes the two tests on these chains can be refused, frozen or seized by its issuer: Coinbase's B20 (seize, a blocklist or an allowlist per stock token, pause), Ondo's and Binance's (a compliance contract on every transfer).
   An issuer's key therefore reaches the Quote Asset side of the pool and every payout made in it, which is the same contradiction #232 found on Robinhood Chain (a blocklist, `adminBurn`, a pause, one beacon), and it reaches the stablecoins too.
   This report's tables therefore say "passes the fee and rebase tests" where they first said "yes": whether an issuer's asset is listed, and what the site says of it, is the owner's call at #235, issuer by issuer.
7. User story 34 ("As a holder on Ethereum, I want to claim my rewards myself") and "on Ethereum holders claim for themselves, rounds added together".
   #231 has holders on Ethereum claim for themselves because gas is dear there, and the measurements do not bear that out: the base fee ran from 0.044 to 1.998 gwei over twelve samples in 90 days and read 0.122 gwei on 2026-11-22 (0.155 gwei on 2026-11-23).
   At the 88,600 gas a pushed claim measured on Robinhood Chain (#232), a claim on Ethereum costs about $0.007, $0.02 and $0.30 at those three prices, so a single pushed claim costs cents.
   What stays dear is a whole round at the top of the range: 16,384 holders cost about $110, $300 and $5,000 to push.
   So the reason for a separate claim model on Ethereum is gone for a small round and holds only for a large round in a dear week; #235 can choose one model for every chain, with a ceiling on what the keeper spends per round.
8. User story 45 ("add a chain by deploying the contracts and writing a chain profile, so that a new chain needs no new code") and user story 3 ("one transaction and one signature").
   HyperEVM needs code no other chain needs: a transfer to a system address (`0x2222...2222`, or a linked token's `0x20...` address) moves the value to HyperCore instead of paying it, so every Destination and every payout must refuse those addresses.
   A fast block there caps a transaction at 3M gas.
   The spike's launch measured about 1.14M gas on Robinhood Chain (#234), which fits, but a launch that grows past the cap, and the deployment of the contracts themselves, needs the sender to opt into big blocks through a HyperCore action, which is a second step before the one transaction.
   The profile says both (`evm-security-standards/profiles/hyperevm.md`); in this list they stood only in passing, under line 3.
9. "The coin is a plain ERC-20: 1 trillion at 18 decimals" together with user story 46 (a Quote Asset listed "with its start price and Graduation Target").
   The Quote Assets found here have 6 decimals (USDC, USDT, USDT0, USDH), 8 (Coinbase's B20 stock tokens) and 18 (the native assets, BSC's stablecoins, Ondo, bStocks), and the pool's price is a ratio of raw units, so each decimal moves the start tick by about 23,027 ticks.
   For illustration, a start at a $4,000 fully diluted value is a raw ratio near tick 193,400 against an 18-decimal dollar stablecoin on BSC, near 469,700 against 6-decimal USDC and near 478,000 against an 8-decimal B20 stock token at $230 (the sign follows the currency order; v4's ticks end at 887,272).
   So the registry must hold each listing's start price and Graduation Target in raw units worked out with that asset's decimals, never as one figure for a chain, and the tests must cover 6, 8 and 18 decimals in both currency orders; the spike (#234) ran against an 18-decimal Stock Token alone.
   Also for the registry: Ethereum's USDT returns nothing from `transfer` (an `eth_call` of a zero transfer returns empty data where USDC returns `true`, read 2026-11-23), so every payout of it needs a safe transfer that accepts an empty return.

The lines #231 asks to verify are answered here: the census of Quote Assets on each later chain (the tables above), BSC's routing (confirmed: PancakeSwap carries the launch market), and HyperEVM's venue read fresh (official Uniswap v4).

## Gaps

- **Launch-trading shares are inferred, not measured,** for Clanker, o1, Stockereum and fusi.ng, which DefiLlama does not track by volume; a measurement needs each launchpad's pools indexed (Dune or a paid indexer).
  The free route is to index each factory's `Initialize` events and the pools' `Swap` events through a public RPC, which is slow but possible in a later session.
- **Aggregator routing to hooked v4 pools** (1inch, 0x, OKX, Binance Wallet, GMGN) was not measured; whether they route to a pool with an unknown hook decides how much flow a Stoker pool sees on BSC and HyperEVM.
- **HyperEVM DEXes' extension points** (Project X, HyperSwap, nest) were found only in third-party sources.
- **Ondo's and Binance's compliance rules** were not read beyond the interface: which addresses they refuse, and whether a contract recipient can be refused, needs their source or their legal terms.
- **Robinhood's earlier Arbitrum stock tokens** were not looked for on-chain; CoinGecko lists none there.
