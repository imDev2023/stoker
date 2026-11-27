# The gate before any contract reaches a live chain (#251)

Stoker's EVM contracts have not been audited by an independent firm: the owner decided against an audit on 2026-11-22 (ADR 0030), and that decision is not reopened here.
This file is the report of what stands in its place, and of what that does not cover.
It was written by the agent of lane `evm-gate` on 2026-11-27, for the tree that carries it; the owner reads it before anything is deployed to a live chain.

It has five parts: the security standards' pre-deployment gate, the v4 hooks safety checklist scored for the finished set, the invariant campaign over the whole set, the checks of a deployment, and static analysis.
The last section says plainly what none of them proves.

## 1. The pre-deployment gate

The gate is the security standards repository's own (`gate/check.py`, pinned in `script/deps.sh` at `96a6eb8`), run with Robinhood Chain's profile (`robinhood-4663`) in strict mode, where an unanswered item fails.
CI's `contracts` job runs it on every push through `script/gate.sh`, after the build and the tests.

| | Items |
| --- | ---: |
| Pass | 42 |
| Waived, each with its reason | 18 |
| Not applicable (Hardhat's) | 3 |
| Unanswered | 0 |
| Fail | 0 |

Of the 42 that pass, 19 are checked by the gate itself against the sources and the build, and 23 are attested.

**Who attested.**
The standards say an attested item is a signature, worth having because a person puts their name to it.
No person has yet: each of the 23 was answered by the agent from the code, a named test or an ADR, and the answer says which.
They are in `.evm-standards.json`, one sentence or two each, and the owner's reading of them is the signature the gate asks for.

**What the gate checks itself** (19): no `tx.origin`; no `ecrecover`; explicit visibility enforced by solhint; no `unchecked` block; no bare `transfer` or `send` of value; no `block.number` in `src` (the profile says it is not a counter on this chain, where it is an estimate of the parent chain's block); no `prevrandao`, `difficulty` or `blockhash`; no `address(this).balance` as accounting; a pinned pragma in every source; an explicit `evm_version`; warnings denied; the profile complete; Slither's and the invariant campaigns' results recorded by the run; the four property mixins inherited and run (access control, rounding direction, conservation, solvency); and a multiplier change simulated (below).

**The waivers** (18), which are where the contracts depart from the standard, each by a decision already taken or for a stated reason:

| Item | Why it is waived |
| --- | --- |
| Privileged roles are multisig | The Admin is one hardware wallet and the three server keys are single keys, by ADR 0030. Each key's reach is bounded in the contracts, and one device and one sheet of paper stand behind every cold power. |
| Proxy hazards | Nothing is proxied. |
| A circuit breaker | There is no pause anywhere, by ADR 0030, so nothing can trap a sale, a Payout Call or a claim. A defect found after launch cannot be paused either. |
| Value at risk is capped | Nothing caps it and nothing was decided. The owner's to decide before mainnet whether to start with few Listings. |
| Checks, effects, interactions without exception | Not without exception: where a write follows a call, the call is the PoolManager's, a contract of ours or the listed Quote Asset's, behind a transient guard. Where control passes to someone else's address the state is written first. |
| `nonReentrant` on every entry point | The guards are transient flags on every entry point that hands control away; entry points that call only our own views carry none. |
| Pull over push | Credits and holder rewards are pushed by a call anyone can make, by ADR 0025 and 0029, each payment isolated so a refusal stops nobody; an owner may always pull. |
| No EOA detection | The one `extcodesize` is SafeERC20's own check on the asset being paid, never on a person. |
| Four oracle items | No contract reads an oracle or any outside price. |
| A slippage bound and a deadline on every swap-shaped function | A trader's are the router's. The Tax Vault's own buys carry neither: a capped piece, an interval and the Reference Price bound them instead. |
| Coverage near 100% | Not measured; guard-removal runs stand in for it. |
| An external audit | The owner's decision. |
| A bug bounty | None exists, and none is decided. |
| Monitoring of invariant drift | The API's two alarms are not built (#254, #255); the runbook makes them a condition of mainnet. |
| A security contact | None is published yet (#256). |

**The multiplier.**
The profile's sharpest warning is the ERC-8056 multiplier of a Stock Token: it is exactly 1 at launch, so code that applies it wrongly gives the right answer in every test until the first corporate action.
The contracts are on the safe side of it by reading no price and no multiplier at all.
`test/unit/Multiplier.t.sol` moves the multiplier tenfold, before the trades and between a trade and its payments, with every contract of ours forbidden the reading: every Credit, tax, piece, pot and payment is the same to the unit, and no runtime carries the multiplier's selector or a price feed's.
It does not test a pricing module against a second source, as the standards' own property does, because the contracts have none; what the site shows of a Stock Token's amount is the stack's.

**Two limits the clock leaves, both accepted and both the owner's to know.**
A sequencer outage stops every call alike, so nothing is lost in one, but the clock runs on.
A coin whose price was left above its Graduation Target just before an outage of an hour graduates when the chain resumes, with nobody having been able to sell into the hold.
A Round Root's 24 hours also run through an outage: one posted just before a long outage leaves the Guard less time, and after an outage of a day none, with the claim and the cancel racing in the first blocks.

## 2. The v4 hooks safety checklist, scored for the finished set

Scored against the v4 hooks knowledge base's `research/notes/05-safety-checklist.md`, rounding up where unsure, as it asks.
Tiers: Low 0 to 6, Medium 7 to 17, High 18 to 33.
The checklist has no tier in which an audit is optional.

| Dimension | Range | The hook | The Tax Vault | The spike's hook | What the grilling expected |
| --- | --- | ---: | ---: | ---: | ---: |
| Complexity | 0-5 | 4 | 4 | 4 | 3 |
| Custom math | 0-5 | 2 | 2 | 1 | 1 |
| External dependencies | 0-3 | 1 | 1 | 1 | 1 |
| External liquidity exposure | 0-3 | 2 | 3 | 3 | 1 |
| TVL potential | 0-5 | 2 | 2 | 2 | 2 |
| Team maturity | 0-3 | 3 | 3 | 3 | 3 |
| Upgradeability | 0-3 | 0 | 0 | 0 | 0 |
| Autonomous parameter updates | 0-3 | 1 | 0 | 0 | 0 |
| Price impacting behaviour | 0-3 | 3 | 3 | 3 | 2 |
| **Total** | 0-33 | **18** | **18** | **17** | **13** |

**The hook: 18, High, one above the 17 each slice carried.**
Item by item:

- **Complexity, 4.**
  Six callbacks and both returns-delta flags; four fees (the Platform Fee, a Referrer Fee, a tax, the Opening Fee) in four branches by swap type; a schedule that falls with time; a Graduation Hold judged once a transaction through a transient flag; a Reference Price followed before every swap; three Creator Tiers; and two payout modes over three kinds of unlock.
  Every slice left this at the 3 it was given when the hook was a third of its size, each adding one thing and judging that one thing small.
  Read whole, the finished hook branches at least as much as the Tax Vault, which the same README scores 4, so it is 4 here.
  Read as 3 the total is 17, the top of Medium; either way nothing changes in what the checklist asks, which is an audit.
- **Custom math, 2.**
  Basis-point fees rounded up, a net amount's fee over the combined rate, the Opening Fee's straight line and its one rounding of a combined rate, and the Reference Price's rate-limited follower in sixty-thousandths of a tick.
  No curve: the pool's price is Uniswap's own.
- **External dependencies, 1.**
  No oracle.
  A Quote Asset's issuer can block, pause, burn from the PoolManager and upgrade; the keys it reads are ours.
- **External liquidity exposure, 2.**
  The hook holds every unpaid Credit as ERC-6909 claims in the PoolManager: funds owed to Creators, referrers and the platform.
  It holds no ERC-20, no position, and the native asset only inside a Payout Call.
- **TVL potential, 2.**
  Assumed $1M to $5M across all pools; scored again when real value reaches $1M.
- **Team maturity, 3.**
  No prior audited production deployment.
- **Upgradeability, 0.**
  No proxy, no owner, no setter.
- **Autonomous parameter updates, 1.**
  Two live inputs a key can change: where the platform's later share is booked follows the Admin's two-step handover, and the ladder key raises a graduated coin's Creator share, upward, twice at most, to shares fixed at its launch, with an event.
- **Price impacting behaviour, 3.**
  A fee on every swap, and in a Launch's first 20 seconds fees of up to 99% of a buy.

**The Tax Vault: 18, High**, as its slice left it: complexity 4 (six public calls, four kinds of unlock, each piece split between two sources), custom math 2 (the cap's virtual reserve at the lower of two prices, a one-sided amount's liquidity, the range's rounding), external dependencies 1, exposure 3 (every Support Liquidity position for good, and every unspent tax as claims), TVL 2, team 3, upgradeability 0, autonomous parameter updates 0, price impact 3 (it buys the coin and adds liquidity in the coin's own pool, capped and spaced, never inside a swap).

**The grilling expected 13**, by moving the burn, the liquidity and the pot out of the hook.
The move happened, and the hook then grew by what the grilling itself added (the Graduation Hold, the Opening Fee) and by what the reviews found necessary (the Reference Price, the native Payout Call's second mode, the ladder's gate).
The same funds sit in two contracts of ours, each now scoring what the spike's one hook did.

**The rest of the set**, on the same scale, none of them a hook: the Distributor 13, the factory 13, the Quote Registry and the keys 9, the three Destinations 7, a Creator Lock 5.
The factory was not scored before: complexity 2 (one launch path, the terms' steps checked, a lock deployed, the seed placed and a First Buy made in one unlock), custom math 1 (the Graduation Target's square root, v4's own liquidity arithmetic), external dependencies 1 (the Quote Asset and its permit), exposure 3 (it owns every Seed Position for good), TVL 2, team 3, upgradeability 0, autonomous parameter updates 0, price impact 2 (it sets every pool's opening price from a Listing and makes the First Buy).

### The two hard stops the set meets

The checklist names six conditions under which a hook is not to ship without a real audit, and says they are not judgement calls.
The set meets two of them.

1. **It holds other people's liquidity and funds, for good.**
   The factory holds every coin's Seed Position and the Tax Vault every Support Liquidity position, and neither has code that removes one; the hook holds every unpaid Credit; the Distributor holds every holder's unpaid reward.
   Nothing is lent on or forwarded to another protocol.
2. **It may hold more than about $1M.**
   That is the TVL score it gives itself, across all pools.

It ships past both by the owner's decision (ADR 0030), and this is the figure that stands beside that decision.

The other four it does not meet.
There is no custom curve and no math that sets a price: the fees are taken beside Uniswap's own swap.
There is no NoOp swap: a swap whose fees would take its whole specified amount reverts, and a buy always keeps at least 1% of itself; in a Launch's first second that is close to the line, for one second, by ADR 0026.
No oracle and no outside price is read: the hook reads its own pool's price to keep the Reference Price.
Nothing is upgradeable.

## 3. The invariant campaign over the whole set

`test/invariant/WholeSet.invariant.t.sol` is one campaign over the nine contracts deployed by the very code `script/Deploy.s.sol` broadcasts, from Robinhood Chain's own settings file, and passed through the deployment's own checks.
The seven per-slice campaigns beside it stay; each proves one slice against a fixture of its own.

Ten coins at most, of all three types, in the three pool kinds, naming each kind of Creator Earnings Destination, four with a Creator Lock.
The handler's 27 calls trade in all four kinds of swap, launch each type, lift prices across Graduation Targets and record Graduation, raise tiers as the ladder key and as everyone else, make every call of the Tax Vault and the Destinations, pay Credits, post, cancel and claim rounds from either pot in the Quote Asset or the coin, claim locks, write the registry, rotate and revoke keys, hand the Admin over, block addresses, try to remove liquidity from the factory's and the vault's own addresses, and wait.

| Invariant | What it holds |
| --- | --- |
| `invariant_liquidityNeverLeaves` | Every Seed Position is what its launch placed and every Support Liquidity position what was added; no removal went through. |
| `invariant_aCreatorTierNeverFalls` | A tier is 1 to 3 and never fell; only the ladder key of the moment raised, never the Admin, never before Graduation; Graduation was recorded an hour after a call first left the price at the target, and never changed. |
| `invariant_aRoundNeverPaysMoreThanItsCoinsPot` | Each of a coin's pots is what reached it less what its own rounds paid; no root owed more than its own pot held; no round paid past its total. |
| `invariant_theCreditsOfAFeeSumToTheFee` | Every fee's two Credits summed to it at the coin's tier; every Credit is booked to an address a fee named; the claims back them one for one; they are the fees taken less the payments made. |
| `invariant_noKeyOfOursMovesACreditALockOrASeed` | Around every call of the Admin, the round key, the ladder key and the Guard, nothing no key may move had moved; a Payout Call paid owners alone; a lock paid its Creator alone, by its schedule. |
| `invariant_conservation`, `invariant_solvency`, `invariant_monotonicity` | The security standards' own: every ledger of ours is backed; every Credit and posted round could be paid at once; what only grows never shrank. |
| `invariant_accessControl`, `invariant_roundingDirection` | The standards' two probing properties: 22 pairs of a privileged call and a caller that must be refused; a round trip through a pool never returns more than it cost. |

**A green run is not an empty one.**
A first version started every run from seven untraded coins, and a run of 64 calls reached Graduation in 10 runs of 130 and a paid round in 2.
Each run now starts from a seeded market (trades in every pool, two pots filled, two coins a held hour past their targets) and the handler prefers a pool it can act on.
Measured over 34 runs of 128 calls: every run traded and lifted; Graduation was recorded by the public call in 24, a tier raised in 16, a round posted in 31, cancelled in 17 and paid in 16, a Creator Lock claimed in 23.
A round paid in the coin itself was reached in 1 run of 34, so that path rests mostly on the test that drives the handler by hand.
`test_wholeSet_theHandlerReachesEverySubject` does that: it drives every call and counts each outcome exactly, so no invariant is held by a handler that never reaches its subject.

**Each invariant fails when its guard is removed.**
Seven guards were removed in turn in a scratch copy of the workspace, the campaign run each time, and the worktree's sources never touched.

| What was removed | The invariant that failed |
| --- | --- |
| The hook's refusal of every removal (`SeedPositionLocked`) | `invariant_liquidityNeverLeaves`: "a removal went through" |
| A raise must name a tier above the one held (`InvalidTier`) | `invariant_aCreatorTierNeverFalls`: "a tier fell, or a raise did not raise" |
| Only the ladder key raises (`NotLadderKey`) | `invariant_aCreatorTierNeverFalls`: "a raise by the wrong caller"; `invariant_accessControl`: "unauthorised caller reached 'raiseTier, by the round key'" |
| A root may not owe more than its own pot holds unreserved (`RootExceedsPot`) | `invariant_aRoundNeverPaysMoreThanItsCoinsPot`: "a root or a claim reached past its own pot" |
| The platform's Credit is the fee less the Creator's (written as its own rounded share instead) | `invariant_theCreditsOfAFeeSumToTheFee`: "a fee's Credits did not sum to it" |
| Only its Creator claims a Creator Lock (`NotCreator`) | `invariant_noKeyOfOursMovesACreditALockOrASeed`: "a Creator Lock paid other than its Creator"; `invariant_accessControl` |
| Only the Guard cancels a root (`NotGuard`) | `invariant_noKeyOfOursMovesACreditALockOrASeed`: "a key's call moved what no key may move" |

Each also fails `test_wholeSet_theHandlerReachesEverySubject`, at the count the removal changes.
The fifth invariant has no guard of its own to remove for a Credit: no function in the contracts lets a key move one at all, so the property is held by absence.
Its detector is shown live another way: `test_wholeSet_theKeyCheckSeesAMovedCredit` rewrites a Credit in the hook's storage and sees the hash the handler takes around every key's call change.

The first attempt at this run proved nothing and is worth knowing about.
Forge 1.8.3 does not recompile a test when only the bytecode of a source it deploys has changed ("dynamic test linking", on by default), and this campaign, which deploys through `script/deployment/`, went on running the first removal's hook: all seven removals reported the first one's failure, to the same unit of gas.
The run above passes `--no-dynamic-test-linking`.
CI builds from nothing and is not affected; anyone who changes `src` and runs this campaign locally is (`README.md`, gotcha 39).

**What it adds to CI.**
The campaign runs fewer and longer runs than the profile's, since Graduation, a raise, a lock's claim and a paid round each come at the end of a sequence: in CI 64 runs of 256 calls for the eight invariants (16,384 calls, every invariant after each), and 32 runs of 128 for the two probing properties, each probe a snapshot rolled back.
On the loaded Mac at CI's depth that is 168 seconds and 56, of 1,507 seconds of CPU for the whole local suite, whose wall time, 180 seconds, is set by its longest contracts.
In CI's `contracts` job (run 46056373135, 2026-11-27) the campaign's main contract took 103 seconds and its probes 16, and the step that runs every local test went from 1 minute 52 on `main` to 2 minutes 16.
The job as a whole went from 14 minutes to 19 minutes 15, of its 30: four minutes of that is the build, which now compiles this slice's scripts and tests; 24 seconds the tests; and 28 seconds the gate itself (Slither's install, the sources built for it, solhint, Slither and the pre-deployment gate).

The build is the part to watch, and not for its time.
With this slice's tests added, one compiler process building the whole workspace held 11 GB, and CI's 16 GB runner died in the build step twice with no compiler error.
CI now builds in parts (`script/build.sh`), each a process that ends; the largest of them held 4.7 GB, measured the same way (`README.md`, gotcha 48).

## 4. The checks of a deployment

`script/deploy.sh <chain> fork|live` deploys the nine contracts in the one order that works and runs `script/deployment/DeploymentChecks.sol`: 76 checks straight after the deployment, 79 once the three server keys are held.
`docs/runbooks/evm-mainnet.md` lists what they assert and why.
`test/unit/DeploymentGate.t.sol` makes each mistake a deployment could carry for good, one a test, and reads the name of the check that refuses it: a Distributor made for another vault, the Admin as a server key, one address in two roles, the deployer as the Admin, a piece of 100, a ladder off the decided shares, a setting that is not the file's, a Destination of another deployment, a hook that is not this build's, other code at a contract's address, a missing contract and the wrong chain.

Proven on forks alone so far: of testnet 46630 through the scripts themselves, and of Robinhood Chain at the pinned block in `test/fork/ForkDeploymentGate.t.sol`.
The rehearsal, 94 transactions, ran whole on a fork of the testnet with the same scripts and the clock moved.
The testnet's own deployment waits for one faucet claim that a person must make; issue #251 has the address and the commands.

## 5. Static analysis

Slither 0.11.3 with the security standards' config reports 90 findings on this tree, the same 90 as the last slice's, since no source changed: 3 of high impact, 20 medium, 33 low, 34 informational.
Each was read again for this report against the triage in `README.md`, and every one is a class explained there:

- **High (3).** One `transferFrom` from a named address, the funding call's own caller carried through the Tax Vault's own unlock; and two state variables "never initialized" (`_terms`, `_references`), which is Slither not being able to read the two functions that write them.
- **Medium (20).** Thirteen return values not used (a new pool's tick, a fresh position's fee delta, the fields of `getSlot0` a reader does not need, the empty answer of an unlock, `settle`'s amount); three locals "never initialized" and two reentrancy findings on the Payout Call (a Credit is cleared before its payment and added back after a refusal, behind a guard); a division before a multiplication (the support range rounded down to the tick spacing, on purpose); a strict equality (a lock's `paid == 0`, an amount, never a balance).
- **Low (33).** Fifteen comparisons of the time, the only clock these contracts read; fourteen writes or events after a call of the PoolManager's, of a contract of ours or of the listed Quote Asset's; two calls in the Payout Call's loop; two addresses with no zero check, each on purpose.
- **Informational (34).** Eleven uses of assembly, one function of cyclomatic complexity 12, and 22 functions "never used", all of which run in every swap or vault call.

They are kept as the triaged set, `slither.db.json`, and `script/gate.sh` fails CI on any finding outside it, of any severity.
An id there carries the finding's place in the source, so a change to `src` brings its findings back until they are read again.

**What Slither cannot see is the larger part of what matters.**
It cannot build its own representation of thirteen functions under this workspace's compiler pipeline, and says so on every run: the hook's `_beforeSwap`, `_afterSwap`, `_feesOnSpecified`, `_followReference`, `referenceTick` and `registerLaunch`; the factory's `_placeSeed` and `_firstBuy`; the Tax Vault's `addSupport`, `burn`, `buyForHolders`, `_swapIn` and `_addLiquidity`.
So it analyses nothing of the fee taken in a swap, the seed, the First Buy, or the vault's buys and additions, and its "never used" and "never initialized" findings are that blindness seen from the other side.
Those paths rest on the tests and the campaigns alone.

`forge lint src` reports nothing; each finding it ever raised is fixed or annotated in the code with its reason.

solhint 6.2.4 with the standards' rules reports no error and 55 warnings, all of five classes: reading the time (30; the only clock these contracts read, since `block.number` is not one here), inline assembly (18; transient storage, and calls that copy no return data), cyclomatic complexity (3), an empty block (2; the receives that take the native asset from the PoolManager alone) and a function over 60 lines (2).

## What none of this covers

Said once, plainly, so nobody reads a green gate as more than it is.

- **Nobody outside has read the code.**
  Everything above was written and run by the lanes that wrote the contracts and by the main session's reviews.
  A gate finds what its author thought to ask.
- **Business logic the tests do not state.**
  The invariants hold the five properties custody rests on and the ledgers; they do not hold that a fee is the right fee or that the Reference Price's rates are the right rates.
  What a held price can still take, and what holding the buys off costs, is measured in `README.md` and accepted there, not excluded.
- **The Quote Asset's issuer.**
  A Stock Token's issuer can block, pause, burn from the PoolManager and upgrade all of them at once; the first two are tested, the last two are not and cannot be from here (ADR 0028).
- **Uniswap v4 itself, and OpenZeppelin's `BaseHook`**, in a release (v1.2.1) that none of its three review reports covers.
- **The factory's runtime on a live chain**, beyond the explorer's verification of its source.
- **Anything off the chain**: the Reward Engine's rounds, the count of Active Days, the Keeper, the alarms, the site's quotes. None is built or it is another slice's.
- **A live chain.**
  Nothing has been deployed to one, the testnet included.
