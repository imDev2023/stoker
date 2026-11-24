# Stoker's EVM contracts

The Foundry workspace for Stoker on EVM chains (PRD #231, ADRs 0024 to 0030), apart from the site so it can be read, tested and verified on its own.
Robinhood Chain (4663) is the first chain.
Nothing here has been deployed to any chain, live or test.

These contracts have not been audited by an independent firm (the owner's decision of 2026-11-22, ADR 0030).
What stands in for an audit is listed under "The safety checklist" below, and the gate before any deployment is #251.

## What is built (#241, #242, #243, #247)

The first path, end to end: a standard coin launched by Direct Seed, with the hook keeping the books (#241), paired with a listed ERC-20 or with the chain's native asset (#242), against the on-chain Quote Registry, with the Admin and the server keys named on-chain and a Referrer Fee a trade may add (#243).
Beside it, the Distributor, which pays Holder Rewards from Round Roots after the Round Delay, with the Guard able to cancel a root inside it (#247); it is tested against a stand-in for the Tax Vault until #245 lands.

| File | What it is |
| --- | --- |
| `src/StokerCoin.sol` | The coin: a plain ERC-20, 1 trillion at 18 decimals minted once to the factory; no owner, no mint, no transfer tax, no blocklist; a holder burns their own coins and nobody else's. |
| `src/StokerFactory.sol` | `launch` and `launchWithPermit`: in one transaction it deploys the coin (CREATE2, salted with the launcher's address), opens the Uniswap v4 pool at the Listing's start price with an LP fee of zero, places the whole supply as the Seed Position, burns the rounding dust, and makes the Creator's First Buy: from an allowance or a permit in an ERC-20, from the value sent in the native asset. It launches only against an asset the Quote Registry lists, and copies the Listing's start price, Graduation multiple (with the Graduation Target it gives) and Referrer Fee cap into the Launch's terms. It holds every Seed Position and has no code that removes liquidity. No owner, no setter; its own settings are fixed at deployment, and it takes its tick spacing from the registry and its keys from the registry's. |
| `src/StokerHook.sol` | The hook: on every swap it takes the 1.00% Platform Fee on the Quote Asset's side, holds it as ERC-6909 claims in the PoolManager, and records it as two Credits (the Creator's share by the first Creator Tier, the rest to the Admin of the moment). A trade may name a referrer and a Referrer Fee up to its Launch's cap in its `hookData`; that fee is taken on top, on the same side, and recorded as a third Credit. It calls no recipient inside a swap. `payout` is the Payout Call: anyone pays any owners, each to themselves; an owner the Quote Asset refuses keeps their Credit and the others are paid. A native Credit is paid by a gas-capped call only once the PoolManager is locked again (below). It also guards the pool: only the factory opens pools on it and adds liquidity, no removal is ever allowed, donations are refused. |
| `src/QuoteRegistry.sol` | The Quote Registry (ADR 0028), behind `src/interfaces/IQuoteListings.sol`: one Listing per Quote Asset (the zero address is the native asset) with its start price, Graduation multiple and Referrer Fee cap. Only the Admin writes it; a Listing takes one write a day, a routine write moves a start price by 25% at most, and a deliberate change is scheduled 48 hours ahead (below). It holds nothing and reaches no launched coin. |
| `src/StokerKeys.sol` | The Admin and the three server keys (the round key, the ladder key, the Keeper), named on-chain (ADR 0030, story 47). The Admin is handed over, and a server key replaced, only when the new address accepts; the Admin can revoke a server key at once. It holds nothing and calls nothing. |
| `src/Distributor.sol` | The Distributor (ADR 0029): a pot per coin and asset, raised only by the Tax Vault's deposit of the holders' part and lowered only by a payment; Round Roots posted by the round key, each reserving its total from its own coin's pot; the Round Delay of 24 hours; the Guard's cancel inside it; claims anyone may submit, each paid to its holder alone, each holder's payment made on its own, a holder's rounds in a row paid as one. No owner, no setter; it reads the round key and the Guard from `StokerKeys` at each call. |
| `script/ListingWrite.s.sol` | The tool that prepares a registry write for the Admin's hardware wallet (ADR 0028): it computes the start tick from an Opening Value, checks a routine write against the 25% band, and prints the target and the calldata. It sends nothing and holds no key. |

The fee is 1.00% of the Quote Asset's side of every swap, rounded up:

| Swap | Quote Asset known | Fee | Taken in |
| --- | --- | --- | --- |
| Buy, exact in | what the trader pays | 1.00% of it | `beforeSwap` |
| Buy, exact out | what reaches the pool | so that it is 1.00% of pool plus fee | `afterSwap` |
| Sell, exact in | what the pool pays out | 1.00% of it, deducted | `afterSwap` |
| Sell, exact out | what reaches the trader | so that it is 1.00% of trader plus fee | `beforeSwap` |

The Creator's Credit is the fee times the Launch's share, rounded down, and the platform's is the rest, so the two always sum to the fee.
A Referrer Fee named by the trade is taken in the same callback, by the same rule at its own rate, on top: on a known gross both are their rates of it, and on a known net each is its rate of net plus both fees, so the Platform Fee stays 1.00% of the Quote Asset's side (below).
When the Quote Asset is the specified side (an exact-in buy, an exact-out sell) the fees are taken before the pool runs, on the whole specified amount, so the hook refuses such a swap if its own price limit stopped it early (`SwapStoppedEarly`), counting both fees.
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

### The Quote Registry (#243)

- **A Listing gates a Launch.** The factory reads the Listing in force and refuses an asset with none (`NotListed`).
  It copies every figure into the Launch's `Terms`: the start tick, the Graduation multiple, the Graduation Target as the pool's own sqrt price (the start price times the multiple, rounded so it is never an easier price to reach; #244 reads it), and the Referrer Fee cap.
  No write reaches a coin already launched: the hook reads only its own `Terms`.
- **The bounds are the contract's.** A new Listing is one write, in force at once.
  A Listing takes one write a rolling day, of every kind but a delisting (`WriteTooSoon`).
  A routine write (`writeStartPrice`) moves the start price by 25% at most, as ticks: up 2,231 (x1.24995) and down 2,876 (x0.75008), the last ticks inside the band either way (`MoveTooLarge`).
  A deliberate change of any figure (`scheduleChange`) is posted with its `effectiveAt`, readable through `scheduledChangeOf` at once, in force 48 hours later with nobody calling anything, and withdrawable by the Admin until then (`withdrawChange`).
  The moment it comes into force counts as that day's write, so the next routine write waits a day after it and moves 25% from the new price.
  While a change waits, neither a routine write nor a second change is taken (`ChangePending`).
- **The figures' own bounds.** A start price is on the pools' tick spacing (the registry's, which the factory takes), above the lowest usable tick, with 70,000 ticks of room above it for the largest Graduation Target; a Graduation multiple is 2 to 1,000; a Referrer Fee cap is at most 5.00%.
- **Delisting** (`delist`) stops new Launches on an asset at once and withdraws a waiting change; it harms nobody, so it is not held to the day.
  A delisted asset comes back only by a scheduled change, never by `list`, so the pair cannot step around the band or the 48 hours.
  This is the agent's call (the ticket names no delisting): an issuer that adds a transfer fee must be stoppable for new Launches.
- **The clocks** read `block.timestamp` alone (`test/unit/Clock.t.sol` scans the registry's runtime for `NUMBER` and finds `TIMESTAMP` there).

### The Admin and the server keys (#243)

- `StokerKeys` holds the Admin and the three server keys; the registry and the hook read the Admin from it, and #247 and #248 will read the round key and the ladder key from it.
- The Admin proposes its successor (`proposeAdmin`), who becomes the Admin only by accepting (`acceptAdmin`); a server key is replaced the same way (`proposeKey`, `acceptKey`), and the old holder keeps the role until the new one accepts.
  Proposing another address, or nobody, withdraws a proposal.
- The Admin can revoke a server key at once (`revokeKey`): a stolen key stops now, and the role goes to nobody, which the two steps exist to prevent only for a real address (the agent's call).
- An Admin handover voids every server-key proposal still waiting, since each was the previous Admin's choice and a handover may be made because that device is no longer trusted; keys already held stay (`test_keys_adminHandover_voidsWaitingServerKeyProposals`, from the review of 2026-11-24).
- Nothing in either contract reaches a coin's pool, its Seed Position, a Credit or a Creator Lock; the invariant campaigns run every Admin and server-key call beside the trades and check that none moves any of them.
- **The platform's share follows the Admin, forward only.** The hook books it to `keys.admin()` at the moment the fee is taken.
  A Credit is its owner's from the trade's block and no key may move or redirect it (ADR 0025), so a handover changes only where later shares go: what the previous Admin was owed stays owed to that address, and is paid there by anyone's Payout Call (`test_keys_handover_platformCreditsBookedBeforeStayWithTheOldAdmin`).
  The previous address is the owner's own (a device replaced, ADR 0030), so it should be paid out before or after the handover.

### The Referrer Fee (#243)

- **What a trade names.** `hookData` empty names nobody.
  Otherwise it must be exactly `abi.encode(address referrer, uint256 feeBps)`: two words, the first a clean address, the second at most the Launch's cap.
  Anything else reverts by name in `beforeSwap`, before the pool runs, and credits nobody: a length other than 64, dirty upper bits, or the zero address with a fee (`MalformedHookData`); a fee over the cap (`ReferrerFeeOverCap`); the hook, the factory or the PoolManager as the referrer, none of which can be paid usefully (`InvalidReferrer`).
  A fee of zero names nobody.
  `sender` (the router) is never read, and the factory's First Buy names no referrer.
- **What it costs.** The fee is taken on top of the Platform Fee, on the Quote Asset's side, in the same callback and by the same rule; the Platform Fee is still 1.00% of that side and its split is unchanged; and the referrer's share is a Credit like any other, paid by the same Payout Call.
  A swap that names no referrer costs exactly what it did before #243, proven to the wei against figures recorded from `main` before the hook changed, locally and through both Universal Routers on the fork (`NoReferrer.t.sol`, `ForkNoReferrer.t.sol`).
- **A sell too small for both fees** (a pool output of 1 wei owes 1 of each) reverts (`SwapTooSmall`) rather than make the trader pay to sell; with no referrer the Platform Fee alone never exceeds the output, so nothing changed there.
- **A referrer is any address,** so it is tested as hostile: one that reverts, burns its gas, returns a bomb or re-enters stays owed and stops nobody; a referrer a Stock Token blocks stays owed and is paid once unblocked; naming yourself only buys fewer coins and credits the fee back.

| Swap | Quote Asset known | Platform Fee | Referrer Fee at `r` |
| --- | --- | --- | --- |
| Buy, exact in | what the trader pays, `A` | `ceil(A x 1%)` | `ceil(A x r)` |
| Buy, exact out | what reaches the pool, `N` | `ceil(N x 1% / (1 - 1% - r))` | `ceil(N x r / (1 - 1% - r))` |
| Sell, exact in | what the pool pays out, `G` | `ceil(G x 1%)` | `ceil(G x r)` |
| Sell, exact out | what reaches the trader, `T` | `ceil(T x 1% / (1 - 1% - r))` | `ceil(T x r / (1 - 1% - r))` |

With `r` zero every row is the table above.

### The Distributor (#247)

Holder Rewards on EVM (ADR 0029): the Reward Engine computes a Reward Round off-chain, the round key posts its Round Root, and after the Round Delay anyone may submit the holders' claims, each paid to its holder.

- **The pot.** The Tax Vault hands a Reward Launch's holders' part over through `deposit(coin, asset, amount)`, the one function of `IHoldersPart` (#245): the native asset as the call's value, exactly the amount; an ERC-20 pulled from the Tax Vault, which approved exactly the amount, with no value.
  Only the Tax Vault may deposit, an address fixed at deployment.
  The asset is the Quote Asset, or the coin itself when the Launch's Payout Asset is the coin and the Tax Vault bought it with its capped buy.
  The Distributor keeps a pot per coin and asset (`potOf`), raised only by a deposit and lowered only by a payment, and refuses an asset that delivers less than the amount (`DepositShort`).
- **A Round Root reserves its total.** The round key posts `postRoot(round, coin, asset, root, total)`: the round's number (the next one, since the leaves carry it), the coin, what the round pays in, the Merkle root and what it owes in all.
  The total is reserved from that coin's pot in that asset at once, and a root that owes more than the pot holds unreserved is refused (`RootExceedsPot`), so a root can never pay beyond its own coin's pot, nor from another coin's, and a coin with nothing in its pot cannot be given a root at all.
  A round then pays at most its total (`RoundTotalExceeded`), whatever its tree says.
  The ADR's "the round pays what the Distributor holds when the root is computed" is this: the Reward Engine computes from `availableOf`, which only a post lowers, so a round posted honestly always finds its total waiting.
- **The keys, read at the moment.** The round key is `keys.holderOf(Role.RoundKey)` and the Guard is `keys.admin()`, read at each call, so a revoke or a replacement takes effect at once; an Admin that names itself the round key still cannot post (`GuardCannotPost`).
- **The Round Delay and the Guard.** A root pays from 24 hours after its posting (`RoundDelay` before then, `block.timestamp` alone); inside the delay the Guard may cancel it (`cancelRoot`), never after (`DelayOver`).
  A cancelled root never pays, and what it reserved is free again in the coin's pot for a round computed and posted again.
- **The leaf** is `keccak256(bytes.concat(keccak256(abi.encode(chainId, distributor, coin, round, holder, amount))))`, OpenZeppelin's standard leaf (`StandardMerkleTree` with the types `uint256, address, address, uint256, address, uint256`), so a proof cannot be replayed on another round, coin, Distributor or chain; `leafOf` returns it.
  One leaf per holder per round: a holder is paid once for a round (`isClaimed`), so the Reward Engine adds a holder's entries together before it builds the tree.
- **Claims.** `claim(Claim[])` takes any holders' claims from anyone, and each payment goes to its holder.
  Claims in a row for the same holder in the same asset are paid as one payment of their sum, so a holder's rounds add together.
  A claim already paid is passed over rather than reverting, so a holder's own claim landing first cannot stop the Keeper's batch; a claim on an unknown or cancelled round, inside its delay, or with a proof that does not verify reverts the call.
  Each holder's payment is made on its own: an ERC-20 by a `transfer` that returns false where SafeERC20 would revert and reads one word of return data at most, the native asset as below.
  A payment the asset refuses (a Stock Token's blocklist, its issuer's pause, a false return, a receive that reverts) leaves that holder's claims owed, every figure added back, and the others are paid; nothing is paid while the issuer's pause is on.
- **The native asset** is paid as the hook pays native Credits (#242): the Distributor holds it, so no PoolManager is unlocked around the payment; a call carrying `NATIVE_CLAIM_GAS` (50,000) that copies no return data; all the gas there is only when the holder claims for themselves; a floor that reverts the whole call rather than starve a holder (`ClaimGasTooLow`); and a transient guard on re-entry (`ClaimReentered`).
- **What a false root can do, and nothing more.** A stolen round key can post a root that pays its own addresses, bounded by three things and nothing else: the coin's pot (it cannot reserve more than is there, nor anything of another coin's), the Round Delay (nothing pays for 24 hours), and the Guard (who cancels it, after which it never pays and its reserve is free again).
  The Admin then revokes the key, which stops it at once.
  A round's unpaid claims never expire and no key can redirect them (the agent's call: ADR 0029 names no expiry).
- **Rounds of source `earnings`** (a Creator Earnings Destination of the holders, #248) will fund the same pot: the holders' Destination of a coin receives the Creator's Credits by the hook's Payout Call like any owner, and hands them to the Distributor through an entry point #248 adds beside `deposit`, admitted for that coin's own Destination alone (read from the Launch's terms, never a list a key keeps), raising `potOf[coin][asset]`; its rounds are posted, delayed, guarded and claimed exactly as a tax round's, and the bound becomes "never more than what was deposited for that coin".

Not built yet: Graduation and the Creator Lock (#244), the tax and the Tax Vault (#245), the Opening Fee (#246), the Creator Ladder's key and the Destination contracts (#248), and the deployment and the gate (#251).

## Run it

```sh
cd contracts
./script/deps.sh                                    # forge-std and OpenZeppelin uniswap-hooks v1.2.1, pinned, into lib/
forge test --no-match-path 'test/fork/**'           # unit and invariant tests: no RPC
forge test --match-path 'test/fork/**'              # fork tests: needs ROBINHOOD_RPC_URL
forge build                                         # before every push: the local run does not compile the fork tests
```

To prepare a registry write for the Admin to sign, with the chain's RPC (it reads the Listing in force and sends nothing):

```sh
REGISTRY=0x... ACTION=list QUOTE=0x... OPENING_VALUE=5000000000 MULTIPLE=20 CAP_BPS=100 \
  forge script script/ListingWrite.s.sol --rpc-url <chain>
```

`ACTION` is `list`, `write` (with `OPENING_VALUE` alone), `schedule`, `withdraw` or `delist`; `OPENING_VALUE` is the whole supply's worth in the Quote Asset's raw units (5,000,000,000 is $5,000 of a six-decimal dollar).

- Foundry 1.8.3, solc 0.8.26 (the version v4-core's PoolManager pins, which the local tests deploy from source), Cancun, via IR.
- Dependencies are pinned in `script/deps.sh` at the revisions of the spike and the v4 hooks knowledge base; nothing under `lib/` is committed and there is no submodule.
- `ROBINHOOD_RPC_URL` must be an archive endpoint: the fork tests pin L2 block 120,800,000 (2026-11-22), which the public RPC no longer serves.
  In the owner's shell it comes from the global env (Alchemy's free tier); from a worktree, `direnv exec "/Volumes/Farhan/Work Folder/Dev/AI/stoker" sh -c 'cd contracts && forge test --match-path "test/fork/**"'`.
  The first run reads the chain; later runs read Foundry's cache under `~/.foundry/cache/rpc/4663/`.
- CI (`.github/workflows/ci.yml`, job `contracts`) checks the format, builds with sizes, lints `src`, and runs every test that needs no RPC on every push, with deeper fuzz and invariant campaigns (`FOUNDRY_PROFILE=ci`); it runs the fork tests only where the repository has the `ROBINHOOD_RPC_URL` secret.

Results on 2026-11-24 with #247, the Distributor, as its lane pushed it: 163 local tests (39 new, eight invariants in the Distributor's own campaign among them) and 35 fork tests (8 new) pass, the local ones under `FOUNDRY_PROFILE=ci` too; each of the Distributor's 28 guards, removed in turn, fails a named test (the PR lists them).
#243 after the main session's review: 124 local tests (unit, fuzz, and five invariants in two campaigns, one per kind of Quote Asset, plus one for native leftovers) and 27 fork tests pass, the local ones under `FOUNDRY_PROFILE=ci` too.
Each of the 19 guards #243 adds or rests on, removed in turn, fails a named test (the PR lists them); the review added two more, each shown failing before its fix.
#243 as its lane pushed it: 122 local and 27 fork tests.
#242 after the main session's review: 70 local and 18 fork tests.
#242 as its lane pushed it: 68 local and 17 fork tests, all passing; the review found no defect in the contracts and added two local tests, one fork test and the own-pull action in the invariant campaigns.
#241 alone, after the main session's review: 40 local and 11 fork tests.

| Contract | Runtime | Initcode | #242 | #241 |
| --- | ---: | ---: | ---: | ---: |
| `StokerFactory` | 11,267 | 22,852 | 10,397 / 20,389 | 10,228 / 18,059 |
| `StokerHook` | 9,979 | 10,880 | 8,571 / 9,451 | 6,430 / 7,290 |
| `QuoteRegistry` | 3,740 | 3,965 | new | new |
| `StokerKeys` | 1,291 | 1,483 | new | new |
| `Distributor` (#247) | 5,601 | 5,827 | new | new |
| `StokerCoin` | 1,705 | 2,774 | unchanged | unchanged |

Launch gas on the fork: about 1.22M with a permit First Buy in NVDA, about 1.06M with a native First Buy (#242: 1.18M and 1.03M; the Listing's three figures and the Graduation Target are read and written into the terms).
A swap costs about 8,000 gas more than in #242: the terms take a second slot and the Admin is read from the keys.
A native Payout Call to eight owners, five of them refusing (each spending its whole 50,000), took 321,867 gas on the fork.

The Distributor's claims on the fork (#247), measured as #232 measured its minimal distributor (`docs/evm/research/robinhood-chain.md`, section 5): a round of 16,384 holders, every account and slot the claim touches marked cold, holders with no prior balance, and each total counting the 21,000 base and the calldata's gas beside the execution (`test/fork/ForkDistributorGas.t.sol`).

| Asset paid | Pushed claim, per holder of a batch of 50 | A holder's own first claim | #232: pushed, of 50 | #232: own first claim |
| --- | ---: | ---: | ---: | ---: |
| NVDA (Stock Token) | 85,479 | 167,103 | 88,648 | 152,233 |
| ETH | 84,782 | 116,985 | 87,228 | 129,005 |

A pushed claim costs about what #232 measured, so a round of 16,384 holders still costs about $50 to push at 0.02 gwei.
A holder's own first claim in NVDA costs about 15,000 more than #232's minimal distributor, which kept one cumulative figure per holder: this one reads the round (four cold slots) and writes the claim's mark, the round's paid sum and the coin's pot, for the per-round leaf, the reservation and the per-coin pot ADR 0029 asks for.
The native first claim comes out about 12,000 below #232's; why was not traced.

## The tests

Every test proves behaviour from outside: what a wallet receives, what an event says, what the PoolManager reports.

| File | What it proves |
| --- | --- |
| `test/unit/Launch.t.sol` | The launch in both currency orders; the plain coin; a holder's burn; a permit First Buy, and a permit someone else submitted first; an unlisted asset refused, the native asset among them until listed; the Creator cannot choose the share; a copied salt gives another address; the factory's bounds. |
| `test/unit/Fees.t.sol` | Each of the four swap types credits exactly the fee above, in both orders, with no transfer to either recipient and no ERC-20 held by the hook; the `FeeCredited` event; a fuzz over all four; no fee on the coin's side; a swap the fee would swallow reverts; a swap with the Quote Asset specified that its price limit stops early is refused, and one with the coin specified pays 1.00% of what it really traded. |
| `test/unit/Payout.t.sol` | A stranger's Payout Call pays each owner alone; an owner pulls their own; a blocked owner stays owed while swaps go on and the others are paid, and is paid once unblocked; nothing moves a Credit but its owner's payment. |
| `test/unit/Lock.t.sol` | No removal through a router by anyone, and none from the factory's own address given code that tries (a zero-liquidity poke included); no one else adds liquidity; donations refused; no pool opens on the hook but the factory's. |
| `test/unit/SharedHook.t.sol` | Two Launches on one hook each book to their own Creator. |
| `test/unit/Clock.t.sol` | No `NUMBER` opcode in the runtime of the hook, the factory, the coin, the registry or the keys (a walk that skips PUSH data and the metadata), the registry's clocks read `TIMESTAMP`, and the walk finds each where it is. |
| `test/unit/Registry.t.sol` | Only the Admin writes, no server key does; a new Listing is read at once and once only; every figure's bounds and their edges; a second write inside a day refused to the second, a scheduled change counting as a write; a routine write over 25% refused at the exact tick either way, on a spacing of 1, and the ticks shown to be 25% as prices; a scheduled change readable at once, not in force a second before 48 hours, in force at 48 hours with nobody calling, withdrawn before then, not withdrawable after, one at a time and no routine write meanwhile, its coming into force counting as that day's write; a delisting at once, a delisted asset back only by a schedule; a coin launched before a routine write and a scheduled change keeps its whole terms while a later coin takes the new figures; the Graduation Target is the start price times the multiple in both orders, never below it. |
| `test/unit/Keys.t.sol` | The Admin handed over only when the new address accepts, nobody else accepting, the old Admin powerless after; a proposal withdrawn; each server key replaced only when its new holder accepts, the old holder keeping it until then, one role giving no other; a revoke at once by the Admin alone, withdrawing a proposal too; a handover voiding every server-key proposal still waiting, keys already held staying; the platform's share booked to the Admin of the moment, Credits booked before a handover staying with the old Admin and paid to it. |
| `test/unit/Referrer.t.sol` | The four swap types in an ERC-20 coin in both orders and in a native coin credit the Referrer Fee on top of the Platform Fee, whose split is unchanged and which stays 1.00% of the side; an exact-in buy's Platform Fee is the very figure with no referrer; the event; a fuzz over coin, type, amount and rate; a fee over the cap, a whole word among them, refused by name in all twelve; seven malformed hookData refused by name on either side the fee is taken; our three contracts refused as referrers; a zero fee or the zero address with none is no referrer; the referrer is the named address, never the router; naming yourself gains nothing; the First Buy names none; with a referrer named, a swap its limit stops early is refused in both directions in all three coins, and one with the coin specified pays both fees on what it traded; a sell too small for both fees refused, the same sell with no referrer as before. Hostile referrers: a stranger's Payout Call pays a referrer to itself alone; a blocked referrer stays owed while the others are paid; five hostile native referrers stay owed under a Keeper's gas while an ordinary referrer, the Creator and the platform are paid. |
| `test/unit/NoReferrer.t.sol` | The four trades in both ERC-20 orders and in the native asset, to the wei against figures recorded from `main` at ce0975a before the hook changed. |
| `test/unit/ListingWrite.t.sol` | The tool's start tick for an Opening Value; calldata the registry takes from the Admin; a routine write over 25% it refuses to prepare; a figure too large for its field refused, never wrapped into another Listing. |
| `test/unit/NativeLaunch.t.sol` | The native Listing; one call with value launches and makes the First Buy, native ETH as currency0, the Creator paying exactly the value, the factory and the hook keeping none; a launch without a First Buy; value that differs from the First Buy, and any value with an ERC-20, refused by name; the permit path takes no value; neither the factory nor the hook accepts stray value. |
| `test/unit/NativeFees.t.sol` | The four swap types credit exactly 1.00% of the native side, with no payment to the Creator's Destination (a contract that counts what reaches it) or the platform and nothing left with the hook or the router; a fuzz over all four; a swallowed swap refused by name; a swap with the native asset specified that its limit stops early refused in both directions, and one with the coin specified paying on what it traded; a native and an ERC-20 Launch booking apart on one hook. |
| `test/unit/NativePayout.t.sol` | Under a Keeper's 1,000,000 gas, one Payout Call pays the ordinary wallet and the platform while recipients that revert, burn their gas, return a bomb or re-enter stay owed, each refusal an event; lenient re-entrants record that a second Payout Call met the guard and a swap or take met a locked PoolManager, and are paid once; a recipient that leaves the PoolManager synced to an ERC-20 cannot stop the refused sum's return; a refused Credit is paid once accepted; a heavy wallet is paid when it pulls its own; too little gas reverts the call instead of refusing, and across every gas budget around the floor a recipient that needs the whole allowance is paid in full or the call reverts whole; a recipient that pulls its own and buys a coin from inside its payment leaves the books whole, the Credit its trade books to a refusing owner kept beside the refused one; duplicates paid once. |
| `test/utils/Recipients.sol` | The misbehaving recipients those tests and the fork's use, with one that trades from inside its payment and one that needs the whole allowance. |
| `test/invariant/Books.invariant.t.sol` | Two campaigns, a coin paired with a mock Stock Token and one paired with the native asset, the Creator's Credit owner and a referrer refusing payment at random (a blocklist, a reverting contract). Under random buys and sells, with and without a price limit of their own, naming no referrer, an ordinary one or the hostile one at any fee up to the cap, Payout Calls by strangers for any Credit owner (the Creator's, every Admin, both referrers) and by the Credit's own owner (the payment that forwards all the caller's gas), refusals, removals, foreign adds and donations, and every call the Admin and the server keys can make (registry writes after random waits, Admin handovers, server keys replaced and revoked, server keys trying every privileged call): the Seed Position's liquidity never falls and no lock breach goes through; the Credits of every swap sum to what was taken, which is always 1.00% of the Quote Asset's side plus the Referrer Fee named; the claims back every Credit; every payment was a Credit; no privileged call moves the pool's price or liquidity, the Seed Position, any Credit, the claims or the coin's terms; and, for the native coin, the hook, the factory and the router hold no native asset between calls. |
| `test/fork/ForkLaunch.t.sol` | Against NVDA on the real PoolManager: one call launches with a permit First Buy in both orders, the coin has no owner and no mint, every coin is in the pool or with the Creator; no call by anyone removes the Seed Position, nobody else adds liquidity, a donation is refused, and the next swap succeeds. |
| `test/fork/ForkTrade.t.sol` | Through the Universal Router the chain's traffic uses: buys and sells, exact in and exact out, deliver the V4 Quoter's figure to the wei in both orders, and a bound one wei tighter reverts; the router reads the six-field struct; a multi-hop through two Launches books each pool's fee to its own Creator; each swap credits exactly 1.00%; a stranger's Payout Call pays each owner, and with the Creator blocked by the Stock Token's registry the swaps go on, the platform is paid and the Creator stays owed; the protocol fee set by Uniswap's controller is read from the chain and appears in the quote; a stranger's `triggerFeeUpdate` leaves our pool at the policy's figure, 0; the four trades again through Universal Router v2.1.2. |
| `test/fork/ForkRegistry.t.sol` | Against USDG, a real asset with no Listing: a launch reverts by name; listed by the Admin, a launch in each order opens at its start price, as NVDA and native ETH do at theirs; a routine write and a scheduled change reach only later Launches, the first coin keeping its terms and trading on. |
| `test/fork/ForkReferrer.t.sol` | Through both Universal Routers, the four trades in NVDA in both orders and in native ETH naming a referrer at 0.75%: the V4 Quoter given the same hookData quotes each to the wei, the referrer is credited the fee on top of the 1.00%, and nothing reaches it inside the swap; a fee over the cap reverts by name through both routers. |
| `test/fork/ForkNoReferrer.t.sol` | Through both Universal Routers, the same four trades naming no referrer: the Quoter's figure, what the trader paid and received and what the hook took, to the wei against figures recorded from `main` before the hook changed. |
| `test/fork/ForkRouteBase.sol` | One trade through either router in a coin paired with NVDA or native ETH, carrying the hookData a front-end puts in it; a small base so the contracts over it stay clear of the stack limit. |
| `test/fork/ForkNative.t.sol` | Against native ETH on the real PoolManager: one call with value launches and makes the First Buy with no approval and no permit; through both Universal Routers the four trades deliver the V4 Quoter's figure to the wei, a bound one wei tighter reverts, each credits exactly 1.00% of the native side and pays nobody; the controller's policy leaves a native pool at 0; a route from one coin to another through native ETH books each pool's fee to its own Creator with no ETH reaching anyone; one Payout Call under a Keeper's gas pays an ordinary wallet, a Safe 1.4.1 and the platform while five hostile recipients stay owed; the re-entrants meet the guard and a locked PoolManager. |
| `test/unit/Distributor.t.sol` | Only the round key posts, never the Guard (even holding the round key), the ladder key, the Keeper or the vault; a revoked or replaced round key stops at once, a proposed one cannot post until it accepts; the round number is the next; no empty root; a root beyond its coin's pot refused to the unit, one at it taken, none for a coin with nothing in its pot, none paid from another coin's pot or the same coin's other asset; a claim a second before the delay reverts by name and succeeds at it; the Guard cancels inside the delay, its claims never pay, its reserve is free and the round posted again pays; no cancel after the delay, by anyone but the Admin of the moment, or twice; a stranger's batch pays each holder their own and the caller nothing; a claim paid once whether repeated in a batch or in a later one; three rounds of one holder paid in one call as one transfer, and claims in two assets paid apart; a proof refused for another amount, holder, round, coin, Distributor or chain; never past a round's total; a blocked holder, a paused asset and an asset returning false each leave holders owed while the others are paid, and pay once cleared; a refused merged payment leaves every round in it owed; a round paid in the coin; only the Tax Vault deposits, the value exactly the native amount and none with an ERC-20, a short transfer refused, plain value refused. |
| `test/unit/DistributorNative.t.sol` | Under a Keeper's 1,000,000 gas, a native batch pays an ordinary wallet and a counting contract while holders that revert, burn their gas, return a bomb or re-enter stay owed, each refusal an event; a lenient re-entrant meets the guard and is paid once; a refused holder is paid once it accepts; a heavy wallet refused when pushed is paid when it claims its own; too little gas reverts the whole batch; across every gas budget from 60,000 to 200,000 a holder that needs the whole allowance is paid in full or the call reverts by name; duplicates paid once. |
| `test/invariant/Distributor.invariant.t.sol` | One campaign over two coins, a mock Stock Token and the native asset, six holders (one the Stock Token blocks at random, one refusing the native asset at random, one always burning its gas): deposits, rounds posted at random amounts up to the pot, the Guard cancelling in and after the delay, the Guard, a stranger and the vault trying to post, time passing, strangers' batches with duplicates and rounds still in their delay, holders claiming their own. Every pot is its deposits less its payments and the pots are exactly what the Distributor holds; a coin's rounds never pay more than its pot received; no holder is paid twice for a round; nothing is paid inside the Round Delay; a cancelled root pays nothing; each holder is paid exactly their leaf, no round more than its leaves or its total, and the round's own count agrees; every payment is a `Claimed` event and every such event a payment; nobody but the round key posts, and the Guard cancels only in time. |
| `test/fork/ForkDistributor.t.sol` | Against NVDA and native ETH on the real chain: a claim a second before the delay reverts and succeeds at it; a root beyond its coin's pot, or for a coin with nothing in its pot, is refused while another coin's pot sits beside it, and one at it pays without touching the other; a stranger pushes 50 holders' claims in one call, each receives their own, and with one blocked by the Stock Token's registry the other 49 are paid and the blocked one stays owed until unblocked; with the issuer's pause on nothing is paid and all stay owed, then all are paid; rounds paid in the coin for a coin on either side of an NVDA pool and one paired with native ETH; a native round pays a wallet and a Safe 1.4.1 while four hostile holders stay owed. |
| `test/fork/ForkDistributorGas.t.sol` | The gas of a pushed claim and of a holder's own first claim, in NVDA and ETH, measured as #232 measured (below), each bounded so a dearer claim fails. |

## Chain facts the tests stand on

- The Universal Router is `0x8876789976dEcBfCbBbe364623C63652db8C0904`, the one the chain's traffic uses: in 2,400 blocks sampled across the 24 hours to L2 block 121,654,185 (2026-11-23), it took 478 of the 507 direct calls to a Universal Router, the feed's v2.1.2 router `0x204FAca1764B154221e35c0d20aBb3c525710498` took 28 and `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99` took 1.
- Its verified source has six-field `ExactInputSingleParams` and `ExactOutputSingleParams` (with `minHopPriceX36`); the periphery that uniswap-hooks v1.2.1 pins has five, so the tests write the structs out by hand (`test/fork/RouterLib.sol`).
- A new pool starts with no protocol fee; Uniswap's controller (`0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`) can set one, `StateView.getSlot0` returns it, and the V4 Quoter includes it.
  The controller is a `V4FeeAdapter` whose policy anyone may push into the PoolManager (`triggerFeeUpdate`); under the policy in force a pool whose hook returns deltas, as ours does, resolves to 0, and only a Uniswap governance vote changes that (`docs/evm/research/quote-assets-and-rehearsal.md`, #249).
  The hook must never implement `protocolFeeFlags()`: reporting flag 2048 would opt its pools into 40 pips each way.
- Universal Router v2.1.2 (`0x204FAca1764B154221e35c0d20aBb3c525710498`) is deployed at the pinned block and reads the same six-field structs; the four trades run through it as well.
- A buy with the native asset through either Universal Router sends it as `msg.value` and settles currency zero with `SETTLE_ALL`; at the Quoter's figure the router keeps none of it.
- Safe 1.4.1 is deployed at its usual addresses at the pinned block (the proxy factory `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`, the L2 singleton `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`, the fallback handler `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99`); a Safe made from them receives a native payment within 50,000 gas.
- USDG (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`) is deployed at the pinned block, and a pool against it opens at a Listing's start price in either currency order.
- NVDA has ERC-2612 `permit`, and the Stock Tokens' registry (`0xe10b6f6B275de231345c20D14Ab812db62151b00`) is asked about both parties of every transfer.

## What the next slices plug into

| Slice | Plugs into |
| --- | --- |
| #244, Graduation and the Creator Lock | `StokerHook._afterSwap` (one hold timestamp per pool, `block.timestamp` only), `StokerHook.Terms.graduationSqrtPriceX96` (the Graduation Target, already written at launch as the pool's own sqrt price: above the open price with the coin as currency0, below it with the Quote Asset as currency0, so the comparison flips with `quoteIsCurrency0`), and `StokerFactory._placeSeed` (the Creator Lock is held out of `SUPPLY` before the seed is placed). |
| #245, the tax and the Tax Vault | `StokerHook._beforeSwap` and `_afterSwap` (the tax beside the fee, booked to the Tax Vault), `_beforeAddLiquidity` (admits the Tax Vault's Support Liquidity beside the factory), and `Terms` (the launch type and its shares). |
| #246, the Opening Fee | `_beforeSwap` and `_afterSwap` on buys, from the Launch's start time (`Terms` gains it), with the factory's First Buy exempt by its `sender`. |
| #245, the Tax Vault, for the Distributor | `Distributor.deposit(coin, asset, amount)`, the signature of `IHoldersPart` (the Distributor declares it until #245's interface file lands, then inherits it), called by the Tax Vault alone. The Distributor is deployed first with the Tax Vault's address computed ahead, since the Tax Vault in turn fixes the Distributor's (`test/utils/DistributorHelpers.sol` deploys a stand-in in its place). |
| #248, rounds of source `earnings` | An entry point beside `deposit` that raises the same `potOf[coin][asset]`, admitted for that coin's own holders' Destination alone (above). |
| #254 and #255, the Keeper and the Reward Engine | `availableOf(coin, asset)` is what a round may owe; `leafOf` and `roundCount() + 1` build the tree; `postRoot` by the round key; `claim` by the Keeper once `roundOf(round).postedAt + ROUND_DELAY` has passed, with the events `RootPosted`, `RootCancelled`, `Claimed` and `ClaimRefused`. In the native asset a refusing holder costs the batch up to `NATIVE_CLAIM_GAS` and its overhead each time, so the Keeper backs off a holder that refused and sets a batch's gas from its count, as for the Payout Call; in a Stock Token it waits while the issuer's pause is on. The API recomputes each posted root from its own index and wakes the owner on a mismatch, so the Guard can cancel inside the 24 hours. |
| #248, the Creator Ladder's key and the Destinations | `StokerKeys.holderOf(Role.LadderKey)`, read at the moment of the call. `Terms.creatorShareBps` (the three tiers' shares written at launch, the ladder key raising only), and `LaunchParams.creatorDestination`, which already takes any address: the Destination contracts are addresses to the launch core. The factory should refuse the hook, itself and the PoolManager as a Destination: none of them accepts the native asset, so a native Credit to one is refused for good, and an ERC-20 paid to one is stranded. A Destination contract that receives the native asset must not act on `creditOf` from inside its payment, where the Credits of the same Payout Call's unpaid owners read zero. |
| #254, the Keeper's Payout Calls | `payout(currency, owners)` and the events `CreditPaid` and `CreditRefused`. In the native asset a refusing owner costs the batch up to `NATIVE_PAYOUT_GAS` and its call's overhead every time it is named, so the Keeper backs off an owner that refused (the event says who) and does not name them in every run. It sets a batch's gas from the owners' count (the cap and the overhead each, plus the two unlocks) and not from a simulation alone, since a recipient may accept in the simulation and burn its allowance in the block; a batch given too little reverts whole (`PayoutGasTooLow`) and loses nothing. |
| #251, the gate and the deployment | This README's checklist and triage, the invariant suite in `test/invariant/`, and a deploy script in the order the fixture uses: `StokerKeys` with the Admin's address (checked against the hardware wallet), `QuoteRegistry` with the keys and the tick spacing, then `StokerFactory` with the registry, the hook's salt mined over `abi.encode(poolManager, keys)` as `test/utils/StokerTestBase.sol` does. The first Listings are the Admin's writes, prepared by `script/ListingWrite.s.sol`. |

## The safety checklist

Scored against the v4 hooks knowledge base's `research/notes/05-safety-checklist.md`, for the hook as each slice builds it, rounding up where unsure as it asks; last on 2026-11-24 for #243.

### The score

| Dimension | Range | #243 | #242 | #241 | Spike | Grilling's aim | Why |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Complexity | 0-5 | 3 | 3 | 2 | 4 | 3 | Six callbacks and both returns-delta flags, four fee branches; #242 adds a second payout mode, two unlocks around a gas-capped call with a transient guard, so it rounds up to 3. #243 reads a referrer from `hookData` and takes a second fee in the same four branches, by the same rule; still no Graduation, tax or nested work, so it stays 3. |
| Custom math | 0-5 | 1 | 1 | 1 | 1 | 1 | Basis-point fees rounded up, a net amount's fee over the combined rate, and v4's own `LiquidityAmounts` for the seed; no curve. |
| External dependencies | 0-3 | 1 | 1 | 1 | 1 | 1 | No oracle; an ERC-20 Quote Asset's issuer can block, pause, burn from the PoolManager and upgrade; the native asset has no issuer. The keys it reads the Admin from are ours. |
| External liquidity exposure | 0-3 | 2 | 2 | 2 | 3 | 1 | The hook holds every unpaid Credit as ERC-6909 claims, so it holds funds owed to others, referrers' among them; it holds no ERC-20 and no liquidity position, forwards nothing to another protocol, and holds native ETH only inside a Payout Call, on its way to its owners. |
| TVL potential | 0-5 | 2 | 2 | 2 | 2 | 2 | Assumed $1M to $5M across all pools; re-scored at $1M. |
| Team maturity | 0-3 | 3 | 3 | 3 | 3 | 3 | No prior audited production deployment. |
| Upgradeability | 0-3 | 0 | 0 | 0 | 0 | 0 | No proxy, no owner, no setter; terms fixed at launch. |
| Autonomous parameter updates | 0-3 | 1 | 0 | 0 | 0 | 0 | #243: where the platform's share of later fees is booked follows the Admin's two-step handover, the one live input to the hook a key can change; a launched coin's terms stay fixed. Rounded up to 1; #248's raise-only ladder key keeps it at 1. |
| Price impacting behaviour | 0-3 | 2 | 2 | 2 | 3 | 2 | A hook fee on every swap, and a Referrer Fee on top when a trade names one; no buys or liquidity added inside a swap. |
| **Total** | 0-33 | **15** | **14** | **13** | **17** | **13** | **Medium (7 to 17).** |

Scored again for #243 on 2026-11-24: 15, one above #242's 14, for the Admin-driven recipient of the platform's share (autonomous parameter updates 1, rounded up).
The Referrer Fee itself adds no dimension: it is a second rate on the branches that already took one, read from data every swap already carried.
Scored again for #242 on 2026-11-23: 14, one above #241's 13, for the native Payout Call's added mode (complexity 3, rounded up as the checklist asks).
#241's total met the grilling's 13 by a different route: exposure 2, not 1, because the Credits are held as the hook's claims, and complexity 2, not 3, before this slice.
Expect the finished hook to score 15 or more (#251 scores it again): Graduation, the tax and the Opening Fee keep complexity at 3 or raise it; the ladder key now adds nothing beyond #243's 1.

The Quote Registry and the keys are not hooks, but scored on the same scale for #251 they total 9 (Low): complexity 2 (a write band, a rolling day, a scheduled change folded in on read), custom math 1 (the band as ticks), external dependencies 0, liquidity exposure 0 (they hold nothing), TVL potential 0, team maturity 3, upgradeability 0, autonomous parameter updates 2 (the Admin writes the figures every future Launch opens with, bounded by the band, the day and the 48 hours), price impacting behaviour 1 (a new Launch's opening price, never a live pool's).
What they guard is the start price of every future Launch: a stolen Admin key can move a Listing 25% a day, or any figure 48 hours after posting it, in public, and can do nothing to a launched coin.

The Distributor (#247) is not a hook either; scored on the same scale on 2026-11-24 it totals 13 (Medium):

| Dimension | Range | Distributor | Why |
| --- | --- | ---: | --- |
| Complexity | 0-5 | 2 | Roots with a reservation, a delay and a cancel; claims grouped per holder, two payment modes, a refusal put back figure by figure, a transient guard. No pool, no unlock, no swap. |
| Custom math | 0-5 | 1 | Sums and differences of amounts; the Merkle proof is OpenZeppelin's. |
| External dependencies | 0-3 | 1 | No oracle; a Stock Token's issuer can block, pause, burn from and upgrade the asset it holds; the keys it reads are ours. |
| External liquidity exposure | 0-3 | 2 | It holds every Reward Launch's holders' part, funds owed to others, as plain balances; it forwards nothing to another protocol. |
| TVL potential | 0-5 | 2 | A share of every Reward Tax waiting a day or more; assumed within the hook's $1M to $5M. |
| Team maturity | 0-3 | 3 | No prior audited production deployment. |
| Upgradeability | 0-3 | 0 | No proxy, no owner, no setter. |
| Autonomous parameter updates | 0-3 | 2 | The round key decides who is paid what, a server key; bounded by each coin's pot, the 24-hour delay and the Guard, and by nothing else. |
| Price impacting behaviour | 0-3 | 0 | It trades nothing. |
| **Total** | 0-33 | **13** | **Medium (7 to 17).** |

Hard stops: it holds user funds (the holders' part), said plainly; no curve, no NoOp swap, no oracle, no upgrade; its real TVL passing $1M is the same stop the hook meets, by the owner's decision without an audit (ADR 0030).
Its own checklist, item by item:

- [x] Only the Tax Vault deposits, and only exactly the amount arrives (`test_deposit_onlyTheTaxVault`, `test_deposit_aShortTransferIsRefused`).
- [x] Only the round key of the moment posts, never the Guard, and a revoke stops it at once (`test_post_*`).
- [x] A root can never owe more than its own coin's pot in its own asset holds unreserved (`test_pot_*`, `test_fork_aRootBeyondItsCoinsPotCannotPay_andCoinsAreApart`, the invariants).
- [x] Nothing pays inside the Round Delay; only the Guard cancels, only inside it; a cancelled root pays nothing (`test_delay_*`, `test_guard_*`, the invariants).
- [x] A leaf binds the chain, the Distributor, the coin, the round, the holder and the amount, hashed twice (`test_claim_aProofCannotBeReplayed`).
- [x] A holder is paid once per round, never past the leaf or the round's total, and always to the holder (`test_claim_*`, the invariants).
- [x] Each payment is isolated, and a refusal leaves every figure as it was (`test_claim_aBlockedHolderStaysOwed_andTheOthersArePaid`, the pause and false-return tests, `test_fork_aStrangerPushesFiftyClaims_oneBlockedStaysOwed`).
- [x] Native payments: a gas cap, no return data copied, a floor that reverts the whole call, a guard on re-entry, all the gas only to a holder claiming their own (`DistributorNative.t.sol`, `test_fork_native_walletAndSafePaid_hostileHoldersStayOwed`).
- [x] Its clocks read `block.timestamp` alone (`test_clock_theDistributorReadsTimeOnly`).
- [ ] The issuer's `adminBurn` from the Distributor would leave a pot counting more than it holds, and the last claims in that asset would be refused until topped up; not testable from here and accepted by ADR 0028, as for the hook.

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
- [x] `hookData` is read defensively (#243): empty names nobody; otherwise exactly two words, a clean address and a fee up to the Launch's cap, or the swap reverts by name before the pool runs; our own three contracts are refused as referrers; a malformed `hookData` never credits anyone (`test_referrer_malformedHookData_revertsByName`).
- [x] Every privileged call is the Admin's (`QuoteRegistry`, `StokerKeys`), and none reaches a pool, a Seed Position, a Credit or a launched coin's terms (`invariant_noPrivilegedCallTouchesAPoolASeedOrACredit`, under every Admin and server-key call in both campaigns).
- [x] No callback rule is relied on for an operation the hook starts: the hook starts no swap, liquidity change or donation; its PoolManager calls are `mint`, `take`, `burn` and `unlock`.

Fees:

- [x] No LP fee override: the pool's static LP fee is zero and the hook returns no override.
- [x] The protocol fee composes on the pool's swap and is read from the chain and quoted (`test_fork_protocolFee_readFromTheChain_inTheQuote`); the hook's own fee is unchanged by it.
- [x] A fee taken before the pool runs is never kept for an amount the pool did not trade: a swap with the Quote Asset specified that stops early reverts (`test_fee_quoteSpecifiedSwapStoppedByItsLimit_reverts`), counting the Referrer Fee beside the Platform Fee in both directions for an ERC-20 and the native asset (`test_referrer_quoteSpecifiedSwapStoppedByItsLimit_reverts`), which #246's Opening Fee, taken the same way, relies on.
- [x] A Referrer Fee is on top and capped per Launch: the Platform Fee and its split are unchanged by it, and a swap naming no referrer costs exactly what it did before #243, to the wei, locally and through both Universal Routers (`NoReferrer.t.sol`, `ForkNoReferrer.t.sol`); the V4 Quoter, given the same `hookData`, includes it to the wei (`ForkReferrer.t.sol`).

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
- [x] Hostile recipients of the native asset: reverting, gas-burning, return-bomb and re-entering contracts, locally and on the fork, and a Safe paid beside them; the same contracts named as referrers stay owed under a Keeper's gas (`test_referrer_payout_hostileNativeReferrersStayOwed`), and a referrer a Stock Token blocks stays owed (`test_referrer_payout_blockedReferrerStaysOwed`).
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

#243's code raised 13 more, each fixed or annotated: the registry's five comparisons of `block.timestamp` (its two clocks, a day and 48 hours, which a sequencer's few seconds move by as much and no more), four casts to `uint40` (timestamps, which last until the year 36812), the cast of `hookData`'s first word to an address (its upper bits checked zero first), a missing zero check on `proposeAdmin` (the zero address withdraws a proposal and nobody can accept for it), and two uninitialised locals in `_afterSwap` (made explicit, with the two in `_referral` beside them).

#242's code raised four more, now fixed or annotated: two uninitialised locals (made explicit), the reentrancy finding on the native Payout Call's first unlock (the PoolManager's call back into the hook's own callback; a Credit is only ever added back after it), and a revert in a loop (the gas floor, which must revert the whole call).

Slither 0.11.3 (`slither . --config-file <security standards>/tooling/slither.config.json --filter-paths "lib/|test/|script/"`) reports the same classes, and two more that are its own limits: it cannot generate IR for `StokerFactory._placeSeed` and `_firstBuy` (memory structs under via IR), and so reports `SUPPLY` as unused and the launch's `seed` as uninitialized, both of which those two functions use.
For #242 it adds three: the factory "locks ether" (the same IR gap: `_firstBuy` settles exactly the value sent into the PoolManager or the launch reverts, and the tests and the native invariant hold the factory's balance at 0), the native Payout Call's reentrancy pattern (guarded, and the only writes after the calls add back refused Credits), and the assembly of the gas-capped call (on purpose, so no return data is copied).
For #243 it adds four, each expected: the registry's timestamp comparisons (its clocks), the zero-address `proposeAdmin` (a withdrawal), `_book`'s writes after the PoolManager's `mint` (the only call before them, with our own keys' view), and the assembly in `_referral` (two `calldataload`s, so a malformed `hookData` reverts by name rather than inside `abi.decode`).
For #247 it adds eight, each expected: the deposit's pot written after the asset's `transferFrom` and its event after it (benign and events reentrancy: only our own Tax Vault may call, and the pull is checked to the unit before the pot rises), the two comparisons of `block.timestamp` (the Round Delay, a day, which a sequencer's few seconds move by as much and no more), three uses of assembly (the gas-capped native call that copies no return data, the ERC-20 `transfer` that reads one word of return data at most and returns false where SafeERC20 reverts, and the transient guard), and `claim`'s cyclomatic complexity of 12 (the grouping per holder, each refusal put back; every branch has a guard test above).
`forge lint src` raised three on the Distributor, each annotated with its reason: the deposit's exact equality (on purpose, so a pot never counts more than arrived) and two reverts in `claim`'s loop (a claim on no round, or with a proof that does not verify, is the caller's error and reverts the call).
It reports 39 results in all, every one a class triaged here.
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
10. Under via IR a test's `block.timestamp` can be read once and reused after `vm.warp`, so a second `vm.warp(block.timestamp + 1 days)` in the same test does not move the clock; the registry's tests read `vm.getBlockTimestamp()` instead.
11. Gotcha 2's general form: `vm.expectRevert` binds to the next external call, and reading the pool's price for a limit (`getSlot0` is an `extsload`) inside the swap's own arguments is one; read the limit into a local first.
12. Every handler function added to an invariant campaign dilutes the trades in a run: with #243's five, a run of 64 calls once held four trades, all stopped by their own limits, and `afterInvariant`'s "no swap went through" failed; the campaign now has four trade entry points.
    A failing sequence persists under `cache/invariant/failures/` and replays on the next run even after the fix, so delete the file once the cause is gone.
13. `vm.recordLogs` records the events of a call that reverted as well, so a handler that reads events after a `try` must read them only when the call went through; the Distributor's campaign counted payments that a later claim's revert had undone until it did.
14. Gotcha 10 holds for `block.chainid` too: read it once, `vm.chainId` another, and a second read can return the first value, so a test that restores the chain id reads it through an external call first.
15. Claims in a batch that name a round still inside its delay revert the whole call, so an invariant campaign that picks rounds at random rarely pays; the Distributor's handler names rounds that may pay now in seven batches of eight and any round in the eighth.
