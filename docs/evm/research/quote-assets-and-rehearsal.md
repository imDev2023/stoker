# USDG and ETH as Quote Assets, Uniswap's protocol fee on our pools, the router in use and the testnet as a rehearsal (#249)

Research for #249, done on 2026-11-23 between 19:27 and 20:16 UTC.
The questions: what USDG and ETH are as Quote Assets on Robinhood Chain (chain 4663), what Uniswap's protocol fee will be on a Stoker pool and whether it can change under a launched coin, which Universal Router the chain's traffic uses and which struct layout it expects, and whether testnet 46630 can serve the rehearsal #231 plans.

Method: read-only `eth_call`, `eth_getStorageAt`, `eth_getCode` and `eth_getLogs` on the chain's public RPCs (mainnet and testnet), one read of Uniswap's governance Timelock on Ethereum through a public RPC, verified source through a keyless Blockscout MCP session, and three public GitHub repositories: Paxos's `paxosglobal/paxos-token-contracts` (USDG's source), `Uniswap/universal-router` and `Uniswap/sdks`.
Nothing was sent to any live chain or testnet, and no paid service was called.
Every chain-level finding, with its raw logs and the two scripts, is written back to the Robinhood Chain knowledge base as `robinhood-chain/57-quote-assets-protocol-fee-router-testnet.md` (local copy `/Volumes/Farhan/Work Folder/Dev/AI/Research-Projects/resources`, commit `74b452f`, not pushed; https://github.com/imDev2023/robinhood-chain-resources once the owner pushes it), with dated pointers in its files 44 and 56, `uniswap/DEPLOYMENTS.md` and the README.
This report gives the answers and what they mean for #231, ADR 0027 and ADR 0028; the knowledge base file is the evidence in full.

## The short answer

1. **USDG and ETH can both be listed under ADR 0028's rule.**
   USDG has no transfer fee, no rebasing balance and no allowlist; its issuer, Paxos, can pause it, freeze any address and burn a frozen address's balance, and can replace its code after a 24-hour timelock, and one externally owned account holds every one of those powers.
   ETH in Uniswap v4 here is the native asset, not WETH, and has no issuer.
2. **A Stoker pool pays no protocol fee today.**
   The controller's live policy gives a pool whose hook returns deltas, as ADR 0025's hook does, a protocol fee of 0.
   Only a Uniswap governance vote, executed through a 2-day Timelock on Ethereum, can change that, to at most 0.1% each way, after which anyone can switch it on for a launched coin.
   `/fees` and every quote read the fee in force from `StateView.getSlot0`.
3. **The Universal Router carrying the traffic is `0x8876789976dEcBfCbBbe364623C63652db8C0904`** (94.2% of Universal Router swaps over 24 hours), with v2.1.2 at `0x204FAca1764B154221e35c0d20aBb3c525710498` at 5.8%; both expect the six-field struct.
   The fork tests pin `0x8876…0904` and run one swap through `0x204F…0498` as well.
4. **A rehearsal can run on testnet 46630**, with a USDG stand-in of our own, native ETH, no protocol fee and the older Stock build; the fork tests stay the only check against mainnet's exact code.

## 1. USDG and ETH as Quote Assets

**Answer.**
USDG is Paxos's Global Dollar: 6 decimals, a `transfer` that returns `true`, ERC-2612 `permit` and EIP-3009, no transfer fee, no rebase for any address outside Paxos's reward groups, and no allowlist.
It passes all three clauses of ADR 0028's listing rule and carries three Quote Risk Labels' worth of issuer powers.
ETH as a Quote Asset is the native asset in a v4 pool (`currency0` is the zero address), which is where the chain's v4 ETH liquidity sits; WETH is an upgradeable bridged token that the chain owner can rewrite, and nothing in our design needs it.

**Evidence.**

- The contract, read at block 121,662,053 (2026-11-23 19:41 UTC): `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` is a 170-byte ERC-1967 proxy whose implementation is `0x68184c449e1a8f34fa18d289737129fd27b66f8f` (verified on Blockscout as `USDG`, 2026-06-26), with an empty admin slot, so the upgrade is UUPS and gated by `DEFAULT_ADMIN_ROLE`.
  `name()` "Global Dollar", `decimals()` 6, `totalSupply()` 633,802,000.58, `paused()` false.
  `nonces` and `authorizationState` answer, so the facet with `permit` and EIP-3009 is installed; `version()` reverts `FacetNotFound`.
- The behaviour, from Paxos's repository at `a9728cb`, whose file tree is the one Blockscout lists for the verified implementation: `_transfer` moves exactly the amount and reverts when the sender or the recipient is frozen; `transferFrom` also reverts when its caller is frozen; `approve` reverts when the owner or the spender is frozen; `balanceOf` returns the stored balance, and USDG's yield reaches an account only by a claim, as a transfer with its own `Transfer` event, to a payout group the issuer registers.
  The deployed implementation predates the repository's head by months, so a later commit could differ from what is deployed; the roles, the facets, the supply controllers and the event record below were read on chain.
- The powers and their holders, rebuilt from all 42 of USDG's role, pause, freeze, wipe, supply-control and upgrade events (blocks 0 to 121,662,906) and confirmed by a live `hasRole` at block 121,671,374:

| Power | Held by | Quote Risk Label |
| --- | --- | --- |
| Pause every transfer (`PAUSE_ROLE`) | `0x3Af3e85f4f97De7AD0f000B724Fb77fE5ffc024B`, an externally owned account | `pausable`, caution: "Can pause all transfers" |
| Freeze any address, which stops transfers from it, to it and by it as a caller (`ASSET_PROTECTION_ROLE`) | the same account | `freeze`, caution: "Can freeze wallets" |
| Burn a frozen address's whole balance (`wipeFrozenAddress`, the same role) | the same account | part of `freeze`: a frozen address can also be emptied |
| Replace the code, grant every role, change the supply controller (`DEFAULT_ADMIN_ROLE`) | `0xcFA0388f5ddf905FdC08c45c716C15Dc10A14C6F`, a `TimelockController` with a minimum delay of 86,400 s, whose proposer, executor and canceller is the same account | no kind yet: "Upgradeable by its issuer, after a day's notice" |
| Mint to and burn from any unfrozen address | two bridge contracts, `0x0d54755f5106BfdB43f7a35f5D49a23F940628d1` (a LayerZero OFT adapter) and `0xB1d84E3fE81Ed394677FDa105bF966288287d656` (Paxos's attestor bridge), both upgradeable and both owned by the same account; three further minters are rate-limited to their own whitelists | no kind yet: "Bridged with mint and burn" |

- The record: 31 addresses frozen (the latest at block 112,022,587, 2026-11-10), none unfrozen, none wiped, no pause and no upgrade since deployment.
  None of the PoolManager, the two live Universal Routers and Permit2 was frozen at block 121,662,906.
- ETH, at block 121,670,584: the v4 PoolManager held 22,699.53 native ETH and 1,308.62 WETH.
  WETH (`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`) is Arbitrum's bridged `aeWETH` behind a proxy whose admin is owned by `0x2A153c6A1B66DBc930a8d7017230ab0253005C09`, one of the two addresses `ArbOwnerPublic.getAllChainOwners()` returns.
  #232 found the deep Stock Token pools quoted in USDG, SPY and ETH (`robinhood-chain.md`, section 2).

**What it means for #231.**
Both can have a Listing.
USDG's freeze reaches further than a Stock Token's blocklist in one way that matters to us: `transferFrom` checks its caller, so a frozen Universal Router or Permit2 would stop every USDG swap through it, and a frozen PoolManager would stop the output side of every USDG pool and could then be emptied by a wipe (18.9M USDG at block 121,670,377).
A Credit owed in USDG to a frozen address stays owed, exactly as ADR 0025 already says for a blocked Stock Token holder, and every payout batch isolates each payment, as ADR 0029 already requires.
The native asset's Listing is native ETH in the pool key, never WETH; a payout in native ETH is a call to the recipient, so the Payout Call and the Distributor guard against re-entry.
`QUOTE_LABEL_KINDS` has `freeze` and `pausable` and no kind for an issuer's upgrade or a bridge's mint and burn, which Stock Tokens need too; the registry's slice adds them.

## 2. Uniswap's protocol fee on a pool whose LP fee is zero

**Answer.**
The controller, `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`, is Uniswap's `V4FeeAdapter`; it takes each pool's fee from a replaceable `V4FeePolicy` (`0x6ee984309ba26c224f12Bb85D6F7f3C019483DFc`), and both are owned by Uniswap governance's Timelock on Ethereum.
Anyone may push a pool's fee into the PoolManager, and a pool has none until someone does.
The policy prices a hookless pool from its LP fee (1 pip each way at an LP fee of zero, which is the 1-pip reading of 2026-11-23), and gives a hooked pool whose hook returns deltas the policy's `defaultFee`, which is 0 (which fits the other reading).
So a Stoker pool pays no protocol fee today, whether or not anyone triggers it.
It can change under a launched coin only by a Uniswap governance vote, and never above 0.1% each way.

**Evidence.**

- Owners, read at block 121,654,424 (2026-11-23 19:27:41 UTC): the PoolManager's owner, the adapter's owner and fee setter, and the policy's owner and fee setter are all `0x2BAD8182C09F50c8318d769245beA52C32Be46CD`, which has no code on the chain; less Arbitrum's L1-to-L2 alias offset it is `0x1a9C8182C09F50C8318d769245beA52c32BE35BC`, Uniswap governance's Timelock on Ethereum, whose `delay()` is 172,800 s and whose admin is Governor Bravo `0x408ED6354d4973f66138C91495F2f2FCbd8724C3` (Ethereum block 26,479,926).
- The rule, from both contracts' verified source (Blockscout, 2026-07-17): `getFee(key)` is a pool override, else the policy's figure; the policy resolves a family for the pool's hook (a family assigned to that hook; native math for a hookless pool; the hook's own answer to `protocolFeeFlags()` against the flag rules; else unclassified, which pays `defaultFee`); `triggerFeeUpdate(key)` is open to anyone and writes `getFee(key)` into the PoolManager.
  v4-core's `PoolManager.initialize` sets no protocol fee, and v4-core caps each direction at 1,000 pips.
- The settings in force: `defaultFee` 0, `isHookedNativeMathFeeOn` false, one flag rule (a hook reporting `2048` joins family 11, whose default is 40 pips each way), eight LP-fee buckets for hookless pools, three hooks assigned to native math, no pool override.
  All 16 configuration events of the two contracts are in one block, 12,217,078, ending with both handed to the Timelock's alias.
- The simulation, `computeFee` and `getFee` at block 121,678,355 for keys of native ETH against USDG: no hook and an LP fee of 0 gives 1 pip each way; no hook and 0.3% gives 500 each way; a hook with both swap delta flags (address flags `0x28cc`) and an LP fee of 0 gives 0, and so does the same hook with a dynamic fee, and a hook with no delta flag.
- The triggers, `FeeUpdateTriggered` over the 24 hours to block 121,681,683: 797, of which 791 by one Uniswap keeper address (`0x87c4d68b2a3c929f5d9c4bc594c95ca5c1df5ce2`), none setting a fee of 0.

**What it means for #231.**
What `/fees` and a quote must read, in one sentence: the protocol fee in force on the coin's pool, the fourth field of `StateView.getSlot0(poolId)` on the chain's StateView (`0xF3334192D15450CdD385c8B70e03f9A6bD9E673b`), which the V4 Quoter (`0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94`) already includes in every quote, never a constant and never the 17-of-20 figure.
`V4FeeAdapter.getFee(poolKey)` gives what anyone could switch on at once, so the Indexer can raise an alarm when the two differ.
The hook must not implement `protocolFeeFlags()`: a hook that reports flag `2048` opts its pools into 40 pips each way today.
If Uniswap governance ever sets a `defaultFee` or a family for our hook, every launched coin's trades cost up to 0.1% more each way and the platform's 1.00% is untouched, since the protocol fee comes out of the swap in the pool, not out of our Credits.

## 3. Which Universal Router the chain's traffic uses

**Answer.**
`0x8876789976dEcBfCbBbe364623C63652db8C0904` (v2.1.1) still carries the traffic; `0x204FAca1764B154221e35c0d20aBb3c525710498` (v2.1.2, the one Uniswap's feed of 2026-11-09 lists) carries a growing minority, and `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99` almost nothing.
All three expect the six-field `ExactInputSingleParams`, with `minHopPriceX36` between `amountOutMinimum` and `hookData`.
The fork tests should pin `0x8876789976dEcBfCbBbe364623C63652db8C0904`.

**Evidence.**

- Every v4 `Swap` event names, as its indexed `sender`, the contract that called `PoolManager.swap`, which for a Universal Router swap is the router.
  Twelve five-minute windows (3,000 blocks each) spread evenly over the 24 hours from block 120,874,305 (2026-11-22 20:18 UTC) to block 121,669,304 (2026-11-23 19:52 UTC): 28,876 v4 swaps in 25,313 transactions from 534 callers.

| Router | Build | Swaps | Of all v4 swaps | Of Universal Router swaps |
| --- | --- | ---: | ---: | ---: |
| `0x8876789976dEcBfCbBbe364623C63652db8C0904` | v2.1.1 | 9,989 | 34.59% | 94.17% |
| `0x204FAca1764B154221e35c0d20aBb3c525710498` | v2.1.2 | 611 | 2.12% | 5.76% |
| `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99` | v2.1.1 with Across | 7 | 0.02% | 0.07% |

- The other 63% of v4 swaps come from aggregators, bots and launchpads with contracts of their own; in September `0x8876…0904` carried 99.7% of router traffic (knowledge base, `uniswap/DEPLOYMENTS.md`).
- Layout: all three routers' runtime code carries the selectors of `V4TooLittleReceivedPerHopSingle(uint256,uint256)` (`0x4713c18b`), `V4TooLittleReceivedPerHop`, `V4TooMuchRequestedPerHopSingle` and `InvalidHopPriceLength`, which exist only in the six-field build; tag `2.1.2` of `Uniswap/universal-router` (commit `802fe4c`, 2026-09-17) pins v4-periphery `545a5d2`, whose `ExactInputSingleParams` is `(PoolKey, bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum, uint256 minHopPriceX36, bytes hookData)`; the spike proved the same on `0x8876…0904` on its fork (`spike/evm-robinhood-fork/README.md`, point 6).
- `universal-router-sdk` (`Uniswap/sdks` at `8ae0425c57`, 2026-11-09) lists both for chain 4663, `V2_1_1` and `V2_1_2`, and its `DEFAULT_UR_VERSION` is `V2_0`, which this chain does not have, so the site's client must name the version.

**What it means for #231.**
The fork test of #231's Testing Decisions pins `0x8876…0904` and adds one swap through `0x204F…0498`, both with the six-field struct written out by hand, never OpenZeppelin uniswap-hooks v1.2.1's five-field struct.
The site's trade panel names `V2_1_1` explicitly while it carries the traffic, and the chain profile records both addresses.

## 4. Testnet 46630 as a rehearsal

**Answer.**
A rehearsal can run there.
The v4 PoolManager, StateView, V4 Quoter, PositionManager, Universal Router v2.1.1 and Permit2 are deployed at their mainnet addresses with the mainnet code sizes, and a faucet contract funds a wallet with 0.01 ETH and 5 of each of the five stand-in Stock Tokens per claim.
What it lacks is USDG, WETH at the address the router and the PositionManager were built with, Universal Router v2.1.2, a protocol fee controller, and mainnet's Stock build.

**Evidence.**

- Code sizes at testnet block 157,148,396 (2026-11-23 20:09 UTC) against mainnet's: PoolManager 24,009, PositionManager (`0x58daec3116aae6d93017baaea7749052e8a04fa7`) 23,877, StateView 3,531, V4 Quoter 6,118, Universal Router `0x8876…0904` 24,546, Permit2 9,152, all equal; Universal Router `0x204F…0498` and `0x06Af…bf99`, WETH and USDG have no code on testnet.
  #232 compared the code byte by byte at block 156,734,275 (`robinhood-chain.md`, section 4).
- `protocolFeeController()` on the testnet PoolManager is the zero address.
- The testnet PositionManager's `WETH9()` is `0x0Bd7…AD73`, which the testnet Universal Router's code also holds, and nothing is deployed there, so a command that wraps or unwraps ETH cannot work; native ETH settles without it.
- The stand-ins AMZN, TSLA, AMD, PLTR and NFLX sit behind beacon `0x1df3ca0fd30ed5eeb09eb01938f4e9c5196e6ca5`, still on implementation `0xBd14156E05c6AF28ad39aA53a2AB8eB9CDf657DA` against mainnet's `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2`; `terms()` reverts, and #232 found no oracle pause and no spender check in `approve`.
- The faucet: each claim is one transaction from a relayer account, `0xF691446e9386DEDF7364340fE35B09E8fE884d81`, to the faucet contract `0x8762F93772c663c6a88Ba50900bd5381df2717Be` with 0.01 ETH, which mints 5 of each stand-in to the recipient and forwards the ETH (transaction `0x8ba11e005361b7a317313ea6e9757308c400a5301d3a66b82178881b4232c696`, block 157,146,938).
  Over the 864,000 testnet blocks to block 157,149,011 (54 hours) it paid 2,115 claims to 1,523 addresses, at most 8 to one.
  The web form at `faucet.testnet.chain.robinhood.com` answered HTTP 429 to every automated fetch, so what it asks of a visitor was not read.
- Gas: 0.01 gwei, so one claim's 0.01 ETH pays for about a billion gas.

**What it means for #231.**
The contracts rehearsal and the visitor rehearsal of #231's Testing Decisions can both run on testnet 46630, on these terms: native ETH and the five stand-ins as Quote Assets, a USDG stand-in of the rehearsal's own (with a freeze and a pause, so the frozen Credit is rehearsed too), no protocol fee (the fork test pranks the controller instead, as the spike's `test_chain_protocolFeeCanBeSwitchedOnByUniswap` did), and the older Stock build.
A test wallet is funded by one claim through the faucet's form, by a person, or by a transfer from a wallet that claimed; nothing in this lane claimed.
Universal Router v2.1.2, the exact Stock Token code, the issuer's real keys and the real pools are checked on a mainnet fork only.

## Gaps

- No paid source was needed for any answer.
- The faucet's web form, its sign-in and its stated limits were not read (HTTP 429).
- Who holds the chain owner's upgrade-executor role, which can rewrite WETH, was not enumerated; nothing in the design uses WETH.
- USDG's behaviour is read from Paxos's public source, whose file tree matches the verified implementation's, not from the deployed bytecode itself; a fork test of a frozen Credit and a paused pool in USDG (as the spike did in NVDA) would settle it.
- Whether the one zero-LP-fee pool among the 20 deepest (GLD/USDG) is hooked was not read; either answer fits the policy.

## Lines of #231 the evidence contradicts

Each line was corrected in #231's body on 2026-11-23, in place and dated, with this file named.

1. **Fees (ADR 0027):** "Uniswap's protocol fee is real: its controller is set on Robinhood Chain's PoolManager, and 17 of the 20 deepest Stock Token pools already pay 0.005% to 0.1%" is true of those pools and reads as true of ours; under the controller's live policy a pool whose hook returns deltas pays 0, and only a Uniswap governance vote can raise it, to at most 0.1% each way.
2. **Quote Assets (ADR 0028):** "USDG and ETH, which most Creators will pick, are not yet read as Quote Assets" is answered: both can be listed, USDG with the labels of section 1 and ETH as the native asset in the pool key.
3. **Testing Decisions:** "a swap through the Universal Router the chain's traffic uses" now has its address, `0x8876789976dEcBfCbBbe364623C63652db8C0904`, with one swap through `0x204FAca1764B154221e35c0d20aBb3c525710498` beside it.
4. **Testing Decisions:** "rehearsed on testnet 46630 (Uniswap v4 at the mainnet addresses, five stand-in Stock Tokens)" leaves out what the testnet lacks: USDG, WETH, Universal Router v2.1.2 and a protocol fee controller.
5. **Further Notes:** three of the five items "still open" are closed: USDG's and ETH's issuer powers, how the controller sets a pool's fee and what a zero-LP-fee pool pays, and the router in use.

## What it changes in ADR 0027 and ADR 0028

Each ADR carries a dated note at its end; neither is rewritten.

- **ADR 0027:** "Uniswap's protocol fee is not ours and is not zero" holds for the chain and not for our pools today: a Stoker pool's protocol fee is 0 under the policy in force, and the decision to show it on `/fees` and include it in every quote stands, read from `StateView.getSlot0`.
  The hook does not implement `protocolFeeFlags()`.
- **ADR 0028:** its consequence "USDG and ETH were not read as Quote Assets" is answered: both meet the listing rule; USDG's Listing carries the labels "Can freeze wallets", "Can pause all transfers", "Upgradeable by its issuer" and "Bridged with mint and burn", and the native asset's Listing is native ETH, never WETH.
  The label kinds for an issuer's upgrade and a bridge's mint and burn are new, and Stock Tokens need the first as well.

## For the contracts lane (#241 and after)

Not contradictions; facts the build can use now.

1. Pin `0x8876789976dEcBfCbBbe364623C63652db8C0904` in the fork tests, add one swap through `0x204FAca1764B154221e35c0d20aBb3c525710498`, and write the six-field struct by hand.
2. Leave `protocolFeeFlags()` out of the hook, and add a fork test that triggers `V4FeeAdapter.triggerFeeUpdate` on a launched coin's pool and reads 0 from `getSlot0` (the policy's answer for a delta-returning hook).
3. The native asset's pool key is `currency0 = address(0)`; the Payout Call and the Distributor pay native ETH by a call with a re-entry guard.
4. A USDG stand-in for the testnet rehearsal needs a freeze, a pause and a caller check on `transferFrom` to stand in for USDG's powers.
