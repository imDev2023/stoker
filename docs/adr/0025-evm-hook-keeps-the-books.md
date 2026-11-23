# On EVM chains the hook keeps the books: a swap records Credits, and calls anyone can make pay, burn and add liquidity

Status: accepted by the owner on 2026-11-23 (#235), not built.
It amends #231's "The hook takes the Platform Fee on every swap and pays each share in that transaction", its "Graduation ... switches on the Reward Liquidity, as on Solana" and its user story 36 ("done by the contract in the trade").
Solana's Creator Forward (ADR 0009), its Reward Burn and its Reward Liquidity (ADR 0006) stand untouched.

The spike built what #231 asked for: a hook that pays the Creator, the referrer and the platform inside the swap, burns inside the swap and adds liquidity inside the swap (`spike/evm-robinhood-fork/README.md`).
It works, and the spike and its review measured what it costs.

- A Stock Token's blocklist makes a payment fail, so a payment in the swap needs a fallback to a claim anyway, and a blocked recipient would otherwise stop every swap of the coin (`docs/evm/research/robinhood-chain.md`, contradicted line 4).
- A payment of the native asset hands control to the recipient in the middle of someone else's trade, and a currency the PoolManager holds none of cannot be paid out mid-swap at all.
- The burn is a coin buy made inside another person's trade.
- Tax that waits for Graduation is taken by whoever crosses it: a wallet that crossed the target and left in one transaction took 58% and 70% of the liquidity waiting on two Stoke Launches (+27.08 and +22.13 NVDA, `test/Review.t.sol`), and a coin that never graduates keeps its share unused for ever.
- The hook scores 17 of 33 on the v4 hooks safety checklist, High at 18, and meets two of its hard stops; with the burn, the liquidity and the pot moved out it scores 13.
  No independent audit stands behind either figure (ADR 0030).

## Decision

### A swap only keeps the books

- Inside a swap the hook takes the fees on the Quote Asset's side and records who is owed what; it calls no recipient, buys nothing and adds no liquidity.
- A Credit is an amount the hook has recorded as owed to an address in a Quote Asset: a Creator's share, a Referrer Fee, the platform's share.
  A Credit belongs to its address from the block of the trade, and no key of ours can move, lower or redirect it.
- A Payout Call pays Credits to their owners, and anyone can make it.
  The Keeper, our server wallet with no privilege, makes Payout Calls on a schedule, so a Creator still has nothing to claim; an owner may also pull their own Credit at any moment.
- A Credit owed to an address the asset refuses stays owed to that address: there is no redirect to another address, no sweep, and it is never revenue (the agent's call, the owner's to overrule).
- A Creator Earnings Destination stays an address fixed at launch, as in #231: the Creator's Credit is recorded to it, whatever it is.
- The owner picked "books only" in the dialog, over paying in the swap with a failure credited.

### The Tax Vault

- The hook holds nothing.
  A coin's Reward Tax, its Stoke Tax and its Opening Fee (ADR 0026) go to the Tax Vault, a contract of ours beside the hook, in the Quote Asset.
- The Tax Vault does the Reward Burn's buy and the liquidity additions, each by a call anyone can make and the Keeper makes, in capped pieces, and passes the holders' part to the Distributor (ADR 0029).
- The Reward Burn's buy spends at most 0.5% of the Quote Asset the coin's pool holds in one piece, mirroring #43's bound on a Reward Sale (the agent's call, the owner's to overrule), and burns exactly what it bought.
- Solana's steps are kept: a Reward Launch's burn and liquidity shares are each none, a tenth, a quarter or half, at most half together, and a Stoke Launch sends its whole tax to liquidity.
  The factory enforces the steps, which the spike did not.

### Support Liquidity, from the first trade

- On EVM the Reward Liquidity, the Stoke Tax and the Opening Fee all become Support Liquidity: Quote Asset alone, placed in a locked position just below the current price.
  No coin is bought, so nobody's trade is moved and there is nothing for a crossing wallet to take.
- It is added from the first trade, on every coin, graduated or not; Graduation switches nothing on.
- The Tax Vault holds every such position and has no code that removes liquidity.
- The owner picked this in the dialog, over both-sided additions in capped pieces and over waiting for Graduation.
- It is unproven: no test places a one-sided position under the price through the hook yet, so a fork test in the first tax slice comes before anything is built on it.

### Donations

- The spike's hook let anyone donate to a pool, and a 50 NVDA donation made the hook's next liquidity addition revert with `CurrencyNotSettled()`, since a position's delta includes accrued fees.
  The build refuses donations to our pools, or handles the sign, and proves it with a test.

### Trading outside the coin's pool is accepted and shown

- Only swaps in the coin's own pool carry the Platform Fee and the tax.
  A transfer from wallet to wallet is never taxed, and a second pool that someone opens for the coin pays nothing to the holders, the Creator or the platform.
- The coin stays plain; nothing stops a second pool.
  The coin's page shows what share of the coin's trading happens outside its own pool, from the indexed trades, and the launch form and `/fees` say the rule in words.
- The owner picked "accept it and show it" in the dialog, over a tax inside the coin and over a coin that refuses other pools.

## Considered Options

- Pay in the swap and credit a failure, as the spike built: most shares arrive in the trade's own transaction, the strongest thing to say against Solana's off-chain forward, but every trade costs more gas and a stranger's code runs in the middle of other people's trades.
- Pay ERC-20 shares in the swap and the rest by call: two payment paths to build, test and explain.
- Both-sided liquidity in capped pieces from the first trade (the review's direction): depth on both sides, but still a buy made beside other people's trades, and a cap that must be right.
- Waiting for Graduation and then releasing in capped pieces: a coin that never graduates never gets its liquidity, which for a Stoke Launch is the whole tax.
- A tax inside the coin on every transfer: nothing is avoided, but routers and aggregators mishandle such coins, Uniswap v4 does not support them cleanly, and the coin's own contract grows logic nobody audits.

## Consequences

- "Paid in the trade itself" is no longer true and the site must not say it.
  What is true: the share is the Creator's on the chain from the trade's own block, where no key of ours can touch it, and a call anyone can make pays it.
- Moving the burn, the liquidity and the pot into the Tax Vault lowers the hook's score from 17 to 13; it does not lower the system's risk, since the same funds sit in a second contract of ours.
  The Tax Vault is tested and scored as the hook is.
- Payouts, burns and liquidity additions depend on someone making the calls.
  The Keeper does; if it stops, nothing is lost and anyone can make them, but they wait.
- Support Liquidity is depth on the buy side only; it is not a price floor and the site never calls it one.
- The cap on the burn's buy is measured against the Quote Asset in the pool, which is nothing at launch; the first tax slice checks that a burn is never starved by it and may set another base.
- The three Destination contracts of #231 (holders, burn, liquidity) were not grilled; they are slices of their own and may reuse the Tax Vault's and the Distributor's calls.
