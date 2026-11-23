# EVM spike: a direct seed against a stock token, on a fork of Robinhood Chain

Ticket #234, part of #231 (Stoker on EVM chains).
A throwaway spike, as `spike/launchlab-devnet` was for Solana: evidence and gotchas, not production code.
Nothing here was deployed or sent to any live chain.
Every claim below names the passing test that proves it, or says plainly where it comes from instead.

## The question and the answer

Does #231's launch shape work on a fork of Robinhood Chain, against the real PoolManager and a real stock token?

Yes.
One transaction deploys a plain ERC-20, opens a Uniswap v4 pool against NVIDIA's stock token (NVDA) at a listed price, seeds the whole supply single-sided, and makes the Creator's First Buy.
The hook takes the fee on the NVDA side in both directions, pays the Creator, a referrer and the platform inside the swap, takes a Reward Tax that burns and adds locked liquidity, and latches Graduation once.
Swaps go through the chain's Universal Router and price exactly through its V4 Quoter.

Three of #231's decisions need changing, and the hook's safety score is higher than the PRD hopes; see "#231's decisions" and "The safety checklist score" below.
Two more decisions hold only as the ticket worded them: the main session's review of 2026-11-22 measured what each costs, and its tests are on the branch as `test/Review.t.sol`; see "Held, with a caveat the review measured".

## Run it

```sh
cd spike/evm-robinhood-fork
./script/deps.sh                 # forge-std and OpenZeppelin uniswap-hooks v1.2.1 at pinned revisions, into lib/
export ROBINHOOD_RPC_URL=...     # an archive RPC for chain 4663; the owner's global env has Alchemy's free tier
forge test -vv
```

- Every test forks **L2 block 120,800,000** (timestamp 1795370197, 2026-11-22), set once in `test/Base.t.sol` as `FORK_BLOCK`.
- The fork needs an **archive** endpoint: the public RPC keeps only minutes of history, so a pinned block older than that fails there.
  Alchemy's free tier (`ROBINHOOD_RPC_URL` in the owner's global env) serves it; no paid call is involved.
- The first run reads state over RPC; later runs read Foundry's cache (`~/.foundry/cache/rpc/4663/`) and take about a second.
- Result at the pinned block: **42 tests passed, 0 failed** across eight suites.
  37 of them, in seven suites, prove the ticket's eight points; the other 5 are the review's measurements in `test/Review.t.sol`.
- Dependencies are pinned in `script/deps.sh` (no submodule, nothing under `lib/` committed); the revisions are those of the v4 hooks knowledge base's `hooks/foundry.lock`.

## What is here

| File | What it is |
| --- | --- |
| `src/StokerCoin.sol` | The coin: OpenZeppelin ERC-20, 1 trillion at 18 decimals minted once to the factory, no owner, no mint, no tax, no blocklist; holders may burn their own (the Reward Burn uses it). |
| `src/StokerFactory.sol` | `launch` and `launchWithPermit`: coin by CREATE2, pool, seed, First Buy, in one transaction. Holds every seed position; no code removes liquidity. A minimal Quote Registry (`list`) behind the registry key. |
| `src/StokerHook.sol` | The fee hook: Platform Fee and Reward Tax on the Quote Asset side, three in-swap payouts with a claim fallback, Reward Burn and Reward Liquidity in the swap or by `flush`, the Graduation latch. |
| `test/Base.t.sol` | The fork fixture: pinned block, chain addresses, the hook's salt mined for the factory, NVDA listed, helpers. |
| `test/Launch.t.sol` | Points 1 and 2. |
| `test/Fees.t.sol` | Point 3, the blocklist and the empty-PoolManager cases. |
| `test/RewardTax.t.sol` | Point 4, and the Stoke Launch. |
| `test/Graduation.t.sol` | Point 5. |
| `test/UniversalRouter.t.sol` | Point 6. |
| `test/Clock.t.sol` | Point 7. |
| `test/Chain.t.sol` | The chain facts the spike stands on, including Uniswap's protocol fee controller. |
| `test/Review.t.sol` | The review's measurements (2026-11-22): what a forced Graduation costs, what the wallet that crosses Graduation takes from the waiting tax, and a donation breaking the hook's next liquidity add. |

The listing used throughout: NVDA as Quote Asset, the coin opening at a fully diluted value of about 24.8 NVDA (tick -244,200 of the coin's price in NVDA) and graduating at about 20 times that (tick -214,200), tick spacing 200, a Creator share of half the Platform Fee, a referrer share of a tenth of it.
The coin's address is chosen by CREATE2 salt, so the tests run every path with the coin on both sides of NVDA in the pool's currency order.

## Evidence, point by point

### 1. One transaction: coin, pool, single-sided seed, First Buy

- `test_launch_oneTransaction_quoteIsCurrency0` and `test_launch_oneTransaction_quoteIsCurrency1`: one call to `launch` deploys the coin, initializes the pool at the listed start price, seeds the whole supply, and swaps the First Buy.
  The Creator pays exactly 1 NVDA and receives 38,335,385,974 coins (3.83% of the supply, after the 1% fee).
  Every coin is accounted for: the PoolManager's balance, the Creator's and the factory's rounding dust (68,091 and 138,123 wei in the two orders) add up to the supply.
  The pool's LP fee is 0, the factory's position is the pool's only liquidity, and the First Buy raised the price from the start.
  Launch gas on the fork: about 1.14M, including the test's approve.
- `test_launch_withPermit_noPriorApprove`: NVDA implements ERC-2612, so a Creator with no allowance launches and makes the First Buy in one transaction, signing a permit off-chain in place of an approve transaction.
- `test_launch_refusesUnlistedQuote`: the registry is the gate.
- `test_launch_activeLiquidityAtOpen`: a quirk of the seed (gotcha 6).

### 2. No path removes the position's liquidity

- The factory has no function that removes liquidity, and its `unlockCallback` answers the PoolManager alone (`test_lock_noPathRemovesTheSeed`).
- The hook's `beforeRemoveLiquidity` refuses every removal, whoever sends it; the test tries through a liquidity router from a stranger and from the factory's address (`test_lock_noPathRemovesTheSeed`).
- `beforeAddLiquidity` admits the factory alone, so no one else can open a position whose withdrawal would matter (`test_lock_nobodyElseCanAddLiquidity`).
- The seed position's liquidity is unchanged after the attempts and after trading (`test_lock_noPathRemovesTheSeed`), and under fuzzed buys and sells (`testFuzz_lock_tradingNeverMovesTheSeed`, 64 runs).
- The hook's own Reward Liquidity position is likewise never reduced by later trading (`test_rewardTax_liquidityAfterGraduation`), and the hook has no code that removes it.

### 3. The fee on the Quote Asset's side, both directions, three recipients, LP fee zero

- `test_fee_buy_exactIn`, `test_fee_buy_exactOut`, `test_fee_sell_exactIn`, `test_fee_sell_exactOut`, each in both currency orders: the fee is 1% of the gross NVDA side of the trade, rounded up in the platform's favour; the Creator Destination, the referrer named in `hookData` and the platform receive their shares **in the same transaction**; the shares sum to the fee; the `SwapFee` event says the same.
  Exact-out sells deliver exactly the NVDA asked for.
- `test_fee_noReferrer_platformKeepsTheShare`: without a referrer the platform keeps the tenth.
- `test_fee_lpFeeIsZero`: the key's static LP fee is 0 and the hook returns no override.
- `test_fee_blockedRecipient_doesNotBrickThePool` and `test_fee_registryBlockReachesTheTransferPath`: see gotcha 1.
- `test_fee_freshQuote_swapBeforeSettle_fallsBackToClaims` and `test_fee_freshQuote_settleFirst_pushes`: see gotcha 2.

### 4. A Reward Tax: a share burned, a share added as liquidity

- `test_rewardTax_burnInTheSwap`: a 3% Reward Tax rides on the 1% Platform Fee.
  A 10 NVDA buy pays 0.1 NVDA of Platform Fee and 0.3 NVDA of tax; the tax splits into 0.075 NVDA to burn, 0.075 NVDA waiting for Graduation as liquidity, and 0.15 NVDA held for the holders as ERC-6909 claims.
  The burn share crosses the flush threshold, so the same swap buys the coin back and burns it: the coin's total supply falls inside the trade (1,567,410,176 coins for 0.075 NVDA).
- `test_rewardTax_flushByAnyone`: below the threshold the burn waits, and a stranger's call to `flush` performs it.
- `test_rewardTax_flushRefusesForeignKey`: `flush` takes a caller-supplied key and refuses one that names another hook (the safety checklist's `onlyValidPools` item, written by hand).
- `test_rewardTax_liquidityAfterGraduation`: after Graduation the liquidity share, including what waited, is added as a full-range position owned by the hook; rounding leftovers wait as claims; the hook's claims match its books.
- `test_stokeLaunch_wholeTaxBecomesLiquidity`: a Stoke Launch (liquidity share 100%) sends the whole tax to the pool and keeps no holder pot.
- `test_rewardTax_termsBounded`: a tax above 5%, or shares above 100%, are refused at launch.
- `test_review_graduationFlushCapture_tax5`, `..._tax1` and `..._control`: who ends up with the tax that waited for Graduation; see caveat B under "Held, with a caveat the review measured".
- `test_review_donationBreaksTheNextAdd`: a donation makes the next small liquidity add revert; see "In the spike's code, for the build not to copy".

### 5. Graduation as a threshold

- `test_graduation_latchesOnce_quoteIsCurrency0` and `..._quoteIsCurrency1`: 50 NVDA of buying leaves the price under the target; 60 NVDA more crosses it, and that swap emits the one `Graduated` event and records the block's timestamp.
  Selling everything back under the target leaves Graduation and its time unchanged, and crossing again emits nothing.
- `test_review_forcedGraduationCost`: what that latch costs to force; see caveat A under "Held, with a caveat the review measured".

### 6. The Universal Router, with the six-field struct

- `test_router_roundTrip_quoteIsCurrency0` and `..._quoteIsCurrency1`: a buy and a sell through the router at `0x8876789976dEcBfCbBbe364623C63652db8C0904` (commands `V4_SWAP`, actions `SWAP_EXACT_IN_SINGLE`, `SETTLE_ALL`, `TAKE_ALL`, Permit2 allowances) each deliver the V4 Quoter's figure to the wei, with the referrer in `hookData` paid in the same transaction.
  Router buy gas on the fork: about 318k to 351k, including three NVDA transfers to the fee recipients.
- `test_router_sixFieldLayout_perHopFloorBites`: with `minHopPriceX36` one above the realised price the router reverts `V4TooLittleReceivedPerHopSingle(price + 1, price)`; at the price it passes.
  That proves the router read the six-field layout; the v4-periphery pinned here still ships the five-field struct (gotcha 8).
- `test_router_rewardLaunch_nestedFlushQuotesExactly`: on a Reward Launch past Graduation, where every swap also burns and adds liquidity inside the hook, the Quoter still matches the router's delivery to the wei.

### 7. The hook reads time only

- `test_clock_noBlockNumberInRuntime`: the deployed runtime of the hook, the factory and the coin contains no `NUMBER` instruction (a walk over the bytecode that skips PUSH data and the metadata), and the hook does read `TIMESTAMP`.
  This is a property of the code, so it holds on the live chain.
- `test_clock_scannerFindsNumber`: the walk does find `NUMBER` in a contract that reads `block.number`.
- `test_clock_blockNumberChangesNothing`: the same trades under very different `block.number` values give the same result; Graduation is stamped with the timestamp.
- `test_clock_forkReportsTheL1Estimate`: what a fork models of Nitro's clocks (gotcha 4).

### 8. The safety checklist score

See "The safety checklist score" below.

## Gotchas

1. **A stock token's blocklist can brick a pool that pays inside the swap.**
   Each stock token asks one registry (`0xe10b6f6B275de231345c20D14Ab812db62151b00`) about both parties of every transfer and approve, and reverts with `Blocked(address)` (selector `0x75e91ce7`) (`test_fee_registryBlockReachesTheTransferPath`).
   A fee pushed to a blocked Creator Destination would revert every swap in that pool.
   The hook wraps each payout's `take` in `try`/`catch` and records an ERC-6909 claim instead; the swap goes through and the recipient claims later (`test_fee_blockedRecipient_doesNotBrickThePool`).
2. **An in-swap push needs the currency to be in the PoolManager already.**
   The Universal Router's order is SWAP, then SETTLE_ALL, then TAKE_ALL, so the trader's Quote Asset arrives after the hook pays out.
   With NVDA the PoolManager holds 22,484 NVDA of other pools, so the push works; with a Quote Asset it holds none of, the push fails and falls back to claims (`test_fee_freshQuote_swapBeforeSettle_fallsBackToClaims`).
   The factory settles the First Buy before it swaps, so a launch pushes even on a fresh Quote Asset (`test_fee_freshQuote_settleFirst_pushes`).
3. **Uniswap can switch a protocol fee on in our pools.**
   The PoolManager has a protocol fee controller at the pinned block (`0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`); pranked as it, `setProtocolFee` puts a fee on our zero-LP-fee pool and the trader receives less (`test_chain_protocolFeeCanBeSwitchedOnByUniswap`).
   A zero LP fee is ours to fix; the protocol fee is not.
4. **A Foundry fork does model Nitro's `block.number`, and emulates ArbSys.**
   On the fork `block.number` is the forked header's `l1BlockNumber` (26,472,290 at L2 block 120,800,000), not the L2 height, and `ArbSys(0x64).arbBlockNumber()` answers the L2 height even though the chain's code there is the `0xfe` stub; `vm.roll` moves `block.number` but not ArbSys's answer (`test_clock_forkReportsTheL1Estimate`).
   So a fork test can catch a `block.number` mistake at the forked block, but not one that depends on how the L1 estimate advances.
5. **`HookMiner` reads each candidate's code, which on a fork is an RPC call per salt.**
   The fixture mines the hook's salt with plain `computeCreate2Address` arithmetic instead (`test/Base.t.sol`).
   The factory deploys the hook from its own constructor with that salt, so the hook's factory is an immutable and there is no one-shot setter.
6. **With the coin as currency1, the pool reports no active liquidity until the first buy.**
   The pool opens on the seed range's upper edge, which v4 counts as outside the range; with the coin as currency0 it opens on the lower edge, which is inside (`test_launch_activeLiquidityAtOpen`).
   A reader of `getLiquidity` (an indexer, an aggregator's liquidity figure) sees zero until someone buys.
7. **One transaction is not one signature with an ERC-20 Quote Asset.**
   The First Buy needs an allowance; NVDA's ERC-2612 permit turns that into an off-chain signature inside the same transaction (`test_launch_withPermit_noPriorApprove`).
   A Quote Asset without ERC-2612 needs an approve transaction first, or Permit2.
8. **The v4-periphery that OpenZeppelin uniswap-hooks v1.2.1 pins still has the five-field `ExactInputSingleParams`.**
   Universal Router 2.1.1 on this chain reads six fields; the tests write the struct out by hand (`test/UniversalRouter.t.sol`).
   The knowledge base records that the five-field form does not revert and silently drops the per-hop floor (`robinhood-chain/44-uniswap-v4-hooks.md`, not re-tested here).
9. **The fee path needs the IR pipeline.**
   The hook's fee computation is too many locals for the legacy code generator ("stack too deep"), so `via_ir = true` (`foundry.toml`).
   Sizes with the optimizer at 200 runs: hook 13,356 bytes, factory 9,512, coin 1,705, all under Ethereum's 24,576 (`forge build --sizes`).
10. **Every flush is a nested swap inside the trader's swap.**
    The hook's own buy and liquidity add are self-calls, so v4 skips the hook's callbacks for them: no fee on the hook's buy-back and no `beforeAddLiquidity` gate on its add, which is what the design wants and also what makes callback-only rules unsafe to rely on.
    The Quoter simulates the same work, so quotes stay exact (`test_router_rewardLaunch_nestedFlushQuotesExactly`), but the trader whose swap crosses the threshold pays the flush's gas.

## #231's decisions: which held and which must change

Held, each with its evidence above:

- A Launch is a direct seed in one transaction, with the whole supply single-sided and the First Buy inside it (point 1).
- The position sits with a contract that has no removal path (point 2).
- The coin is a plain ERC-20, 1 trillion at 18 decimals, with no owner, mint, tax or blocklist (point 1).
- Graduation is a threshold recorded once and never reversed (point 5).
  The latch works as the ticket asked; what it is worth is caveat A below.
- The pool's LP fee is zero and the hook takes every fee in the swap, on the Quote Asset side, in both directions (point 3).
- The Reward Tax and Stoke Tax as hook fees of 1% to 5%, with the burn and liquidity shares done by our contracts and not by a job (point 4).
  The liquidity share waiting for Graduation does not hold as #231 words it; see caveat B below.
- The Universal Router and the V4 Quoter serve a delta-returning hook, so the site needs no router of its own (point 6).
- The hook reads time only (point 7).
- Robinhood Chain's stock tokens qualify as Quote Assets: NVDA's raw balances ignore its multiplier (1.000775 at the pinned block, `test_chain_nvdaIsAStockTokenWithPermit`), it carries no transfer fee, and it can sit in a pool and be paid out by a contract.
  This is proven for NVDA alone, and of the issuer's powers for the blocklist alone (gotcha 1).
  Not exercised here: the issuer's `adminBurn` from the PoolManager, the global pause, and an upgrade of the one beacon every stock token shares.
  Those three are why #231's "No key can reach a coin's liquidity" is not true of the Quote Asset's side of a pool; the evidence for them is the Robinhood Chain research (#232, PR #240, `docs/evm/research/robinhood-chain.md`), and what a listing may say about them is for #235.

### Held, with a caveat the review measured

Both were measured on 2026-11-22 by the main session's review of PR #239, with the tests in `test/Review.t.sol`, and measured again when the file was added to this branch; every figure below is from that run at the pinned block.

**A. Graduation as a threshold can be forced for about 2% of the target, and half of that returns to the Creator** (`test_review_forcedGraduationCost`).

- One wallet buys 115 NVDA of a fresh standard Launch, which crosses the Graduation tick, and sells every coin back.
  It loses 2.2885 NVDA, the 1% Platform Fee on each leg, and 1.14425 NVDA of that lands in the Creator Destination.
- The coin stays graduated with nothing left in the pool but the seed.
- With a flash loan this needs no capital, only the 2.2885 NVDA and the loan's fee.
- In #231 Graduation starts the Creator Lock's clock, takes the Graduation Fee and switches on the Reward Liquidity.
  A Creator who forces it and whose Destination is their own wallet buys all three for about 1% of the target.
- For #235: either the owner accepts "touched once" as what Graduation means on EVM, or Graduation needs a price that holds for a time, which the hook can measure, since it reads time.

**B. Tax that waits for Graduation is taken by whoever crosses it** (`test_review_graduationFlushCapture_tax5`, `..._tax1`, `..._control`).

The Reward Liquidity share and the Stoke Tax wait in the hook until Graduation.
The swap that crosses then adds everything waiting in one flush, and that flush spends half of it on one buy of the coin with no price limit.
A wallet that crosses and sells out in the same transaction keeps most of it:

| Launch | Tax waiting | Buy to cross | Round-trip result |
| --- | --- | --- | --- |
| Stoke Launch, 5% tax | 46.56 NVDA | 125 NVDA | **+27.08 NVDA** |
| Stoke Launch, 1% tax | 31.68 NVDA | 125 NVDA | **+22.13 NVDA** |
| Stoke Launch, 5% tax (control) | none | 250 NVDA | -18.46 NVDA |

- That is 58% and 70% of the locked liquidity #231 promises the pool, taken by one wallet.
- A larger crossing buy takes less, since it pays more in fee and tax: at 5% the result is +21.38 NVDA for a 250 NVDA buy, +5.81 for 500 and -27.91 for 1,000; at 1% it is +20.60, +14.44 and +0.25.
  So the smallest buy that crosses is the best one, and it is the one a bot would send.
- The cause is #231's line "Graduation ... switches on the Reward Liquidity, as on Solana".
  On Solana the pool the liquidity goes into does not exist before Graduation.
  Here the pool exists from the first block, so nothing needs to wait.
- For #235: add the liquidity share from the first trade, in threshold-sized pieces, with a cap on each flush's buy.
- As built, a coin that never graduates also keeps its liquidity share unused for ever, which for a Stoke Launch is the whole tax.

Must change:

1. **"Pays each share in that transaction" needs a fallback.**
   Paying in the swap works, but a blocked recipient or a PoolManager short of the currency must turn a payout into a claim rather than revert (gotchas 1 and 2).
   The PRD should read: each share is paid in the trade when it can be, and otherwise held for its recipient to claim.
   The site's swap builder should settle the Quote Asset before the swap where it can, so shares are pushed rather than deferred.
2. **"The pool's own LP fee is zero" is not the whole fee.**
   Uniswap's protocol fee controller can add a protocol fee to our pools at any time (gotcha 3).
   `GET /v1/platform` and `/fees` must read each pool's protocol fee from the chain, and the trade panel's quote must include it (the Quoter already does).
3. **Story 3, "one transaction and one signature", holds only for a native-asset First Buy.**
   With an ERC-20 Quote Asset it is one transaction and a permit signature where the token has ERC-2612, or an approve first where it does not (gotcha 7).

Recommended, for the grilling (#235):

4. **Take the Reward Burn and the Reward Liquidity out of the hook.**
   Doing them in the hook works, but it makes the hook hold tokens and a position and do price-impacting swaps inside other people's trades, which is most of its safety score (below) and one of the checklist's hard stops.
   A separate contract of ours, fed by the hook's push, could do the same work in the trade or on a call anyone can make, and leave the hook holding nothing.
   That lowers the hook's score, not the system's risk: the same funds, and the same buys inside other people's trades, would sit in a contract of ours beside the hook (see the score below).
5. **The native asset is untested, and the factory cannot take it.**
   `launch` pulls the First Buy with `transferFrom` on the Quote Asset, and nothing in the factory or the hook is payable.
   #231 makes the native asset a Quote Asset on every chain, and the review notes it is this chain's second most used quote.
   A push of the native asset also hands control to the recipient in the middle of a swap, which no ERC-20 here does.
   It should be the build's first slice after the launch itself.
6. **Not tested here, and the build's first slices:** the Graduation Fee, the Creator Lock's vesting, the distributor and its Merkle rounds (the holders' pot is collected here and has no way out of the hook), the Creator Ladder's raise-only key, exact-output swaps through the Universal Router, and every chain after Robinhood Chain.

## In the spike's code, for the build not to copy

Found by the review of 2026-11-22.
Nothing under `src/` was changed for them: the spike is throwaway, and this list is where the build learns what not to carry over.

1. **A donation breaks the hook's next liquidity add** (`test_review_donationBreaksTheNextAdd`).
   `_addFullRange` reads `-d.amount0()` and `-d.amount1()` as the amounts paid, but `modifyLiquidity`'s delta includes the fees the position has accrued, and `beforeDonate` is off, so anyone can donate to the pool.
   After a 50 NVDA donation to a graduated Reward Launch a 1 NVDA buy reverts with the PoolManager's `CurrencyNotSettled()`: the accrued fees outweigh what the small add pays, the hook reads the credit as a payment, and what it settles no longer matches the PoolManager's books.
   A 100 NVDA buy, whose add is larger than the accrued fees, clears it, and 1 NVDA buys work again.
   It costs the donor more than it blocks, so it is a correctness bug more than an attack.
   The build should refuse donations in `beforeDonate`, or read the fee delta that `modifyLiquidity` returns apart from the principal.
   The part of a donation that accrues to the factory's seed position can never be collected, since the factory has no code that touches the position.
2. **`creatorShareBps` is the launcher's to choose, up to 90%.**
   The fixture passes half, and that is all "the Creator's share is half" means here.
   `register` checks only that the Creator's share and the referrer's tenth fit inside the Platform Fee.
   In the build the share is the Creator Ladder's tier, set by the contract and never by the launch's caller.
3. **Any address in `hookData` is paid a tenth of the Platform Fee.**
   A trader or a bot can name itself, so the referrer's share is a standing discount out of the platform's share for anyone who fills the field.
   Whether a referrer's share comes out of the Platform Fee or sits on top of it, and who may be named, is the owner's call at #235.
4. **A blocked recipient's claim can never be collected.**
   `claim` pays `msg.sender` alone, so a share owed to a Creator Destination the issuer has blocked stays in the PoolManager for good.
   What should happen to such a share is a question for #235, not a bug.
5. **The holders' pot has no way out of the hook.**
   The hook adds the holders' part of every tax to `holderPot` and holds it as ERC-6909 claims; no function pays it to a distributor or to anyone.
6. **The casts to `uint128` and `int128` are unchecked, and neither contract uses SafeERC20.**
   The tests cover the casts for the amounts they trade, and NVDA and the coin both revert on a failed transfer.
   The build must use checked casts and SafeERC20 (Ethereum's USDT, for one, returns no bool).

## The safety checklist score

Scored against `research/notes/05-safety-checklist.md` in the v4 hooks knowledge base, rounding up where unsure, as it asks.

| Dimension | Range | Score | Why |
| --- | --- | --- | --- |
| Complexity | 0-5 | 4 | Five callbacks and both returns-delta flags; three launch types; behaviour changes at Graduation; nested swaps and adds inside a swap. |
| Custom math | 0-5 | 1 | Basis-point fees and v4's own `LiquidityAmounts`; no curve of our own. |
| External dependencies | 0-3 | 1 | No oracle; the Quote Asset's issuer can block, burn, pause and upgrade (the control surface). |
| External liquidity exposure | 0-3 | 3 | The hook holds tax and owed payouts as ERC-6909 claims and owns a liquidity position. |
| TVL potential | 0-5 | 2 | Assumed $1M to $5M across all pools; to be re-scored at that line. |
| Team maturity | 0-3 | 3 | No prior audited production deployment. |
| Upgradeability | 0-3 | 0 | No proxy, no owner, every term fixed at launch. |
| Autonomous parameter updates | 0-3 | 0 | None in the spike; the build's raise-only ladder key would make it 1. |
| Price impacting behaviour | 0-3 | 3 | A hook fee, plus buy-backs and liquidity adds inside the swap. |
| **Total** | 0-33 | **17** | **Medium (7 to 17), at its top; 18, High, once the ladder key is added.** |

Hard stops it meets, by the checklist's own wording, are two.
The hook holds a liquidity position and holds funds owed to holders and recipients.
And by the TVL score it gives itself above, 2, real TVL is past roughly $1M, which is the checklist's last hard stop.
The checklist says not to ship without a real audit when any hard stop is true, and it has no tier where an audit is optional; #231 records the owner's decision against one, so this is the number to put beside that decision at #235.
It does not create NoOp swaps: the most it takes from a specified amount is 6% (a 1% Platform Fee plus a tax capped at 5%, `test_rewardTax_termsBounded`).

What would lower it:

- Move the burn, the liquidity and the holder pot to a separate contract (recommendation 4): exposure from 3 to 1, price impact from 3 to 2 and complexity from 4 to 3, which brings the total from 17 to **13** and takes the hook off the "holds liquidity" hard stop.
  13 is still Medium, and the TVL hard stop stays.
  It also moves the risk without removing it: the same funds and the same buys inside other people's trades would sit in a second contract of ours, which the checklist's score for the hook no longer counts.
- Keep the ladder key out of the hook (a Destination contract can hold the tier), so autonomous updates stay at 0.
- Cap TVL by listing, and re-score at $1M.

Static analysis: Slither over `src/` reports 41 results, none a defect in the spike's terms.
The "arbitrary from in transferFrom" finding is the First Buy pulling from the Creator, who is always the launch's `msg.sender`; the unchecked `transfer` returns are the coin (OpenZeppelin, reverts) and NVDA (reverts); the reentrancy findings are the PoolManager calls inside an unlock that the PoolManager itself orders.
The build should still use SafeERC20 and triage each finding in writing, as the checklist requires.

## Chain-level findings for the knowledge base

Not written back from this lane (the relay gives that to `evm-research-rh`); listed here and in the PR for write-back.

- A Foundry fork of 4663 sets `block.number` to the forked header's `l1BlockNumber` and emulates `ArbSys.arbBlockNumber()` with the forked L2 height, which `vm.roll` does not move.
- The Uniswap v4 PoolManager on 4663 has a protocol fee controller, `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`, at L2 block 120,800,000, and it can set a protocol fee on any pool.
- The stock tokens revert a blocked party with `Blocked(address)`, selector `0x75e91ce7`, and check the registry on `approve` as well as transfers.
- NVDA (`0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC`) implements ERC-2612 `permit` and `nonces`, so a contract can take a stock token First Buy with a signature in one transaction.
- The PoolManager held 22,484.7 NVDA at L2 block 120,800,000, which is what lets a hook pay NVDA out mid-swap before the trader settles.
- The Universal Router and V4 Quoter deliver and quote exactly against a hook that returns deltas on both sides and makes nested swaps and liquidity adds inside `afterSwap`.
