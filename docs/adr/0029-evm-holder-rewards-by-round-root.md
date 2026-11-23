# On EVM chains Holder Rewards are paid by a Round Root that waits 24 hours and that a cold Guard can cancel

Status: accepted by the owner on 2026-11-23 (#235), not built.
It amends #231's "Holder rewards": "On cheap chains the keeper submits every claim ...; on Ethereum holders claim for themselves" and "The root key is the largest trust point of the design".
Solana's Reward Rounds (ADR 0006), its Payout Asset (#43) and Holding Weight (ADR 0022) stand untouched.

On Solana the Reward Engine's wallet holds the harvested tax and pays each holder itself.
On EVM #231 put the tax in a distributor contract and had a key post each round's Merkle root to it.
The contract never lets a round pay more than that coin's tax, but that bound does not stop a stolen key from posting a false root that pays a coin's whole pot, or every Reward Launch's, to a thief; and the key must sit on a server, since a job posts the rounds.
The research added three facts (`docs/evm/research/robinhood-chain.md`, `docs/evm/research/chains.md`).

- A pushed claim costs about 88,600 gas a holder on Robinhood Chain, about $0.003, and a round of 16,384 holders about $50.
- One blocked holder reverts a plain batch of payments in a Stock Token, and no round in a Stock Token can pay while the issuer's pause is on.
- Ethereum's gas was measured at 0.04 to 2 gwei, so a pushed claim there costs cents, and a round of 16,384 holders about $110 to $5,000 across that range; #231's reason for a different claim model on Ethereum does not hold as written.

## Decision

- The Reward Engine computes each Reward Round off-chain from the indexed balances with Holding Weight, exactly as on Solana, and publishes the round's full figures so anyone can recompute a share.
- A Round Root is the round's Merkle root, posted to the Distributor by the round key.
  The Distributor holds each coin's collected tax and never lets a round pay more than that coin's own.
- A Round Root pays nothing for 24 hours after it is posted: the Round Delay.
- The API recomputes every posted Round Root from its own index and raises an alarm on a mismatch.
- The Guard is a cold power, held by the Admin (ADR 0030), that can only cancel a Round Root inside the Round Delay; it can never post one.
- One claim model on every EVM chain, Ethereum included.
  After the Round Delay the Keeper pushes each holder's payment, each on its own, so a holder the asset refuses stays owed without stopping the others; it waits while gas is above a ceiling and while an issuer's pause is on.
  Anyone may claim for a holder at any time after the delay, and the payment always goes to the holder; rounds a holder has not been paid add up.
- The owner picked the 24-hour delay with a cold key that can cancel in the dialog, over a 1-hour delay and over none.

### The Payout Asset on EVM

- On EVM the Reward Tax is collected in the Quote Asset, since the hook takes it on that side of each swap (ADR 0025); on Solana it is collected in the coin.
- A Payout Asset of the Quote Asset therefore needs no Reward Sale: the Tax Vault passes the holders' part to the Distributor as it is.
- A Payout Asset of the coin buys the coin with the holders' part through the Tax Vault's capped public call, the one the Reward Burn uses, and the Distributor pays what was bought.
- Both choices stay, fixed at launch (the agent's call, the owner's to overrule).
- A Stoke Launch has no Reward Round, as on Solana.
- A Reward Round of source `earnings` (a Creator Earnings Destination of the holders) uses the same Distributor and the same Round Root.

## Considered Options

- No delay, as the Solana Reward Engine's wallet pays today: nothing to wait for and no second power, and a stolen round key empties the pots before anyone can react.
- A 1-hour delay: rewards arrive sooner, but an alarm at night must be answered within the hour from a hardware wallet, by one person.
- A delay with no Guard: a false root would be seen and still paid.
- Holders on Ethereum claiming for themselves, as #231 had it: two models to build and explain, for a gas price that does not call for it today; the Keeper's gas ceiling covers the day it does.
- The Quote Asset alone as the Payout Asset on EVM: the smallest build, but a term Solana offers would be missing on EVM.

## Consequences

- Holders are paid a day later than the round's snapshot, on every chain.
- The Guard is useful only if the alarm is: the recomputation runs for every posted root, and the alarm reaches the owner by a route that wakes them.
- A cancelled round is computed and posted again; the Ledger shows both.
- The round key stays on a server and its worst case is bounded twice: by the Distributor, to each coin's own tax, and by the Round Delay and the Guard.
- If the Guard is lost, rounds still pay after the delay, with nobody able to cancel one.
- A Payout Asset of the coin means buys by a public call in capped pieces, so a round's pot fills over several calls; the round pays what the Distributor holds when the root is computed.
- The invariants the Distributor is tested for: a round never pays more than its coin's tax, a holder is never paid twice for one round, nothing is paid inside the Round Delay, and a cancelled root pays nothing.
