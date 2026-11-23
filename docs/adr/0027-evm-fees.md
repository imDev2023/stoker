# On EVM chains the Platform Fee is 1.00% for life, a Referrer Fee comes on top, and there is no Graduation Fee

Status: accepted by the owner on 2026-11-23 (#235), not built.
It amends #231's "The rates mirror Solana's", its "a referrer's to the referrer" and its "Graduation ... takes the Graduation Fee".
Solana's fee model (ADR 0009), its Creator Ladder (ADR 0020), its referral share (#21) and its Graduation Fee (ADR 0015) stand untouched.

On Solana a trader pays 1.00% before Graduation and 1.25% after, because the coin moves to a Raydium pool with a fee of its own.
On EVM the coin stays in one pool for life (ADR 0024), and the hook's fee is the only fee we set.
Three findings shaped the rest.

- Uniswap's own protocol fee is already charged on Robinhood Chain: its controller is `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`, and 17 of the 20 deepest Stock Token pools paid 0.0052% to 0.1% at block 121,389,325 (`docs/evm/research/robinhood-chain.md`); the controller is set on five of the six later chains (`docs/evm/research/chains.md`).
- The spike let the launcher choose the Creator's share up to 90%, and paid a tenth of the Platform Fee to whatever address a trade named, so any trader or bot could name itself (`spike/evm-robinhood-fork/README.md`, "In the spike's code, for the build not to copy").
- The nearest rival on Robinhood Chain, o1, charges 1% of the paired asset per swap (`docs/evm/research/chains.md`).

## Decision

- The Platform Fee on an EVM chain is 1.00% of the Quote Asset's side of every swap in the coin's own pool, buys and sells, from the first block and for the coin's life.
  It does not change at Graduation.
  The pool's own LP fee is zero.
- The rate is a term of the Launch, written at launch from the platform's settings and read from the chain by `GET /v1/platform`; no page but `/fees` shows a figure (owner, 2026-10-30).
- The Creator's share of the Platform Fee follows the Creator Ladder: 50%, 60% after 15 Active Days, 70% after 30.
  The factory writes the three shares into the Launch from the platform's settings; they are never the launcher's to choose.
  The contract pays the first tier with no key involved, and the ladder key may raise one coin's Creator Tier to the second or the top and can never lower it, which is the whole of its power.
  Active Days are counted by the API from the indexed trades.
- An Active Day on EVM is a UTC day on which a graduated coin's pool traded at least 1% of the Quote Asset it took to carry the coin from its start price to its Graduation Target, an amount fixed at launch by the Seed Position's own arithmetic (the agent's call, the owner's to overrule: the Graduation Target is a price on EVM, so Solana's "1% of the Graduation Target" has no amount to read).
- A Referrer Fee is a fee a front-end or a bot adds on top of a trade it brings, up to the cap its Listing holds, recorded as a Credit to the address the trade names (ADR 0025).
  The trader of that front-end pays it, naming yourself gains nothing, and the Platform Net is untouched.
  Any share of the platform's own revenue for referrers or integrators stays a row of the Budget Table (ADR 0019).
- There is no Graduation Fee on an EVM chain, and `/fees` says so; Solana keeps its own.
- Uniswap's protocol fee is not ours and is not zero.
  `/fees` shows it per chain as Uniswap's, read from the chain, and every quote of what reaches a wallet includes it.
- The owner picked three of these in the dialog: 1.00% for life, the Referrer Fee on top and capped, and no Graduation Fee.
  The Creator's share by the ladder is #231's own, and the protocol fee follows from the evidence with no choice to make.

## Considered Options

- 1.00%, then 1.25% after Graduation: Solana's two figures on every chain, but the hook would switch rate at Graduation, a coin would get dearer to trade the moment it succeeds, and nothing on EVM explains the extra quarter point.
- A fee the Creator picks at launch (1%, 2% or 3%), as Stockereum and Clanker have: a new feature Solana does not have, on top of a Reward Launch's tax.
- A referrer's share out of the platform's part, open to anyone, as the spike and o1 have: traders pay no more through a partner, but every bot names itself and the platform's part of that flow is smaller for good, outside the Budget Table.
- No referrer in the contracts: the simplest hook, but nobody is paid in the trade and the Budget Table's rows are 0 today.
- A Graduation Fee withheld in the hook: parity with Solana, at the price of one more amount remembered per coin and one more path that diverts a Creator's Credits, in a hook nobody audits, for a few dollars a coin.
- A fee at launch in the native asset: a charge on every Creator's wallet up front, which ADR 0015 avoided on purpose.

## Consequences

- One figure to explain on EVM, and the hook needs no fee switch.
- The first caps of the Referrer Fee are the owner's to set when a Listing is written; Solana's are 1% on SOL and 0 on most other assets (#21).
- A Creator's shares are written at launch, so a later version of the Creator Ladder reaches new Launches only; on Solana a version applies to what is collected while it is in force.
- The site's fee copy needs a second set of words for the EVM chain family; the figures all come from the chain.
- The quote must read three things from the chain at the moment of a trade: the Launch's own terms, the Opening Fee's second (ADR 0026) and Uniswap's protocol fee.
