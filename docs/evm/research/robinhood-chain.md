# Robinhood Chain against the EVM PRD (#231)

Research for #232, done on 2026-11-22 between 17:57 and 18:26 UTC.
The question: can every feature in #231 stand on Robinhood Chain (chain 4663) as the PRD assumes?

Method: read-only calls to the chain's public RPC, the issuer's keyless REST API, Chainlink's feed directory, Dexscreener's free API, the testnet explorer and a keyless Blockscout MCP session, plus a Foundry test on a local fork of mainnet.
Nothing was sent to any live chain, and no paid service was called.
Every chain-level finding, with its raw responses, scripts and the fork test, is written back to the Robinhood Chain knowledge base as `robinhood-chain/56-stock-token-custody-and-payouts.md` (local copy `/Volumes/Farhan/Work Folder/Dev/AI/Research-Projects/resources`, commits `e03c6c0` and `d742302`, not pushed; https://github.com/imDev2023/robinhood-chain-resources once the owner pushes it).
This report gives the answers and what they mean for #231; the knowledge base file is the evidence in full.
Additions of 2026-11-23, made on the main session's review of PR #240: Uniswap's protocol fee (section 2), the registry key as a hot key (section 2), the glossary and what Stoker itself may show (section 3), the unread Quote Assets (Gaps) and an eighth contradicted line; each carries its own block or source.
The knowledge base holds the chain-level part of them, with the spike's chain-level findings from PR #239, in `robinhood-chain/44-uniswap-v4-hooks.md` (the protocol fee, paying out inside a swap, a fork's two clocks) and in section 7 of file 56 (the blocklist's revert selector, `permit`).

The chain's own term is "Stock Tokens", and its terms forbid calling them "tokenized stocks" (section 3 below), so this report uses it.

## The short answer

Yes, with five changes to the design.

1. A Stock Token can be held and paid out by any contract: there is no allowlist.
   But the issuer can block any address, pause every Stock Token at once, burn from any address and rewrite all 205 tokens' code, and each of those powers sits with one externally owned account.
   So "no key can reach a coin's liquidity" is true of our keys only, and every payment our contracts push in a Stock Token must survive a blocked recipient.
2. 87 of the 205 Stock Tokens have a Uniswap v4 pool and 56 have one with $10,000 or more; most have no Chainlink feed, and the 35 equity feeds go stale every weekend.
   A start price and a Graduation Target can be set from the issuer's quotes during market hours, never from a weekend quote and never from a feed inside the hook.
3. The chain's terms bar its marks from a coin's name, ticker, image and metadata outright, so the launch form must refuse them, not "may need to".
4. A testnet exists with Uniswap v4 and five issuer-style stand-in Stock Tokens, so the visitor rehearsal can run there, and fork tests cover the exact mainnet code.
5. Uniswap's protocol fee controller is set on this chain's PoolManager and already charges a protocol fee in 17 of the 20 deepest Stock Token pools, so an LP fee of zero is not the whole fee and every quote and `/fees` must read the protocol fee from the chain.

A pushed reward costs about 88,600 gas a holder, about $0.003, because the chain charges no L1 data fee today.

## 1. Stock Tokens in a pool and in a contract's hands

**Answer.**
No Stock Token restricts who may hold or receive it by an allowlist, a cap or a check on contracts.
A hook, a distributor and a vesting contract can all hold and pay one out.
Every transfer, `transferFrom`, `approve` and `permit` checks a central blocklist on the sender, the recipient and the caller, and stops when the token or the whole registry is paused.
`adminBurn` burns from any address without the holder.

**Evidence.**

- Roster: `GET https://api.robinhood.com/rhj/assets` returned 205 active Stock Tokens, all on chain 4663 (eleven added and one removed since 2026-09-23, counted against the 195 of that day; #231's 194 was the count of 2026-09-19, before QNT became the 195th, so 194 plus eleven less one is not the sum to make).
- All 205 read at block 120,801,823 (2026-11-22 18:00:07 UTC) by batched `eth_getStorageAt`, `eth_getCode` and `eth_call` on the public RPC: every one is a beacon proxy of `0xe10B6f6B275De231345c20D14Ab812DB62151B00`, with one runtime code hash, the beacon's `implementation()` is `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` (unchanged since launch: the registry's only two `Upgraded` events, blocks 7,796 and 657,134, name it), and none is paused.
  That is far more than the ten live tokens the ticket asked for.
- The reference implementation's verified source (`Stock.sol`, archived in the knowledge base under `launchpads/hood-fun/contracts/Stock-Implementation-0xb354…/`): `onlyNotPaused` plus `onlyNotBlocked` on `from`, `to` and `_msgSender()`; `paused()` is the token's flag or the registry's; `adminBurn` under `ADMIN_BURNER_ROLE` has no other check; there is no transfer fee and no allowlist.
- Contracts already hold them: the v4 PoolManager has a non-zero raw balance in 201 of the 205.
  The PoolManager, the PositionManager, the Universal Router (`0x8876…0904`) and Permit2 are all not blocked at that block.
- The issuer's roles, rebuilt from all 280 of the registry's logs (blocks 0 to 120,801,823, `eth_getLogs` in 100,000-block windows) and each confirmed by a live `hasRole` at block 120,808,656: every role, from `DEFAULT_ADMIN_ROLE` and `BEACON_UPGRADER_ROLE` to `ADMIN_BURNER_ROLE`, `BLOCKER_ROLE` and `PAUSER_ROLE`, is held by one externally owned account, with no multisig and no timelock (the table is in the knowledge base file, section 3).
- The powers are used: 175 addresses are blocked today (246 of 247 `Blocked` events on 2026-06-08 and 09, before launch; one address blocked and unblocked 72 minutes apart on 2026-11-02, blocks 104,519,492 and 104,561,973); the global pause fired once for 69 seconds (blocks 611,101 to 611,243, 2026-06-30); and `adminBurn` was called three times, the latest at block 99,548,992 on 2026-10-27 (Blockscout MCP, the holder's transactions).
  All three burned from one address, `0xa8553DB0049fc6843c0d00D0Efc08D31848E3C74`, which has no code and has never sent a transaction; none burned from the PoolManager, a pool or any contract (knowledge base file 56, section 3).
  So the record shows the power is live, not that it has ever been turned on a pool.
- On a fork of block 120,815,451 (Foundry, `fork-test/` in the knowledge base's raw folder), a fresh contract received NVDA by a real transfer out of the PoolManager and paid it to 50 new holders.
  With one holder blocked on the fork, a direct payment to them reverted and a plain batch containing them reverted whole; a batch that makes each payment with a low-level call and keeps the failed one owed paid the others.
  With the registry paused on the fork, every payment reverted, and so did a transfer out of the PoolManager, the output side of every swap in a Stock Token pool.

**What it means for #231.**
A Stock Token pool can be frozen (a pause, or the PoolManager blocked), drained of its Stock Token side (`adminBurn` on the PoolManager, whose single balance backs every v4 pool of that token) or changed (a beacon upgrade could add a fee or an allowlist to all 205 at once) by the issuer, and nothing we deploy can prevent it.
The liquidity position stays ours and locked; whether the pool can pay out its Stock Token is the issuer's.
And because a blocked address makes any transfer to it revert, the hook must not push a Stock Token share to a fixed address inside the swap: one blocked Creator Destination would make every swap that pays it revert, for the life of the coin.
The fix is the one the fork test proves: credit each share and let it be pulled, or try the push and credit it on failure; the Reward Round keeper's batch needs the same.

## 2. Pools with real liquidity, and what a start price and a Graduation Target are read from

**Answer.**
87 Stock Tokens have a Uniswap v4 pool; 56 have one with at least $10,000 of liquidity, 27 with $100,000 and 4 with $1,000,000; 118 have none.
On chain, the v4 PoolManager holds $31.8M of Stock Tokens, 86 tokens above $10,000.
The deep pools are quoted in USDG, SPY and ETH.
The best source for a start price and a Graduation Target is the issuer's own quote, taken during US market hours and checked against Chainlink where a feed exists; a weekend quote and an equity feed read inside the hook are both unfit.

**Evidence.**

- Dexscreener `token-pairs/v1/robinhood/<address>`, once for each of the 205 at about 18:19 UTC: 919 pairs, 549 on Uniswap v4; the deepest are SPY/USDG $1.88M, QQQ/SPY $1.53M, META/USDG $1.04M and MSTR/USDG $1.01M.
  The endpoint returns at most 30 pairs a token, so a long tail can be missing.
- Cross-check from chain state: each token's raw `balanceOf(PoolManager)` at block 120,801,823, valued at the issuer's mid quote, totals $31.8M (SPY $6.39M, NVDA $2.92M, MSTR $2.42M; nine tokens above $1M).
  `StateView.getSlot0` and `getLiquidity` at block 120,813,435 confirmed the ten deepest pools live, with LP fees from 0 to 1%.
- Chainlink's directory (`feeds-robinhood-mainnet.json`) lists 62 feeds: 35 equity reference feeds marked `us_equities_24/5` with a 24-hour heartbeat, and four new 24/7 equity feeds for TSLA, NVDA, GOOGL and SNDK, which already have a 24/5 feed.
  So 170 of the 205 Stock Tokens have no 24/5 feed, ten of them among the 33 with $100,000 or more in v4.
  Read on a Sunday at block 120,813,590, every 24/5 feed was 41 to 65 hours old, past its own heartbeat; the 24/7 feeds were 19 to 436 minutes old at block 120,813,768.
- `GET https://api.robinhood.com/rhj/prices` quoted all 205 on the Sunday (18:20:54 UTC) with no trading halt, but at a median bid-ask spread of 6.47% and up to 124%.
- Uniswap's protocol fee, read on review: `PoolManager.protocolFeeController()` (`eth_call` on the public RPC at block 121,389,325, 2026-11-23 11:56:35 UTC) returns `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`, a contract of 4,544 bytes; the spike read the same address on its fork of block 120,800,000 (PR #239).
  `StateView.getSlot0` at the same block on the 20 deepest v4 pools of the Dexscreener sweep (the best pool of each Stock Token; the script and its output are `tools/protocol_fee.py` and `protocol-fees-2026-11-23.json` in the knowledge base's raw folder): 17 carry a protocol fee, the same in both directions, from 52 to 1,000 hundredths of a basis point (0.0052% to 0.1%, the most v4 allows), beside LP fees of 0.02% to 1%.
  SPY/USDG, META/USDG and TSLA/USDG pay 0.05% on a 0.3% LP fee, and SPCX/USDG, COIN/USDG, PLTR/USDG and TTWO/USDG pay 0.1%.
  The three with none are GLD/USDG, the one pool of the 20 whose LP fee is zero, and two pools quoted in meme coins.
  How the controller chooses a pool's fee, and who may call it, was not read.

**What it means for #231.**
The PRD has the registry key set the start price and the Graduation Target for future Launches only, which is the right shape: no oracle is read in a swap, so a stale feed cannot stop trading.
The listing rule needs a price source per Stock Token, and only the issuer's API covers all 205; Chainlink covers 35 and the pools 56.
Conservatively, the registry should take its prices from the issuer's quotes while the US market is open, refuse to update while the spread is wide or the market is shut, and list a Stock Token only where a pool or a feed can confirm the issuer's figure.
The Graduation Target itself needs no feed: the hook compares the pool's own price with the target in Quote Asset units.

**The protocol fee.**
#231 sets the pool's LP fee to zero and has the hook take every fee, which reads as if the hook's fee were the whole cost of a trade.
On this chain a controller that is not ours can put up to 0.1% in each direction on any pool, ours included, and it already does so on most of the deep Stock Token pools.
The one zero-LP-fee pool among the 20 pays none today, which is one observation and not a rule to build on.
So the trade panel's quote (user story 24) and `/fees` (user story 38) must read each pool's protocol fee from the chain, never assume zero; #238 found the same controller set on five of the six later chains.

**The registry key becomes a hot key.**
#231 lists the registry key as one of four bounded keys, used to "list a Quote Asset, set its start price and Graduation Target for future Launches only", which reads as a key used now and then.
The price rule above changes that: prices taken from the issuer's quotes during market hours, and refused while the market is shut, mean a job that writes up to 205 listings every trading day, so the key sits on a server and signs without a person.
#235 has to settle three things the PRD does not say.
How often the job writes: once a day at a fixed time, or whenever a price has moved by a set amount.
How far one update may move a start price, so that a stolen or mistaken key cannot open the next Launch at a tenth or at ten times the fair price.
And what a stale price costs: a start price and a Graduation Target are fixed in Stock Token units at the last write, so a Stock Token that has moved 10% since then opens every new Launch 10% off in dollars, and after a weekend the last write is close to three days old, four after a Monday holiday.

## 3. The chain's terms on a coin's name, ticker, image and metadata

**Answer.**
The Robinhood Chain Terms of Service (last updated 2026-08-24, unchanged in the live docs bundle on 2026-11-22 apart from link markup) forbid putting the chain's marks in a coin's name, ticker, image or metadata, and the brand guidelines (version 1.0, 2026-08-20, also unchanged) add "HOOD".

| Source | What it says | What the launch form must refuse on Robinhood Chain |
| --- | --- | --- |
| Terms 5.5(a) | The marks are the words ROBINHOOD CHAIN, ROBINHOOD as used for the chain, and its logos, badges, icons and trade dress | |
| Terms 5.7(d) | The marks, "or any marks confusingly similar thereto", may not be part of a "token name, or other distinctive identifier" | A name or ticker containing "Robinhood", "Robin Hood", "Robinhood Chain" or "Hood Chain", in any case, spacing or look-alike spelling |
| Terms 5.7(h) | No mark or "any element of the Robinhood Chain brand identity" in the "artwork, iconography, metadata, or smart contract attributes" of any token | The same words in the description and links, and the logo or the feather symbol in the image |
| Terms 5.11(a) and (e) | A token name with the marks, and use "in connection with a token issuance", need Robinhood's prior written consent | No exception without that consent |
| Brand guidelines, "Messaging: What to Avoid" | "You must not reference $HOOD (or HOOD) in any context" | The ticker HOOD or $HOOD, and a name that is only "HOOD" |
| Terms 2.3 (Fraud or Deception, impersonation) and the contracts page | "a token with a matching name/ticker but a different contract address is not a Robinhood Stock Token" | A ticker equal to a listed Stock Token's symbol, and a name containing "Robinhood Token" (every Stock Token is named "X • Robinhood Token") |
| Terms 5.7(g) | No marks in connection with "rug pulls", phishing or impersonation | Covered by the rows above |

A coin's image cannot be checked for the logo by a rule, so the form refuses the words, and the image is handled like Copy Protection's: a report from anyone, and a label or removal by the operator.
The site's own copy is bound too: Terms 5.7(j) and the guidelines require "Stock Tokens" (or "tokenized real-world assets such as Stock Tokens"), never "tokenized stocks" or "tokenized equities", for Robinhood Chain's assets; 5.7(b) requires a notice that the site is not affiliated with Robinhood Markets, Inc.; 5.8(d) requires the full name "Robinhood Chain".
Today's Solana copy says "tokenized stock" 15 times in 11 files under `apps/web/src`, which is fine for Solana's assets but must not carry over to Robinhood Chain's.

**The phrase is in the glossary and the API contract, not only in the copy.**
"Tokenized stock" is one of the ten Asset categories in `CONTEXT.md` (ADR 0010), the glossary names it again under Quote Asset and Market behind an asset, and the API contract returns it as the category `tokenized_stock` (`QUOTE_CATEGORIES` in `packages/contract/src/quotes.ts`, also the `category` column's enum in `packages/db/src/schema.ts`), with an `issuer` beside it drawn from `QUOTE_ISSUERS`, which names four Solana issuers and not this chain's.
User story 41 of #231 lists every chain's Quote Assets with their Quote Risk Labels, and the board and the assets page group by the category, so a Stock Token would be served to integrators as a `tokenized_stock` and described that way in the glossary.
Terms 5.7(j) bars describing, referring to or marketing Stock Tokens as "tokenized stocks", "tokenized equities" "or similar characterizations".
#235 ends in the glossary's EVM terms, so it must decide what this chain's assets are called there and in the contract: a category of their own, or the present one renamed for every chain.
The Quote Risk Label kinds themselves (`QUOTE_LABEL_KINDS`: freeze, pausable and the rest) do not use the phrase, and the issuer's powers in section 1 map onto them.

### What Stoker itself may show

The table above is about what a Creator puts in a coin.
The larger exposure is the site's own use of the chain's name and badge, because user story 22 of #231 has every coin "show its chain on the board, the coin page and every share image", and every Launch on this chain is a token issuance.
What the terms say (knowledge base `robinhood-chain/29-terms-of-service.md`, the capture of 2026-09-02, last updated 2026-08-24):

| Section | What it says | What it touches in #231 |
| --- | --- | --- |
| 5.6(a) and 5.6(d)(iii) | Pre-approved without asking: accurate statements such as "Deployed on Robinhood Chain" and "Built on Robinhood Chain", and "ecosystem directories, token lists, or blockchain explorer listings that include Robinhood Chain as a supported network" | The chain's name in text on the chain picker, the board's filter and a coin's page |
| 5.6(e) with 5.8(a) and (b) | The logo and badges may be used only as downloaded from the Brand Asset Library, never altered, recoloured, cropped or combined "with other branding, imagery, graphic elements or text in a way that obscures or alters their appearance" | A chain badge drawn into our own card or share image |
| 5.7(b)(ii), 5.7(b)(iii) and 5.7(c) | Our own brand "must be more prominent than any use of the Robinhood Chain Marks", and a disclaimer of affiliation is required | Every page and image that names the chain |
| 5.7(h) | No mark and no "element of the Robinhood Chain brand identity" in "the artwork, iconography, metadata, or smart contract attributes of any non-fungible token (NFT), digital collectible, or token" | The chain's badge on a coin's share image, and the chain's name in a coin's Arweave metadata |
| 5.8(d) | The network is referred to "exclusively as 'Robinhood Chain'"; "Hood Chain" and any "abbreviated, informal, or unofficial variant" are prohibited | A short chain label on a card, a filter chip or a share image |
| 5.11(e) | Use of the marks "in connection with a token issuance, initial exchange offering, or similar fundraising event" is not pre-approved and needs Robinhood's prior written consent, which it "may grant or withhold in its sole and absolute discretion" | A launchpad that names the chain beside every Launch |

Three things follow from the text alone.
The chain is named in full, "Robinhood Chain", wherever the site names it, with no short form, and no ticker-like chip such as "RH" or "HOOD".
A coin's metadata stored on Arweave should name the chain by its chain id (4663) and not by its marks, since 5.7(h) covers a token's metadata.
The site carries the notice that it is not affiliated with Robinhood Markets, Inc., and Stoker's own mark stays the larger one.

Two things are legal questions this research cannot settle, and both go to the owner.
Whether a share image that Stoker draws for a coin counts as the "artwork" or "iconography" of a token under 5.7(h), which would bar the chain's badge from it, and perhaps its name.
And whether a launchpad that prints "Robinhood Chain" beside each Launch is using the marks "in connection with a token issuance" under 5.11(e), which would need written consent, or is making the factual statement 5.6(a) pre-approves.
The conservative build until that is answered: the chain's name in plain text only, no badge or logo anywhere on a coin's card or share image, and no logo in the chain picker.

The terms name the address for exactly this question: section 5.11 and section 17 send requests for authorization of uses not pre-approved under 5.6 to `robinhoodchain@robinhood.com`, attention of the Robinhood Chain Brand Team (the knowledge base records it in `ROBINHOOD-CHAIN.md`, sections 12 and 17, and in `robinhood-chain/33-brand-guidelines.md`).
Asking before the build is cheaper than after: a breach ends the trademark licence without notice (5.12) and carries a trademark indemnity (5.13), and a redrawn set of share images and baselines costs more than an email.

**Not a finding, recorded for the grilling (#235).**
The issuer's restricted jurisdictions page says Stock Tokens may not be offered to U.S. Persons and are restricted in Canada, the United Kingdom and Switzerland; `EXCLUDED_REGIONS` already names the U.S., the U.K. and Canada, not Switzerland.
Whether that matters for a coin paired with a Stock Token is a legal question for the owner, not one this research can settle, and the region gate (ADR 0014) is not re-opened here.

## 4. A testnet

**Answer.**
Yes.
Robinhood Chain Testnet (chain 46630) has Uniswap v4 at the mainnet addresses and at least five issuer-style stand-in Stock Tokens: AMZN, TSLA, AMD, PLTR and NFLX.
A mainnet fork remains the only place with the exact Stock Token code, the real holders and the real pools.

**Evidence.**

- `eth_getCode` at mainnet block 120,809,285 and testnet block 156,734,275 (2026-11-22 18:13 UTC): the PoolManager, V4 Quoter, StateView, CREATE2 deployer and Multicall3 are byte-identical across the two; the PositionManager, Universal Router and Permit2 have the same length and differ only by chain immutables.
- None of the 205 mainnet Stock Token addresses, the mainnet registry or USDG's mainnet address has code on testnet.
- The testnet explorer's `/api/v2/tokens`, top 50 by holders, then the ERC-1967 beacon slot of each: AMZN `0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02`, TSLA `0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E`, AMD `0x71178BAc73cBeb415514eB542a8995b82669778d`, PLTR `0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0` and NFLX `0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93` (240,000 to 308,000 holders each) are beacon proxies of `0x1df3ca0fd30ed5eeb09eb01938f4e9c5196e6ca5`, which answers `paused()` and `isBlocked()` like the mainnet registry.
- Their verified implementation `0xBd14156E05c6AF28ad39aA53a2AB8eB9CDf657DA` is an earlier `Stock` build: the same pause and blocklist checks on `transfer` and `transferFrom`, but no oracle pause, no `terms()`, and an `approve` that does not check the spender.
- The explorer also lists unofficial look-alikes ("Mock USDG" several times, "Mock Robinhood Stock Token", "NVIDIA (vibe test stock, no value)"), so testnet addresses must come from the beacon, never from a name.
- `faucet.testnet.chain.robinhood.com` exists and answered HTTP 429; the live docs bundle (24 routes) never mentions a faucet.
  How a test wallet gets the five stand-ins was not established.

**What it means for #231.**
The PRD's "rehearsal on the first chain driven as a visitor with a test wallet" can run on testnet 46630 against the five stand-ins, with a mock USDG of our own if one is needed.
Fork tests against mainnet stay as the PRD says, and are the only check against the exact Stock Token code.

## 5. The cost of a pushed reward

**Answer.**
One holder in a keeper's batch costs about 88,600 gas when paid in a Stock Token, about 1.8e-6 ETH or $0.003 at today's 0.02 gwei base fee.
A holder's own first claim is about 152,200 gas, $0.005.
A whole Reward Round of 16,384 holders costs about $50 to push.
"Nothing to claim on cheap chains" holds on Robinhood Chain.

**Evidence.**

- Chain pricing at block 120,815,738: `ArbGasInfo.getL1BaseFeeEstimate()` is 0 and `getPricesInWei()` is `[0, 0, 400000000000, 20000000, 0, 20000000]`, so no L1 data fee and 0.02 gwei per L2 gas; `NodeInterface.gasEstimateL1Component` returned 0 for 580 and 30,468 bytes of calldata; every user transaction in blocks 120,815,833 to 120,815,837 had `gasUsedForL1` 0; `eth_maxPriorityFeePerGas` is 0.
- Measured on the fork of block 120,815,451: a minimal cumulative Merkle distributor (leaves of account and cumulative amount, anyone may submit, the payment always goes to the holder, rounds add together, a 16,384-leaf tree), every call with its accounts and storage cold, totals including the 21,000 base and the calldata gas, recipients with no prior balance:

| Asset paid | First claim | Later round, same holder | Keeper push of 50, per holder |
| --- | ---: | ---: | ---: |
| ETH | 129,005 | 86,879 | 87,228 |
| USDG | 141,959 | 107,739 | 84,733 |
| NVDA (Stock Token) | 152,233 | 118,007 | 88,648 |

- Dollar figures use ETH at $1,717.40, Chainlink's `ETH / USD` at block 120,813,768.
  The base fee sat at its 0.02 gwei floor; it read about 0.05 gwei in September, which would multiply every figure by 2.5.

**What it means for #231.**
Pushing every claim is affordable, and a dust floor (carry an amount below a few cents into the next round, which a cumulative leaf does by itself) keeps the gas a small share of what is paid.
A chain profile's gas model for Robinhood Chain is L2 gas alone today, and should still read the L1 component from `NodeInterface` rather than assume zero, since the chain's owner can change the pricing.

## Gaps

- No paid source was needed for any answer.
- Dexscreener caps a token at 30 pairs, so the pool counts are lower bounds; the PoolManager balances are the complete figure.
- The testnet roster beyond the 50 ERC-20s with the most holders, and how its faucet hands out Stock Tokens, were not established.
- Whether Robinhood would read a Creator's coin on Stoker as Stoker's use of the marks is a legal reading; this report takes the conservative one.
  What Stoker itself may show of the chain's name and badge is set out in section 3, with its two legal questions.
- USDG and ETH were not read, and most Creators will pick one of them: section 2 finds the deep pools quoted in USDG, SPY and ETH, and #231 offers "any listed Quote Asset" with the native asset listed on every chain.
  The ticket asked about Stock Tokens, so this report's custody findings cover those alone.
  USDG's own issuer powers (it is a 170-byte proxy at `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, knowledge base `robinhood-chain/31-onchain-verification.md`) are recorded nowhere in the knowledge base: who can freeze, seize, pause or upgrade it was not read, and the v4 hooks knowledge base's safety checklist holds its token review open for every token, "USDG included" (`research/notes/05-safety-checklist.md`, as of 2026-09-20).
  The native asset has no issuer, but a push of ETH hands control to the recipient in the middle of a swap, which the spike left untested (PR #239).
  Both need reading before either is listed.
- How Uniswap's protocol fee controller chooses a pool's fee, and who may call it, was not read (section 2).
- Closed on 2026-11-23 by #249 (`quote-assets-and-rehearsal.md`): USDG's and ETH's powers as Quote Assets, the controller's rule (a pool whose hook returns deltas pays 0 under the policy in force), the Universal Router to pin, and how the testnet's faucet hands out the five stand-ins.

## Lines of #231 the evidence contradicts

Lines 1 to 7 were corrected in #231's body on 2026-11-22, in place, with this file named and the old wording kept.
Line 8 was added on review on 2026-11-23; #231 takes it with the outcome of the grilling (#235).

1. **Solution:** "its 194 stock tokens" is 205 Stock Tokens at block 120,801,823.
2. **Quote Assets:** "Robinhood Chain's stock tokens qualify: their ERC-8056 multiplier is display only" leaves out what decides how a contract may hold them: a blocklist on the sender, recipient and caller of every transfer, a per-token and a global pause, `adminBurn` from any address (used three times, latest 2026-10-27) and one beacon that can rewrite all 205, each power held by a single externally owned account.
   A listing must say so, and only the issuer's API prices all 205 (Chainlink covers 35, v4 pools of $10,000 or more 56).
3. **Keys and custody:** "No key can reach a coin's liquidity, a Creator's accrued share or a Creator Lock" holds for our keys only; on a coin paired with a Stock Token the issuer's keys can freeze, burn or rewrite that side of the pool.
4. **Fees, in the swap:** "The hook takes the Platform Fee on every swap and pays each share in that transaction" would let one blocked Creator Destination or platform address make every swap of a Stock Token coin revert; each share paid in a Stock Token must be credited and pulled, or pushed with the failure credited.
5. **Holder rewards:** "On cheap chains the keeper submits every claim" needs each payment isolated, since one blocked holder reverts a plain batch, and no round in a Stock Token can pay during the issuer's pause.
6. **Further Notes:** "Robinhood Chain's terms bar its marks from a coin's name and metadata (knowledge base, sections 5.7 and 5.11), which the launch form may need to refuse" is "must refuse", and the list is wider: the marks and look-alikes in the name, ticker, description, links and image, the ticker HOOD, and any listed Stock Token's symbol or "Robinhood Token" in a name.
7. **Further Notes:** "Whether every stock token can sit in a pool and be paid out by a contract, or whether some restrict transfers" is answered: all 205 can, none has an allowlist, all share one blocklist and pause.
8. **Fees, in the swap, and user stories 24 and 38:** "The pool's own LP fee is zero. The hook takes the Platform Fee on every swap" leaves out Uniswap's protocol fee.
   The PoolManager's protocol fee controller is `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c` (block 121,389,325, 2026-11-23), it can put up to 0.1% in each direction on any pool, and 17 of the 20 deepest Stock Token pools already pay one at that block.
   The quote of "what reaches my wallet after every fee" and the figures on `/fees` must read the protocol fee from the chain here, as #238 found on five of the six later chains.

## For the grilling (#235), beyond the contradicted lines

These are not contradictions of #231's wording; they are decisions it does not yet hold.

1. **The name of this chain's assets in the glossary and the contract** (section 3): "tokenized stock" is an Asset category in `CONTEXT.md` and `tokenized_stock` in the API contract, and the terms bar the phrase for Stock Tokens.
2. **What the site shows of the chain** (section 3, "What Stoker itself may show"): user story 22 against 5.7(h), 5.8(d) and 5.11(e), and whether to write to `robinhoodchain@robinhood.com` before the build.
3. **The registry key's cadence and bounds** (section 2): how often it writes, how far one write may move a start price, and what a stale price is allowed to cost.
4. **Switzerland** (section 3): the issuer restricts Stock Tokens there, and `EXCLUDED_REGIONS` does not name it.
5. **USDG and ETH** (Gaps): neither was read, and both will be picked more often than any Stock Token.
