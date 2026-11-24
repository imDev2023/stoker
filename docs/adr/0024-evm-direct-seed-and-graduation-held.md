# On EVM chains a Launch is a Direct Seed, and Graduation is the target held for one hour

Status: accepted by the owner on 2026-11-23 (#235), not built.
It is the first of seven decisions for the EVM chain family (ADR 0024 to 0030, PRD #231).
Solana's launch shape (ADR 0005), its Graduation and its Creator Lock (ADR 0023) stand untouched; this decision amends #231's "Graduation is a threshold" and its "one transaction and one signature".

No EVM chain has a LaunchLab, so on EVM the curve, the reserves and Graduation are contracts of our own on Uniswap v4.
The owner chose the launch shape on 2026-11-22: a direct seed, with no bonding curve and no migration.
A throwaway spike proved it on a fork of Robinhood Chain against the real PoolManager, Universal Router and V4 Quoter with NVDA as the Quote Asset (`spike/evm-robinhood-fork/README.md`, 42 fork tests at L2 block 120,800,000).
The spike also measured what #231's Graduation was worth.
#231 recorded Graduation the first time the pool's price touched the Graduation Target, and one wallet could buy across the target and sell straight back for about 2% of the target, half of that returning to the Creator, with a flash loan and no capital; the coin stayed graduated with nothing left in the pool (`test/Review.t.sol`, 2.2885 NVDA lost on a 115 NVDA buy, 1.14425 of it to the Creator Destination).

## Decision

### The Direct Seed

- A Launch on an EVM chain is a Direct Seed: one transaction deploys the coin, opens a Uniswap v4 pool against the Quote Asset at the Listing's start price, and places the whole sold supply in it as one single-sided position, the Seed Position.
  There is no curve contract and no migration, and the coin trades in that one pool for life.
- The factory holds every Seed Position and has no code that removes liquidity; the hook refuses every removal, and nobody but our own contracts can add liquidity to the pool.
- The coin is a plain ERC-20: 1 trillion at 18 decimals, with no owner, no mint, no transfer tax and no blocklist.
  A holder may burn their own coins and nobody else's, so a burn lowers the supply (the agent's call, the owner's to overrule; the alternative is a dead address and a supply that never moves).
- A Creator Lock is a share of up to a fifth of the supply held out of the Seed Position in a vesting contract, with its terms fixed at launch (#231, unchanged).
- The First Buy is a swap inside the launch transaction, and it pays the Platform Fee like any buy.
- The launch is always one transaction.
  It is one signature only when the First Buy is paid in the chain's native asset or there is no First Buy.
  A First Buy paid in an ERC-20 is a permit signature and then the transaction where the asset has ERC-2612 (every Stock Token read has it), and an approve first, or Permit2, where it does not.
- The chain's native asset is a Quote Asset on every EVM chain.
  The spike's factory cannot take it and no test covers it, so it is the build's first slice after the launch itself.

### Graduation is the Graduation Hold

- The Graduation Target on EVM is a price: the Listing's start price times the Listing's Graduation multiple, fixed for a coin when it launches.
- A coin graduates when its pool's price has stayed at or above the target for one hour without a break: the Graduation Hold.
  The hook sees every swap in the pool, so it keeps one timestamp per pool: a swap that leaves the price at or above the target starts the hold if none runs, and a swap that leaves it below resets the hold.
  Graduation is recorded once, by the first swap or by a call anyone can make after the hour has passed, and it never reverses.
- The hook reads time only, never `block.number`, which is an L1 estimate on Robinhood Chain and Arbitrum.
- The owner picked one hour in the dialog, over the agent's recommendation of 24 hours.
- Graduation on EVM does three things: it starts the Creator Lock's clock, it is the day Active Days are counted from, and it marks the coin as graduated.
  It no longer switches on any liquidity (ADR 0025) and it takes no fee (ADR 0027).

### The figures are settings

- Every Listing is written so that the whole supply opens worth about $5,000 (the Opening Value) and graduates at 20 times the start price, which takes roughly $20,000 of net buying (owner's pick in the dialog).
- The owner's note on that answer: "keep it flexible because I will change it later for both Solana and EVMS".
  So the start price and the Graduation multiple are fields of a Listing in the Quote Registry (ADR 0028), read by the factory at launch and written into the coin's terms.
  Neither is a constant in the factory or the hook, and a change touches future Launches only.

## Considered Options

- Graduation at the first touch, as #231 had it and the spike built: the simplest hook, but a Creator buys the mark and starts their own lock's clock for about 1% of the target, with a flash loan.
- A hold of 24 hours (the agent's recommendation): faking it means keeping the whole target's worth in the coin for a day, open to every holder selling into it.
  The owner chose one hour: a real Graduation shows sooner, the flash loan is still stopped, and a Creator with capital can still fake it in an hour on a quiet coin, which the owner accepts.
- No Graduation on EVM: the smallest hook, but a Creator Lock would open whether or not the coin ever proved itself, and the board would lose a mark traders know.
- A bonding curve and a migration: refused by the owner on 2026-11-22 (#231, out of scope).

## Consequences

- The hook holds one more timestamp per pool and one public call; the invariant tests must show that Graduation cannot be recorded inside the hour and cannot be undone.
- A coin whose price spikes over the target and falls back within the hour never graduates, and a real Graduation shows an hour after the price first held.
- A Creator Lock cannot be dated at launch, as on Solana: the page says "from Graduation" until the coin has graduated.
- An ERC-20 First Buy is two signatures, so the launch form must say so before the Creator signs; #231's user story 3 becomes "one transaction".
- The spike's figures (a start of about 24.8 NVDA for the whole supply, tick spacing 200, a target 30,000 ticks above the start) are evidence for the shape, not the Listings' values.

## Amended on 2026-11-24 (#244, the review of PR #269): the hold judges the price a transaction leaves

The decision above says "a swap that leaves the price below resets the hold".
Built that way, swap by swap, the independent review of PR #269 showed that anyone with no coins and no capital could reset the hour: inside one PoolManager unlock a contract sells coins it does not own, taking the price under the target, and buys the same coins back, and flash accounting closes its coin delta at zero, so it pays only the round trip's fees.
Five resets at 59-minute intervals kept a coin almost five hours above its target and never graduated, for about 0.07 ETH a day, which would hold Graduation, and with it a Creator Lock's clock, off for good.

So the build judges the hold by the price each transaction leaves, never by a swap inside one (the agent's call, the owner's to overrule):

- A pool's first swap in a transaction (a transient flag per pool, EIP-1153) judges the price standing before it, which is the price the last transaction to swap the pool left, standing since that transaction; the swaps after it in the same transaction are not judged.
- A price left at or above the target starts the hold from the transaction that left it; a price left under it ends the hold; an unbroken hour graduates the coin at the hour's end, recorded by the next transaction to swap the pool or by the public call.
- The public call refuses inside a transaction that has swapped the pool, and otherwise judges the record against the price standing now, so a price left under the target never graduates.

A reset now needs the price left under the target across a transaction boundary, which takes real coins held across it and real exposure, and forcing Graduation (across the target and back in one transaction or one block) stays impossible.
"A swap that leaves the price below" now reads "a transaction that leaves the price below".
