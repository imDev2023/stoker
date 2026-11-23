# On EVM chains one hardware wallet is the Admin, three bounded keys sit on a server, the contracts are unaudited and say so, and STOKER stays on Solana

Status: accepted by the owner on 2026-11-23 (#235), not built.
It amends #231's "The privileged keys are four", its "the site's plain statement that the contracts are unaudited" (now with its words and its places) and its "an EVM chain's budget is bridged there and spent".
Solana's key custody (ADR 0004) and the Budget Table (ADR 0019) stand untouched.

On Solana the platform holds no user funds in a program of its own, and four file keypairs run it.
On EVM the contracts are ours and hold every coin's liquidity, every Creator's Credits and every holder's tax.
The owner decided against an independent audit on 2026-11-22, and that decision is not reopened here.
The spike gives the figure that stands beside it: the hook as #231 described it scores 17 of 33 on the v4 hooks safety checklist, High at 18; with the burn, the liquidity and the pot moved to the Tax Vault (ADR 0025) it scores 13, still Medium.
It meets two of the checklist's hard stops (it holds liquidity, and by its own TVL score it may hold over $1M), and the checklist has no tier where an audit is optional (`spike/evm-robinhood-fork/README.md`, "The safety checklist score").

## Decision

### What no key can do

- No proxy, no upgrade path and no pause anywhere in our contracts.
- No key of ours can reach a coin's liquidity, a Creator's Credits, a Creator Lock or a launched coin's terms (ADR 0028 says what an issuer's keys can do to its own asset).
- Losing every key stops new Listings, price writes, tier raises and Reward Rounds; it never stops trading, a Payout Call or a Creator's claim of their lock.

### The Admin

- The Admin is one address of the owner's on a hardware wallet, per chain.
- It holds the cold powers: the Quote Registry's writes (ADR 0028), the Guard (ADR 0029) and replacing a server key.
- A replacement is made in two steps, so a mistyped address cannot hand a role to an address nobody holds; the Admin's own address is replaced the same way.
- The platform's share is paid to the Admin's address: its Credits are paid there by the Payout Call like anyone's.
- The hardware wallet's seed phrase on paper is the backup.
  If the device is lost, the paper restores it; if both are lost, Listings, price writes, the Guard and key replacement stop for good and the platform's unpaid share is lost, while coins keep trading and every other Credit is still paid.
- The owner picked one hardware wallet in the dialog, over a Safe multisig of the owner's devices and over file keypairs on the Mac as on Solana.

### The server keys

- The round key posts a Round Root and can do nothing else; the Distributor, the Round Delay and the Guard bound it (ADR 0029).
- The ladder key raises one coin's Creator Tier and can never lower one (ADR 0027).
- The Keeper has no privilege: it pays gas for Payout Calls, the Tax Vault's calls, Graduation's call and the holders' payments, all of which anyone can make.
- Each is a Worker secret, and each is replaced by the Admin if it is lost or stolen.

### Unaudited, and the site says so

- The statement, with the chain and the link filled in: "Stoker's contracts on [chain] have not been audited by an independent firm. Their source is public and verified: [link]."
- It stands where money moves and never blocks: on the launch form's review step and in the trade panel for a coin on an EVM chain, in the coin page's contract card, on `/fees`, and on a contracts page that lists every address with its verified source.
  There is no pop-up and nothing to tick.
- In place of an audit, as #231 has it: the security standards repository's pre-deployment gate, the v4 hooks safety checklist scored for the hook and the Tax Vault, invariant fuzzing, fork tests against every chain's real PoolManager, verified source on every explorer, and a rehearsal on the chain's testnet before mainnet.
- The owner picked "where money moves, never blocking" in the dialog, over the welcome and the contracts page alone and over a one-time acknowledgement.

### STOKER stays on Solana

- STOKER is never issued on an EVM chain.
- The Platform Net counts every chain, and the Budget Table divides it as before.
- Each EVM chain's Burn budget builds up at the Admin's address there.
  On a schedule the owner sets, the owner converts it and carries it to Solana by whatever route is cheapest at the time, and the Burn spends it there, with a Ledger entry on each side.
- The Flywheel's budget stays on its chain and buys that chain's top Launches.
- The owner picked this in the dialog, over a job that bridges with a server key and over a STOKER on EVM.

## Considered Options

- A Safe multisig of the owner's devices: survives the loss or theft of one device, but every registry write needs two signatures, and whether Safe is officially deployed on Robinhood Chain was not checked.
- File keypairs on the Mac, as on Solana: nothing new to learn, but the weakest home for the powers that decide what every future Launch opens at.
- A one-time acknowledgement before a wallet's first launch or trade: the strongest record that a user was told, and a gate, which the owner has refused everywhere else.
- A job that bridges the Burn budget: a server key that can send platform money across a third party's bridge, on a route nobody has measured.
- STOKER on EVM: a bridge standard, a pool on every chain and new contracts, before the coin has launched on Solana.

## Consequences

- The site's statement is the only notice a user gets that nobody outside has read the contracts, so it must be on every page the decision names before the first Launch on mainnet.
- The score is kept beside the decision: the hook and the Tax Vault are scored again when they are built, and again if the total they hold passes $1M.
- One device and one sheet of paper stand behind every cold power and the platform's EVM revenue; the runbook for EVM go-live names where each is kept.
- The platform's share arrives at a hardware wallet, so anything a job pays on an EVM chain (Volume Rebates, the Flywheel's buys, the Keeper's gas) is paid from a server wallet the owner funds by hand; none of the three was grilled, and each is settled in its own slice.
- Carrying the Burn budget is manual work on the owner's schedule, and a Ledger entry on each side is how anyone checks it; automation waits until a route is proven.
- The Admin's address can differ per chain, and the operator view shows each key, its address and what it can do (#231's user story 47).
