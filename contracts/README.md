# Stoker's EVM contracts

The Foundry workspace for Stoker on EVM chains (PRD #231, ADRs 0024 to 0030), apart from the site so it can be read, tested and verified on its own.
Robinhood Chain (4663) is the first chain.
Nothing here has been deployed to any chain, live or test.

These contracts have not been audited by an independent firm (the owner's decision of 2026-11-22, ADR 0030).
What stands in for an audit is listed under "The safety checklist" below, and the gate before any deployment is #251.

## What is built (#241, #242)

The first path, end to end: a standard coin launched by Direct Seed, with the hook keeping the books (#241), paired with a listed ERC-20 or with the chain's native asset (#242).

| File | What it is |
| --- | --- |
| `src/StokerCoin.sol` | The coin: a plain ERC-20, 1 trillion at 18 decimals minted once to the factory; no owner, no mint, no transfer tax, no blocklist; a holder burns their own coins and nobody else's. |
| `src/StokerFactory.sol` | `launch` and `launchWithPermit`: in one transaction it deploys the coin (CREATE2, salted with the launcher's address), opens the Uniswap v4 pool at the Listing's start price with an LP fee of zero, places the whole supply as the Seed Position, burns the rounding dust, and makes the Creator's First Buy: from an allowance or a permit in an ERC-20, from the value sent in the native asset. It holds every Seed Position and has no code that removes liquidity. No owner, no setter; its settings are fixed at deployment and written into each Launch's terms. |
| `src/StokerHook.sol` | The hook: on every swap it takes the 1.00% Platform Fee on the Quote Asset's side, holds it as ERC-6909 claims in the PoolManager, and records it as two Credits (the Creator's share by the first Creator Tier, the rest to the platform). It calls no recipient inside a swap. `payout` is the Payout Call: anyone pays any owners, each to themselves; an owner the Quote Asset refuses keeps their Credit and the others are paid. A native Credit is paid by a gas-capped call only once the PoolManager is locked again (below). It also guards the pool: only the factory opens pools on it and adds liquidity, no removal is ever allowed, donations are refused. |
| `src/ListingStandIn.sol` | A minimal stand-in for the Quote Registry, behind `src/interfaces/IQuoteListings.sol`: a start price per Quote Asset written by one address, the zero address standing for the native asset, nothing more. #243 replaces it; it is never deployed to a live chain. |

The fee is 1.00% of the Quote Asset's side of every swap, rounded up:

| Swap | Quote Asset known | Fee | Taken in |
| --- | --- | --- | --- |
| Buy, exact in | what the trader pays | 1.00% of it | `beforeSwap` |
| Buy, exact out | what reaches the pool | so that it is 1.00% of pool plus fee | `afterSwap` |
| Sell, exact in | what the pool pays out | 1.00% of it, deducted | `afterSwap` |
| Sell, exact out | what reaches the trader | so that it is 1.00% of trader plus fee | `beforeSwap` |

The Creator's Credit is the fee times the Launch's share, rounded down, and the platform's is the rest, so the two always sum to the fee.
When the Quote Asset is the specified side (an exact-in buy, an exact-out sell) the fee is taken before the pool runs, on the whole specified amount, so the hook refuses such a swap if its own price limit stopped it early (`SwapStoppedEarly`).
Without that it would pay 1.00% of what it asked for, not of what it traded: the review of 2026-11-23 measured a fee of 1 on a buy of 1.5 (66%).
The same trade with the coin as the specified side goes through and pays on the Quote Asset that really moved; the Universal Router sets no price limit of its own on a single-pool swap, so its trades are untouched.
Nothing is transferred inside a swap, so the hook works the same for a Quote Asset the PoolManager holds none of: the local tests run on a mock Stock Token the PoolManager has never seen, which the spike's paying hook could not do (its gotcha 2).

### The native asset (#242)

The chain's native asset is a Quote Asset like any other.
Its Listing is the zero address, which is native ETH in the pool key (`currency0 = address(0)`, so it is always currency0), never WETH (#249).

- **The launch.** `launch` is payable: a First Buy in the native asset is the value sent, so the launch is one transaction and one signature, with no approval and no permit.
  The factory settles exactly the value it was sent; were the pool ever to take less, its delta would not close and the launch would revert, so no wei stays with it.
  A launch with value and an ERC-20 Quote Asset, or with value that differs from `firstBuy`, is refused (`ValueMismatch`), so the factory never has anything to refund.
  `launchWithPermit` is not payable, and skips the permit for the native asset.
- **The fee.** Trades take the 1.00% Platform Fee in the native asset exactly as in an ERC-20, as the hook's claims on currency zero, and nothing is transferred inside a swap.
  A swap with the native asset specified that its price limit stops early is refused (`SwapStoppedEarly`) in both directions, as #241's review requires.
- **The Payout Call.** `PoolManager.take` of the native asset calls the recipient with all the gas left while the PoolManager is unlocked.
  A recipient could burn the batch's gas (the `try` around it does not stop that), or call the PoolManager and leave a delta of its own that reverts everyone's payment.
  So a native Payout Call works in three steps.
  It clears the Credits and takes their sum out of the PoolManager in one unlock.
  With the PoolManager locked again and the Payout Call guarded against re-entry, it pays each owner by a call carrying `NATIVE_PAYOUT_GAS` (50,000) that copies no return data.
  It puts whatever was refused back into the PoolManager as the hook's claims in a second unlock.
  A recipient that reverts, re-enters or burns its gas fails its own call alone and keeps its Credit owed, to itself, with no redirect (ADR 0025); the others in the same call are paid.
  A recipient cannot act inside the hook's unlock, but it can open one of its own and trade as anyone can; an owner pulling their own has the gas for it.
  Such a trade books its Credits beside the call's own, which only ever adds, so the books come out whole (`test_native_payout_recipientTradingInsideItsPaymentKeepsTheBooks`, from the review of 2026-11-24).
- **Why a gas-capped call and not a pull.** ADR 0025 and story 14 say a Creator is paid without asking, so a pull alone would give a native Creator something to claim.
  The cap bounds what one recipient can cost the Keeper's batch; 50,000 gas covers a Safe 1.4.1, proven on the fork.
  An owner whose receive needs more is paid in full when they pull their own (`payout` with themselves as the owner and the caller), which forwards all the gas they bring.
  A caller that brings too little gas for a payment's full allowance reverts the whole call (`PayoutGasTooLow`) rather than starving a recipient into a refusal.
  The review swept every gas budget around that floor against a recipient that needs the whole allowance: each call either reverted whole or paid in full (`test_native_payout_noGasBudgetStarvesARecipientIntoARefusal`).

Not in this slice, by the ticket: the registry's bounds, the Admin and the Referrer Fee (#243), Graduation and the Creator Lock (#244), the tax and the Tax Vault (#245), the Opening Fee (#246), the Distributor (#247), the Creator Ladder's key and the Destination contracts (#248), and the deployment and the gate (#251).

## Run it

```sh
cd contracts
./script/deps.sh                                    # forge-std and OpenZeppelin uniswap-hooks v1.2.1, pinned, into lib/
forge test --no-match-path 'test/fork/**'           # unit and invariant tests: no RPC
forge test --match-path 'test/fork/**'              # fork tests: needs ROBINHOOD_RPC_URL
```

- Foundry 1.8.3, solc 0.8.26 (the version v4-core's PoolManager pins, which the local tests deploy from source), Cancun, via IR.
- Dependencies are pinned in `script/deps.sh` at the revisions of the spike and the v4 hooks knowledge base; nothing under `lib/` is committed and there is no submodule.
- `ROBINHOOD_RPC_URL` must be an archive endpoint: the fork tests pin L2 block 120,800,000 (2026-11-22), which the public RPC no longer serves.
  In the owner's shell it comes from the global env (Alchemy's free tier); from a worktree, `direnv exec "/Volumes/Farhan/Work Folder/Dev/AI/stoker" sh -c 'cd contracts && forge test --match-path "test/fork/**"'`.
  The first run reads the chain; later runs read Foundry's cache under `~/.foundry/cache/rpc/4663/`.
- CI (`.github/workflows/ci.yml`, job `contracts`) checks the format, builds with sizes, lints `src`, and runs every test that needs no RPC on every push, with deeper fuzz and invariant campaigns (`FOUNDRY_PROFILE=ci`); it runs the fork tests only where the repository has the `ROBINHOOD_RPC_URL` secret.

Results on 2026-11-24, with #242 after the main session's review: 70 local tests (unit, fuzz, and the four invariants of #241 in two campaigns, one per kind of Quote Asset, plus one for native leftovers) and 18 fork tests pass, the local ones under `FOUNDRY_PROFILE=ci` too.
#242 as its lane pushed it: 68 local and 17 fork tests, all passing; the review found no defect in the contracts and added two local tests, one fork test and the own-pull action in the invariant campaigns.
#241 alone, after the main session's review: 40 local and 11 fork tests.

| Contract | Runtime | Initcode | #241 |
| --- | ---: | ---: | ---: |
| `StokerFactory` | 10,397 | 20,389 | 10,228 / 18,059 |
| `StokerHook` | 8,571 | 9,451 | 6,430 / 7,290 |
| `StokerCoin` | 1,705 | 2,774 | unchanged |

Launch gas on the fork: about 1.18M with a permit First Buy in NVDA, about 1.03M with a native First Buy.
A native Payout Call to eight owners, five of them refusing (each spending its whole 50,000), took 346,778 gas on the fork.

## The tests

Every test proves behaviour from outside: what a wallet receives, what an event says, what the PoolManager reports.

| File | What it proves |
| --- | --- |
| `test/unit/Launch.t.sol` | The launch in both currency orders; the plain coin; a holder's burn; a permit First Buy, and a permit someone else submitted first; an unlisted asset refused, the native asset among them until listed; the Creator cannot choose the share; a copied salt gives another address; the factory's bounds. |
| `test/unit/Fees.t.sol` | Each of the four swap types credits exactly the fee above, in both orders, with no transfer to either recipient and no ERC-20 held by the hook; the `FeeCredited` event; a fuzz over all four; no fee on the coin's side; a swap the fee would swallow reverts; a swap with the Quote Asset specified that its price limit stops early is refused, and one with the coin specified pays 1.00% of what it really traded. |
| `test/unit/Payout.t.sol` | A stranger's Payout Call pays each owner alone; an owner pulls their own; a blocked owner stays owed while swaps go on and the others are paid, and is paid once unblocked; nothing moves a Credit but its owner's payment. |
| `test/unit/Lock.t.sol` | No removal through a router by anyone, and none from the factory's own address given code that tries (a zero-liquidity poke included); no one else adds liquidity; donations refused; no pool opens on the hook but the factory's. |
| `test/unit/SharedHook.t.sol` | Two Launches on one hook each book to their own Creator. |
| `test/unit/Clock.t.sol` | No `NUMBER` opcode in the runtime of the hook, the factory, the coin or the stand-in (a walk that skips PUSH data and the metadata), and the walk finds it where it is. |
| `test/unit/NativeLaunch.t.sol` | The native Listing; one call with value launches and makes the First Buy, native ETH as currency0, the Creator paying exactly the value, the factory and the hook keeping none; a launch without a First Buy; value that differs from the First Buy, and any value with an ERC-20, refused by name; the permit path takes no value; neither the factory nor the hook accepts stray value. |
| `test/unit/NativeFees.t.sol` | The four swap types credit exactly 1.00% of the native side, with no payment to the Creator's Destination (a contract that counts what reaches it) or the platform and nothing left with the hook or the router; a fuzz over all four; a swallowed swap refused by name; a swap with the native asset specified that its limit stops early refused in both directions, and one with the coin specified paying on what it traded; a native and an ERC-20 Launch booking apart on one hook. |
| `test/unit/NativePayout.t.sol` | Under a Keeper's 1,000,000 gas, one Payout Call pays the ordinary wallet and the platform while recipients that revert, burn their gas, return a bomb or re-enter stay owed, each refusal an event; lenient re-entrants record that a second Payout Call met the guard and a swap or take met a locked PoolManager, and are paid once; a recipient that leaves the PoolManager synced to an ERC-20 cannot stop the refused sum's return; a refused Credit is paid once accepted; a heavy wallet is paid when it pulls its own; too little gas reverts the call instead of refusing, and across every gas budget around the floor a recipient that needs the whole allowance is paid in full or the call reverts whole; a recipient that pulls its own and buys a coin from inside its payment leaves the books whole, the Credit its trade books to a refusing owner kept beside the refused one; duplicates paid once. |
| `test/utils/Recipients.sol` | The misbehaving recipients those tests and the fork's use, with one that trades from inside its payment and one that needs the whole allowance. |
| `test/invariant/Books.invariant.t.sol` | Two campaigns, a coin paired with a mock Stock Token and one paired with the native asset, the Creator's Credit owner refusing payment at random (a blocklist, a reverting contract). Under random buys and sells, with and without a price limit of their own, Payout Calls by strangers and by the Credit's own owner (the payment that forwards all the caller's gas), refusals, removals, foreign adds and donations: the Seed Position's liquidity never falls and no lock breach goes through; the Credits of every swap sum to the fee taken, which is always 1.00% of the Quote Asset's side; the claims back every Credit; every payment was a Credit; and, for the native coin, the hook, the factory and the router hold no native asset between calls. |
| `test/fork/ForkLaunch.t.sol` | Against NVDA on the real PoolManager: one call launches with a permit First Buy in both orders, the coin has no owner and no mint, every coin is in the pool or with the Creator; no call by anyone removes the Seed Position, nobody else adds liquidity, a donation is refused, and the next swap succeeds. |
| `test/fork/ForkTrade.t.sol` | Through the Universal Router the chain's traffic uses: buys and sells, exact in and exact out, deliver the V4 Quoter's figure to the wei in both orders, and a bound one wei tighter reverts; the router reads the six-field struct; a multi-hop through two Launches books each pool's fee to its own Creator; each swap credits exactly 1.00%; a stranger's Payout Call pays each owner, and with the Creator blocked by the Stock Token's registry the swaps go on, the platform is paid and the Creator stays owed; the protocol fee set by Uniswap's controller is read from the chain and appears in the quote; a stranger's `triggerFeeUpdate` leaves our pool at the policy's figure, 0; the four trades again through Universal Router v2.1.2. |
| `test/fork/ForkNative.t.sol` | Against native ETH on the real PoolManager: one call with value launches and makes the First Buy with no approval and no permit; through both Universal Routers the four trades deliver the V4 Quoter's figure to the wei, a bound one wei tighter reverts, each credits exactly 1.00% of the native side and pays nobody; the controller's policy leaves a native pool at 0; a route from one coin to another through native ETH books each pool's fee to its own Creator with no ETH reaching anyone; one Payout Call under a Keeper's gas pays an ordinary wallet, a Safe 1.4.1 and the platform while five hostile recipients stay owed; the re-entrants meet the guard and a locked PoolManager. |

## Chain facts the tests stand on

- The Universal Router is `0x8876789976dEcBfCbBbe364623C63652db8C0904`, the one the chain's traffic uses: in 2,400 blocks sampled across the 24 hours to L2 block 121,654,185 (2026-11-23), it took 478 of the 507 direct calls to a Universal Router, the feed's v2.1.2 router `0x204FAca1764B154221e35c0d20aBb3c525710498` took 28 and `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99` took 1.
- Its verified source has six-field `ExactInputSingleParams` and `ExactOutputSingleParams` (with `minHopPriceX36`); the periphery that uniswap-hooks v1.2.1 pins has five, so the tests write the structs out by hand (`test/fork/RouterLib.sol`).
- A new pool starts with no protocol fee; Uniswap's controller (`0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`) can set one, `StateView.getSlot0` returns it, and the V4 Quoter includes it.
  The controller is a `V4FeeAdapter` whose policy anyone may push into the PoolManager (`triggerFeeUpdate`); under the policy in force a pool whose hook returns deltas, as ours does, resolves to 0, and only a Uniswap governance vote changes that (`docs/evm/research/quote-assets-and-rehearsal.md`, #249).
  The hook must never implement `protocolFeeFlags()`: reporting flag 2048 would opt its pools into 40 pips each way.
- Universal Router v2.1.2 (`0x204FAca1764B154221e35c0d20aBb3c525710498`) is deployed at the pinned block and reads the same six-field structs; the four trades run through it as well.
- A buy with the native asset through either Universal Router sends it as `msg.value` and settles currency zero with `SETTLE_ALL`; at the Quoter's figure the router keeps none of it.
- Safe 1.4.1 is deployed at its usual addresses at the pinned block (the proxy factory `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`, the L2 singleton `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`, the fallback handler `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99`); a Safe made from them receives a native payment within 50,000 gas.
- NVDA has ERC-2612 `permit`, and the Stock Tokens' registry (`0xe10b6f6B275de231345c20D14Ab812db62151b00`) is asked about both parties of every transfer.

## What the next slices plug into

| Slice | Plugs into |
| --- | --- |
| #243, the Quote Registry, the Admin, the Referrer Fee | `IQuoteListings` (the Listing gains the Graduation multiple and the Referrer Fee's cap; the registry replaces `ListingStandIn`), the hook's `platform` (an immutable today; the Admin's two-step replacement decides whether the platform's Credits follow the Admin), and the hook's `_book` (a Referrer Fee is a third Credit on top, named by the trade's `hookData`, which the hook ignores today). |
| #244, Graduation and the Creator Lock | `StokerHook._afterSwap` (one hold timestamp per pool, `block.timestamp` only), `StokerHook.Terms` (the Graduation Target), and `StokerFactory._placeSeed` (the Creator Lock is held out of `SUPPLY` before the seed is placed). |
| #245, the tax and the Tax Vault | `StokerHook._beforeSwap` and `_afterSwap` (the tax beside the fee, booked to the Tax Vault), `_beforeAddLiquidity` (admits the Tax Vault's Support Liquidity beside the factory), and `Terms` (the launch type and its shares). |
| #246, the Opening Fee | `_beforeSwap` and `_afterSwap` on buys, from the Launch's start time (`Terms` gains it), with the factory's First Buy exempt by its `sender`. |
| #247, the Distributor | The Tax Vault's holders' part. A round in the native asset pays holders as `StokerHook._payoutNative` pays Credits: never a call to a holder with the PoolManager unlocked, a gas-capped call that copies no return data, a refusal kept owed, and a guard on re-entry. |
| #248, the Creator Ladder's key and the Destinations | `Terms.creatorShareBps` (the three tiers' shares written at launch, the ladder key raising only), and `LaunchParams.creatorDestination`, which already takes any address: the Destination contracts are addresses to the launch core. The factory should refuse the hook, itself and the PoolManager as a Destination: none of them accepts the native asset, so a native Credit to one is refused for good, and an ERC-20 paid to one is stranded. A Destination contract that receives the native asset must not act on `creditOf` from inside its payment, where the Credits of the same Payout Call's unpaid owners read zero. |
| #254, the Keeper's Payout Calls | `payout(currency, owners)` and the events `CreditPaid` and `CreditRefused`. In the native asset a refusing owner costs the batch up to `NATIVE_PAYOUT_GAS` and its call's overhead every time it is named, so the Keeper backs off an owner that refused (the event says who) and does not name them in every run. It sets a batch's gas from the owners' count (the cap and the overhead each, plus the two unlocks) and not from a simulation alone, since a recipient may accept in the simulation and burn its allowance in the block; a batch given too little reverts whole (`PayoutGasTooLow`) and loses nothing. |
| #251, the gate and the deployment | This README's checklist and triage, the invariant suite in `test/invariant/`, and a deploy script that mines the hook's salt as `test/utils/StokerTestBase.sol` does. |

## The safety checklist

Scored on 2026-11-23 against the v4 hooks knowledge base's `research/notes/05-safety-checklist.md`, for the hook as this slice builds it, rounding up where unsure as it asks.

### The score

| Dimension | Range | #242 | #241 | Spike | Grilling's aim | Why |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Complexity | 0-5 | 3 | 2 | 4 | 3 | Six callbacks and both returns-delta flags, four fee branches; #242 adds a second payout mode, two unlocks around a gas-capped call with a transient guard, so it rounds up to 3. No Graduation, tax or nested work yet. |
| Custom math | 0-5 | 1 | 1 | 1 | 1 | A basis-point fee rounded up, and v4's own `LiquidityAmounts` for the seed; no curve. |
| External dependencies | 0-3 | 1 | 1 | 1 | 1 | No oracle; an ERC-20 Quote Asset's issuer can block, pause, burn from the PoolManager and upgrade; the native asset has no issuer. |
| External liquidity exposure | 0-3 | 2 | 2 | 3 | 1 | The hook holds every unpaid Credit as ERC-6909 claims, so it holds funds owed to others; it holds no ERC-20 and no liquidity position, forwards nothing to another protocol, and holds native ETH only inside a Payout Call, on its way to its owners. |
| TVL potential | 0-5 | 2 | 2 | 2 | 2 | Assumed $1M to $5M across all pools; re-scored at $1M. |
| Team maturity | 0-3 | 3 | 3 | 3 | 3 | No prior audited production deployment. |
| Upgradeability | 0-3 | 0 | 0 | 0 | 0 | No proxy, no owner, no setter; terms fixed at launch. |
| Autonomous parameter updates | 0-3 | 0 | 0 | 0 | 0 | None; #248's raise-only ladder key makes it 1. |
| Price impacting behaviour | 0-3 | 2 | 2 | 3 | 2 | A hook fee on every swap; no buys or liquidity added inside a swap. |
| **Total** | 0-33 | **14** | **13** | **17** | **13** | **Medium (7 to 17).** |

Scored again for #242 on 2026-11-23: 14, one above #241's 13, for the native Payout Call's added mode (complexity 3, rounded up as the checklist asks).
#241's total met the grilling's 13 by a different route: exposure 2, not 1, because the Credits are held as the hook's claims, and complexity 2, not 3, before this slice.
Expect the finished hook to score 15 or more (#251 scores it again): Graduation, the tax and the Opening Fee keep complexity at 3 or raise it, and the ladder key adds 1.

Hard stops, by the checklist's own wording:

- Custom curve or price-affecting math: no.
- NoOp swaps: no. The fee is at most 10% of the specified amount by the factory's bound (1.00% as set), and a swap whose fee would equal its whole specified amount reverts (`SwapTooSmall`, `test_fee_tinySwapCannotBeSwallowed`).
- Holds or rehypothecates user liquidity: not liquidity, but the hook holds every unpaid Credit (fees owed to Creators and the platform) as claims in the PoolManager; it rehypothecates nothing. Said plainly so nobody reads "no" as "holds nothing".
- Reads an oracle or an external price: no.
- Upgradeable: no.
- Real TVL past roughly $1M: met by the TVL score assumed above. The checklist says not to ship past any hard stop without an audit; the owner decided against one (ADR 0030), and this is the figure that stands beside that decision.

### The pre-deployment checklist, item by item

Accounting and deltas:

- [x] Every currency the hook takes is settled before the unlock closes: the fee is minted as the hook's claims against the delta the swap owes the hook, so its net delta is zero; every swap test would revert with `CurrencyNotSettled` otherwise.
- [x] Specified versus unspecified is derived from the swap's parameters (`exactIn == zeroForOne`), never assumed; all four swap types are tested in both currency orders, locally and on the fork.
- [x] Rounding favours the platform, never the trader: the fee rounds up; the Creator's share rounds down and the platform's is the remainder.
- [x] No delta from an earlier callback is relied on: `_beforeSwap` reads the parameters, `_afterSwap` reads its own `delta`.

Permissions and deployment:

- [x] `getHookPermissions()` is exactly the eight flags used.
- [x] The constructor validates the address against them (`BaseHook`).
- [x] The mined address's low 14 bits are asserted against the expected bitmap in every test's fixture (`_deployStoker`).
- [x] No returns-delta flag without its action flag.

Access control:

- [x] Every callback is `onlyPoolManager` (the library's non-virtual entry points), and so is `unlockCallback` (`test_unlockCallback_onlyThePoolManager`).
- [x] No external function takes a caller-supplied `PoolKey` but `registerLaunch`, which only the factory may call; `beforeInitialize` admits only pools the factory opens with registered terms (`test_lock_nobodyElseInitializesAPoolOnTheHook`).
- [x] `sender` is never taken for the end user: it is compared only with the factory's address.
- [x] `hookData` is ignored.
- [x] No callback rule is relied on for an operation the hook starts: the hook starts no swap, liquidity change or donation; its PoolManager calls are `mint`, `take`, `burn` and `unlock`.

Fees:

- [x] No LP fee override: the pool's static LP fee is zero and the hook returns no override.
- [x] The protocol fee composes on the pool's swap and is read from the chain and quoted (`test_fork_protocolFee_readFromTheChain_inTheQuote`); the hook's own fee is unchanged by it.
- [x] A fee taken before the pool runs is never kept for an amount the pool did not trade: a swap with the Quote Asset specified that stops early reverts (`test_fee_quoteSpecifiedSwapStoppedByItsLimit_reverts`), which #246's Opening Fee, taken the same way, relies on.

Token review: the Listing is the allowlist (ADR 0028), and an issuer's powers are Quote Risk Labels, never a bar, by the owner's decision.

- [x] Blocklist: checked by the Stock Tokens on the sender, the recipient and the caller of every transfer and approve; a blocked Credit owner stays owed and stops nothing (`test_fork_payout_strangerPays_blockedCreatorStaysOwed`). Aimed at the PoolManager, it freezes every pool in that asset; no hook can reach that.
- [x] Pause: stops every swap of a paired coin and every payout in that asset while on; nothing is lost and nothing moves (accepted by ADR 0028).
- [ ] Burn from the PoolManager (`adminBurn`): would leave the PoolManager holding less than its pools and the hook's claims believe; not testable from a hook and accepted by ADR 0028; untested here.
- [ ] Upgrade of the one beacon behind every Stock Token: could change any of the above at once; accepted by ADR 0028; untested here.
- The holders of each power, read on 2026-11-22: `docs/evm/research/robinhood-chain.md` and the Robinhood Chain knowledge base's `robinhood-chain/56-stock-token-custody-and-payouts.md`.

Testing:

- [x] Static analysis: `forge lint src` reports nothing, each finding it raised being fixed or annotated in the code with its reason; Slither 0.11.3 with the security standards' config is triaged below.
- [x] Invariants assert delta conservation and fee bounds (`test/invariant/Books.invariant.t.sol`).
- [x] Reentrancy: a Payout Call cannot run inside a swap (the PoolManager refuses a second unlock), nor inside another Payout Call (a transient guard, `PayoutReentered`); a restored Credit is added back, never overwritten, so a swap made inside a payout's transfer cannot erase a Credit; two Launches sharing the hook are tested (`SharedHook.t.sol`, the fork's multi-hop).
- [x] Native payouts (#242): no swap pays the native asset to anyone; a native Credit is paid only with the PoolManager locked, by a call capped at 50,000 gas that copies no return data, so a recipient can neither swap or take inside the hook's unlock nor burn or bomb the batch, and a trade it makes in an unlock of its own only adds to the books; the refused sum is put back after a native `sync`, so a recipient that leaves the PoolManager synced to an ERC-20 cannot block it; a caller with too little gas reverts instead of forcing a refusal (`NativePayout.t.sol`, `ForkNative.t.sol`, each failing when its guard is removed).
- [x] Multi-hop routing through two Launches in one transaction (`test_fork_router_multiHopThroughTwoLaunches`).
- [x] Hostile recipients of the native asset: reverting, gas-burning, return-bomb and re-entering contracts, locally and on the fork, and a Safe paid beside them.
- [x] Hostile tokens: a blocklisting Quote Asset is tested locally (`MockQuote`) and on the fork (NVDA's registry); fee-on-transfer and rebasing assets are barred by the Listing rule (ADR 0028), and a short settlement would fail the launch's own delta check.

Operational (for #251):

- [x] The score, its date and its assumptions are above; it is re-scored when the hook is finished and when real TVL reaches $1M.
- [ ] The unclosed items (the hard stops, the issuer's burn and upgrade) are written here as accepted risk; the deployment runbook and the incident response are #251's.

### Static analysis triage

`forge lint src` raised 22 findings; each was fixed or is annotated in the code with its reason, and it now reports none.

- Unchecked casts (7): every sign change now goes through OpenZeppelin's `SafeCast.toUint256`, and every narrowing through v4's `SafeCast`.
- Missing zero checks (2): added for the stand-in's writer and the hook's platform.
- Unused returns (5): `initialize`'s tick (equal to the open tick by construction), a fresh position's accrued fees (zero), `settle`'s amount (any shortfall fails the unlock), and the Payout Call's empty unlock result; annotated.
- Events after external calls (4) and the reentrancy finding on the Payout Call (1): the calls are the PoolManager's, our own contracts' and the listed Quote Asset's; the Payout Call clears a Credit before the transfer and adds it back on failure.
- Calls in a loop (2): the Payout Call's, isolated per owner by `try`, paid for by the caller.
- `transferFrom` with an arbitrary `from` (1): the First Buy pulls from the launch's own caller, carried through the factory's own unlock.

#242's code raised four more, now fixed or annotated: two uninitialised locals (made explicit), the reentrancy finding on the native Payout Call's first unlock (the PoolManager's call back into the hook's own callback; a Credit is only ever added back after it), and a revert in a loop (the gas floor, which must revert the whole call).

Slither 0.11.3 (`slither . --config-file <security standards>/tooling/slither.config.json --filter-paths "lib/|test/|script/"`) reports the same classes, and two more that are its own limits: it cannot generate IR for `StokerFactory._placeSeed` and `_firstBuy` (memory structs under via IR), and so reports `SUPPLY` as unused and the launch's `seed` as uninitialized, both of which those two functions use.
For #242 it adds three: the factory "locks ether" (the same IR gap: `_firstBuy` settles exactly the value sent into the PoolManager or the launch reverts, and the tests and the native invariant hold the factory's balance at 0), the native Payout Call's reentrancy pattern (guarded, and the only writes after the calls add back refused Credits), and the assembly of the gas-capped call (on purpose, so no return data is copied).
Running Slither and the security standards' gate in CI is #251's.

## Gotchas met here

1. A local test of `PoolManager` needs solc 0.8.26 exactly, so the whole workspace is pinned there.
2. `vm.expectRevert` binds to the next external call, which in a swap helper is an `approve`; approve first, then expect, then swap (`_approveRouter` and `_swapApproved`).
3. A test that `vm.etch`es code over the factory loses the factory's views; read the seed's range before.
4. `forge-lint: disable-next-line` covers one line; a multi-line call needs `disable-start` and `disable-end`.
5. With the Quote Asset as currency0 (the coin as currency1), the pool opens on the seed's upper edge, which v4 counts as out of range: the pool reports no active liquidity until the first buy (the spike's gotcha 6, `test_launch_withoutFirstBuy`).
6. A cached local build lints only what changed, while CI's clean build lints every file, the tests included, and with warnings denied that aborted CI once; so `lint_on_build` is off and `forge lint src` is a step of its own.
   Prove a CI change from `forge clean` first.
7. Foundry gives a test near-unlimited gas, so a recipient that burns all its gas leaves 1/64 of it, still plenty, and an uncapped payment looks safe; the hostile-recipient tests send a Keeper's 1,000,000 gas, under which the uncapped design reverts the whole call.
8. A test with `vm.prank(who)` and `{value: x}` pays from `who`, and v4's `PoolSwapTest` refunds unspent value to its caller, so the native tests read a trader's own balance as the native side of a swap.
9. A fork test contract can outgrow the compiler: one more test in `ForkNativeTest` failed the whole build with a Yul "too deep in the stack" error that named none of the new code, so the route test lives in `ForkNativeRouteTest`, a small contract over the same `ForkNativeBase`.
   The local run (`--no-match-path 'test/fork/**'`) does not compile the fork tests, so only the fork run shows it; CI builds everything, so run `forge build` before pushing a fork test.
