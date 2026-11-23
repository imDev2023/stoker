# On EVM chains a Launch opens with an Opening Fee on buys, all of it added to the coin's own liquidity

Status: accepted by the owner on 2026-11-23 (#235), not built.
It sets the owner's rule of 2026-10-26 (First Buy, vesting and labels, never a tax) aside for the EVM chain family alone.
Solana keeps the rule: LaunchLab has one platform-wide fee and no sniper tax, and Bundle Radar there labels and stops nothing.
It amends #231's "Out of Scope: an anti-snipe fee schedule".

With a Direct Seed (ADR 0024) there is no curve, so the whole sold supply is on offer at the start price in the launch's own block.
A bot watching the factory buys before anyone has seen the coin's page; the Creator's First Buy, made inside the launch transaction, protects the Creator alone.
The rivals on the same launch shape open every coin with a buy fee that falls from 99% to the normal fee over 20 seconds: Clanker's v5 coins on Base and Stockereum on Ethereum (`docs/evm/research/chains.md`, read on 2026-11-22 from their own docs).
Such a fee works as an auction: a bot buys when the fee has fallen to what its head start is worth, and pays the coin for it.
A fee like this cannot be added to a coin after it has launched.

## Decision

- Every Launch on an EVM chain has an Opening Fee: an extra fee on buys in its first 20 seconds.
  At the launch's own second the hook's fees together take 99% of a buy; the Opening Fee is the part of that above the Launch's standing fees (ADR 0027), and it falls in a straight line to nothing at 20 seconds.
  The fees of a buy never add up to more than 99% of it.
- All of the Opening Fee goes to the Tax Vault and becomes Support Liquidity in the coin's own pool (ADR 0025).
  Neither the platform nor the Creator earns from it, and no share of it is a Credit.
- The Creator's First Buy is exempt: it is the swap the factory makes inside the launch transaction, and no other buy can be.
- Sells never pay it.
- The start figure and the duration are terms written into the Launch from the platform's settings when it launches, read by the hook from the Launch's own terms and by time alone (the agent's call, the owner's to overrule); a change of the settings touches future Launches only.
- The owner picked this in the dialog, over keeping the October rule on every chain and over leaving it out of version 1.
- On EVM the Snipe Window is the time the Opening Fee runs, and a Sniper is a wallet other than the Creator that bought inside it (the agent's call).
  Bundle Radar still only labels; the Opening Fee is the one exception to "nothing is refused or taxed".

## Considered Options

- The rule of 2026-10-26 on every chain: the smallest hook, and our Launches the cheapest on the chain for bots already tuned to Clanker's fee.
- Not in version 1, decided from data: coins launched before then would never get it, and the first hundred Launches would be the measurement.
- The Opening Fee paid through the Platform Fee's split: the Creator would earn half of what snipers pay, which pays a Creator to snipe their own coin with a second wallet.
- A commit-and-reveal or an allowlist at launch: a gate, which the owner has refused everywhere else.

## Consequences

- One more path in the unaudited hook (ADR 0030), reading time and the Launch's own terms.
  A fee that never fell would stop a coin from trading, so the invariant tests must show the fee at the launch's second, at every second to the twentieth and after it, for exact-in and exact-out buys.
- A quote in a Launch's first 20 seconds must carry the Opening Fee at the second the trade lands, so `GET /v1/platform`, the trade panel and the Universal Router's price floor all read it; a buy quoted a second early pays less than quoted, never more.
- The site says what it is and who gets it wherever a buy can be made in those seconds, and `/fees` is still the only page with the figure.
- A real person who buys in the first 20 seconds pays it too; the trade panel shows the fee falling so they can wait.
- Because the Opening Fee is Support Liquidity, it rests on ADR 0025's unproven one-sided addition.
