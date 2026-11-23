# On EVM chains a Quote Asset is listed with its issuer's powers stated, and the Quote Registry is written by a cold key

Status: accepted by the owner on 2026-11-23 (#235), not built.
It amends #231's listing rule ("an ERC-20 with no transfer fee and no rebasing balance"), its "No key can reach a coin's liquidity" and its registry key as one of four bounded keys.
Solana's Quote Registry (ADR 0005), its Asset categories (ADR 0010) and the region gate (ADR 0014) stand untouched.

On Solana any Quote Asset with a Raydium GlobalConfig can be paired.
On EVM the factory takes a Quote Asset only when an on-chain Quote Registry lists it, with the start price and the Graduation multiple every Launch on it opens with (ADR 0024).
The research found what such an asset carries (`docs/evm/research/robinhood-chain.md`, `docs/evm/research/chains.md`).

- All 205 Stock Tokens on Robinhood Chain sit behind one beacon, which is also their registry: a blocklist checked on the sender, the recipient and the caller of every transfer, a per-token and a global pause, `adminBurn` from any address, and an upgrade of all 205 at once, each power held by one externally owned account.
  None has an allowlist, so a contract can hold and pay any of them; a fork test showed the pause stopping every transfer out of the PoolManager.
- Every stock token found on the later chains that passes the fee and rebase tests has issuer controls of the same kind (Coinbase's B20, Ondo, Binance's bStocks); xStocks and Dinari rebase and fail.
- Only the issuer prices all 205 Stock Tokens; Chainlink covers 35, and its 24/5 feeds were 41 to 65 hours old on a Sunday.
  Prices taken from the issuer's quotes each market day would mean a job writing up to 205 Listings every trading day, with the registry key on a server.
- The chain's terms forbid its marks in a coin's name, ticker, image and metadata (5.7(d), 5.7(h), 5.11), forbid any short form of its name (5.8(d)), pre-approve factual statements such as "Deployed on Robinhood Chain" (5.6), and require prior written consent to use the marks "in connection with a token issuance" (5.11(e)).
- The issuer restricts Stock Tokens in Switzerland as well as the U.S., the U.K. and Canada.

## Decision

### The listing rule has three clauses

- A Quote Asset is listed on an EVM chain only when it has no transfer fee, has no rebasing balance, and our contracts can hold it and pay it out with nobody's permission (no allowlist).
- An issuer's blocklist, pause, burn or upgrade power does not bar a Listing.
  Each is a Quote Risk Label on the asset and on every coin paired with it.
- #231's custody line becomes "no key of ours": no key of ours can reach a coin's liquidity, a Creator's Credits or a Creator Lock, and on a coin paired with an issuer's asset the issuer's keys can freeze, burn or rewrite that side of the pool, which the site says.
- All 205 Stock Tokens can be listed under the rule.
  The issuers on later chains are judged when their chain's turn comes, issuer by issuer.
- The owner picked "list it, powers stated" in the dialog, over refusing upgradeable assets and over listing only assets with no issuer keys.

### The Quote Registry and its cold key

- The Quote Registry on an EVM chain is a contract.
  A Listing is one Quote Asset's entry: its start price, its Graduation multiple and the cap of its Referrer Fee (ADR 0027).
- Only the Admin writes it, from the owner's hardware wallet (ADR 0030); no server holds the key.
- A start price is rewritten only when the asset has moved more than 20% since its last write (the owner's pick in the dialog; the 20% is the agent's proposal within it).
- The contract itself bounds a routine price write: at most one per Listing per day, and none that moves the start price by more than 25%.
- A deliberate change of the figures (the Opening Value, the Graduation multiple, the Referrer Fee's cap) is a scheduled write: it is posted, announced like a fee change, and takes effect no sooner than 48 hours later (the agent's call, following the owner's "keep it flexible because I will change it later").
- No write ever touches a coin already launched: a coin's terms are copied from its Listing when it launches.
- A new Listing is one write by the Admin.
- The hook reads no price and no oracle; a price enters the system only through a Listing.

### Robinhood Chain's terms: ask first, text only meanwhile

- The owner sends the question of what the site may show to `robinhoodchain@robinhood.com`, the address the terms name, from the owner's own address; an agent drafts it.
- Until an answer comes the site names the chain in plain text only, in full ("Robinhood Chain"), with no logo or badge on a coin's card, on a share image or in the chain picker, and no short form.
  A coin's Permanent Metadata names the chain by its chain id, and the site says it is not affiliated with Robinhood Markets, Inc.
- The site calls the chain's assets Stock Tokens and never "tokenized stocks"; the identifier `tokenized_stock` stays in code.
- On Robinhood Chain the launch form refuses "Robinhood", "Robin Hood", "Robinhood Chain", "Hood Chain" and look-alikes in a coin's name, ticker, description and links, the ticker HOOD, a listed Stock Token's symbol as a ticker, and "Robinhood Token" in a name.
  An image cannot be checked by a rule, so it is handled by a report and a label, as Copy Protection's is.
- The owner picked "ask first, build text-only meanwhile" in the dialog, over not asking and over showing the chain like any other.

### Switzerland

- When the EVM version goes live the disclaimer's list (`EXCLUDED_REGIONS`) gains Switzerland, for the whole site.
  Nothing is withheld or hidden there, and the region gate's table stays empty (ADR 0014 stands).
- The owner picked this in the dialog.

## Considered Options

- Refusing an asset whose issuer can rewrite its code: on Robinhood Chain that refuses all 205 Stock Tokens, since they share one beacon.
- Only assets with no issuer keys: the custody line stays literally true and the reason Robinhood Chain is first is gone.
- A hot registry key with a daily job: dollar starts stay exact, but whoever takes the key moves every future Launch's start price, day after day.
- A price fixed once per asset: no key after listing, but a stock that doubles leaves every new Launch on it opening at twice the intended value.
- Showing the chain's badge like any other chain's: the clearest site, and the one most exposed to a takedown under the terms as written.

## Consequences

- A Launch can open up to about 20% off its nominal Opening Value, which matters little for a coin priced in the asset itself.
- While an issuer's pause is on, every swap of a coin paired with that asset reverts and no payout in it can be made; nothing of ours can change that, and the Quote Risk Label says so.
- The Admin signs every registry write by hand; with 205 possible Listings the first set is the largest job, and a tool that prepares the writes for the hardware wallet is part of the registry's slice.
- The contract's bounds limit what a mistaken or coerced write can do in a day; they do not make the Admin key safe to lose (ADR 0030).
- USDG and ETH were not read as Quote Assets, and most Creators will pick one of them: USDG's issuer powers and the native asset's handling are researched before either is listed.
- A yes from Robinhood adds the badge later; a no is learned before mainnet.
- The chain picker, the board and the share images are designed text-first for this chain, and their baselines change again if the badge arrives.
- The Asset category "tokenized stock" keeps its identifier and gains a second display name on this chain.
