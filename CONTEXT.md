# Stoker

A launchpad where anyone launches a coin paired with a Quote Asset of their choosing and a Creator earns from every trade on it, with every payment public.
On Solana, where it was built first, any Quote Asset can be paired with no gatekeeper choosing which are allowed, and half of what the platform collects on a coin is forwarded to its Creator by us on a public Ledger, where what is owed can be checked against the indexed trades.
On EVM chains (PRD #231, ADR 0024 to 0030, not built) the same Launches run on contracts of our own, which record the Creator's share to them in the trade's own block.

The entries below say what each term means on Solana; "On EVM chains" holds the terms that exist only there and what each of the others means there instead.

## Language

### Launching

**Launch**:
A new coin created on our platform together with its bonding curve, from creation until it graduates or dies.
_Avoid_: Token, pool, project

**Creator**:
The wallet that launched a coin and is entitled to its Creator Earnings.
_Avoid_: Dev, deployer, owner

**Graduation**:
The moment a Launch's curve sells out and its liquidity moves to a Raydium CPMM pool, after which it trades like any other coin.
_Avoid_: Migration (that is Raydium's mechanism), bonding, completion

**Graduation Target**:
The amount of Quote Asset a Launch's curve must raise to graduate, fixed once at launch as the equivalent of a set amount of SOL.
_Avoid_: Bonding target, market cap target, fund raising

**Launch Shape**:
What every new Launch's coin and curve are, pinned on-chain by our curve rules: a supply of 1 trillion coins at 6 decimals, 793.1 billion of them sold on the curve, the rest moving to the pool at Graduation, with no vesting (since #166; coins launched before it keep the 1 billion shape, 793.1 million sold).
A coin with a Creator Lock sells that many fewer coins on the curve; its supply and the pool's share are the same.
_Avoid_: Tokenomics, curve settings

**Creator Lock**:
Coins a Launch sets aside for its Creator, taken out of what the curve sells: the chain holds them from launch, nothing unlocks until the cliff has passed after Graduation, and the Creator's own wallet claims what has unlocked (ADR 0023, #186).
At most a fifth of the supply, lasting at least seven days after Graduation, all of it the Creator's and fixed at launch.
_Avoid_: Vesting (LaunchLab's word for the mechanism), team allocation, dev supply, locked liquidity (that is the pool's, behind a Fee Key)

**Quote Asset**:
The existing token a Launch is priced and traded against, such as SOL, a community token or a tokenized stock.
_Avoid_: Pair token, base, collateral

**Swap** (the section):
Jupiter's swap widget on `/swap` (owner, 2026-10-30), any Solana token for any other on mainnet through Jupiter, with a referral fee to the platform; Stoker coins trade on their own pages, never here.
_Avoid_: trade section (parked, #123), exchange

**Copy Protection**:
The window after a Launch, seven days unless the operator sets another, during which nobody else may launch a coin here, on any chain, with its name, ticker or image; afterwards anyone may, and a coin that does carries a label naming the original.
_Avoid_: Anti-vamp (the feature's working name), ticker registry, blacklist

**Trust figures**:
What a buyer checks before buying, shown in the coin page's "Before you buy" card: what the Creator holds, their First Buy and their record here, Bundle Radar's snipers, and what the ten largest wallets hold.
Every figure is computed from the indexed trades and the chain so anyone can recompute it (ADR 0013); a label informs rather than blocks.
_Avoid_: Audit, safety score, rug check

**Snipe Window**:
A launch's own slot and the few after it (five, about two seconds, unless the operator sets another): a buy inside it was placed by a bot watching the program, not by someone who read the page.
_Avoid_: Block 0, launch block

**Sniper**:
A wallet other than the Creator that bought in the Snipe Window.
A bundle is several snipers that landed beside the launch or paid the same amount, which is how one bot's wallets buy.
_Avoid_: Bot (the wallet, not the program), insider

**Bundle Radar**:
The part of the trust figures that lists the snipers, what they bought in the Snipe Window and what they hold by their trades since, and marks the bundle among them.
Labels only: nothing is refused or taxed, since LaunchLab has one platform-wide fee and no sniper tax.
_Avoid_: Anti-sniper (nothing is stopped), bundle checker

**Chart Mark**:
A circle on a candle of a coin's chart with a picture in it (#160): a Trade Mark for one wallet's trades on one side in that candle, its ring the up colour for a buy and the down colour for a sell, or a Mention for a post on X, its ring the accent.
By default only the key wallets' trades are marked: the visitor's own, the Creator's, the Snipers', the ten largest holders' by their trades and the Notable Wallets'; every trade on request.
_Avoid_: Bubble, dot, annotation

**Mention**:
A post on X that named a coin by its mint address, its ticker as a cashtag or its page's link, found by the mentions job while the coin trades (ADR 0018) and stored once with the market cap the coin stood at when it was posted.
_Avoid_: Tweet (X's old word), social signal, buzz

**Notable Wallet**:
A wallet the operator has named after its owner's X account, whose Trade Marks show that account's handle and picture; the only way a trade carries an X name until sign-in links wallets to X (#159).
_Avoid_: KOL wallet, influencer, whale

**Quote Risk Label**:
A fact about a Quote Asset that a Creator or trader should know before using it, such as an unverified issuer, an issuer's power to freeze or move tokens, a transfer fee, or no reliable price.
Labels inform rather than block, and are shown as further information (the asset's page, the launch form, a coin's page), never beside the asset's name (owner, 2026-10-10).
_Avoid_: Warning, verification status, badge

**Asset category**:
What kind of asset a Quote Asset is, one of ten (SOL, stablecoin, tokenized stock, real-world asset, wrapped, DeFi, leveraged, collectible, meme, community), read from its mint's address and authorities and from Jupiter's token tags, never from its name (ADR 0010).
The board filters by it and the assets page groups by it; a tokenized stock also carries its issuer.
_Avoid_: Type, sector, class

**Market behind an asset**:
The market TradingView charts for a Quote Asset: the stock or fund a tokenized stock tracks, the coin a wrapped coin wraps, or the coin's own market (#124).
Known from the issuer's ticker or the mint address, never from a name, and absent for an asset with no public market (a private company's token, a collectible); the asset's page charts it.
_Avoid_: Underlying (on its own), real price, reference price

**First Buy**:
The Creator's own buy of their coin, made inside the launch transaction right after the curve is created, so no other trade can come before it.
_Avoid_: Dev buy, initial buy, snipe

**Airdrop**:
Part of a Creator's First Buy given to a list of wallets right after launch, paid from the Creator's wallet in as many transactions as the list needs.
_Avoid_: Holder Reward (paid from Reward Tax), distribution

**Asset Pairing**:
Letting a Creator choose any supported Quote Asset instead of only SOL.
_Avoid_: Pair with anything, multi-quote

### Fees

**Platform Fee**:
Our share of every trade on a Launch, collected by the platform.
On the curve LaunchLab pays it into one vault per Quote Asset; after Graduation it is the CPMM pool's creator fee, since the platform is every graduated pool's creator, less the share of it Raydium keeps at collection (the config's `creator_fee_share_rate`, 5% on mainnet).
Half of it is the Creator's, more of a graduated coin's by its Creator Tier, paid on as the Creator Forward (ADR 0009, ADR 0020).
_Avoid_: Protocol fee (that is Raydium's cut)

**Fee Key**:
The NFT Raydium mints when liquidity is locked in a pool, which entitles its holder to the trading fees that locked position earns; the platform holds every one.
A pool has the one from its Graduation and one more for every liquidity addition a Creator's earnings or the Burn's or the Flywheel's budget paid for (ADR 0011, #184).
_Avoid_: LP NFT, position NFT

**Creator Fee**:
LaunchLab's on-chain creator share of curve trades, set per platform: 0 on ours (ADR 0009), so nothing ever collects in a Creator's LaunchLab vault and there is nothing to claim.
The term stays because the chain, the fee-change flow and the announcements name it.
_Avoid_: using it for what a Creator earns (that is Creator Earnings)

**Creator Forward**:
What the platform pays a Creator out of what it has collected on their Launch's trades, straight to the Creator's wallet in the Quote Asset: half of each curve trade's Platform Fee, and of each pool creator fee collection after Graduation the share of the coin's Creator Tier, half on the first (ADR 0009, ADR 0020).
Also one such payment.
Only the coins whose Creator Earnings Destination is the wallet are paid this way.
_Avoid_: Creator Fee (that is LaunchLab's on-chain term), payout, rebate, revenue share, claim

**Creator Earnings**:
What a Creator's Launches have earned them, their share of what the platform collected on those coins' trades: earned, kept as Graduation Fees, sent as Creator Forwards or applied by a coin's Earnings Rule, and still to come, per Quote Asset and per Launch on their own page (`/creator`), which only the connected wallet sees and is offered once it has launched a coin; there is no public creator page (owner, 2026-10-08).
_Avoid_: Creator Fee, claimable, rewards (those are for holders)

**Creator Earnings Destination**:
Where a coin's Creator Earnings go, chosen on the launch form and fixed for the coin's life: the Creator's wallet (Creator Forwards), the coin's holders (Holder Dividends), a buyback that burns the coin, or a buyback that adds locked liquidity to its pool (ADR 0011).
_Avoid_: Vault, template, fee mode

**Earnings Rule**:
A Creator Earnings Destination other than the wallet: holders, burn or liquidity.
A coin with one has a pot of its own in its Quote Asset (what was collected for its Creator on it, less its Graduation Fee, less what the rule has applied), and the Creator Forward job applies the rule to it on its schedule, every action on the Ledger.
_Avoid_: Vault, strategy, smart contract (no program enforces it)

**Holder Dividend**:
What a coin's holders are paid out of its Creator's earnings under the holders rule, by their Weighted Holding in the Quote Asset, through a Reward Round of source `earnings`.
_Avoid_: Holder Rewards (those are paid from Reward Tax), airdrop, staking reward

**Creator Buyback**:
One run of a coin's burn or liquidity rule: a single transaction that buys the coin in its own market with the pot and burns what it bought, or pairs it with the Quote Asset and adds it to the pool as liquidity locked for good.
_Avoid_: Burn (on its own; that is the platform's, of the Platform Token), Flywheel

**Creator Ladder**:
The three Creator Tiers a coin climbs and the share of its pool creator fee collections each gives its Creator: half on the first tier, 60% on the second after 15 Active Days, 70% on the top after 30 (ADR 0020, owner 2026-11-10).
It is versioned: a version is announced ahead like a fee change, and its shares apply only to what is collected while it is in force.
_Avoid_: Loyalty program, levels, creator rewards (rewards are for holders)

**Creator Tier**:
A coin's place on the Creator Ladder: the first from its launch, on the curve and after Graduation, then the second and the top.
It belongs to the coin, never to the Creator across their coins; it is recorded once by the Fee Collector when the coin's Active Days reach it, applies to the pool fees collected from then on, and never falls.
_Avoid_: Level, rank, badge, a Creator's tier

**Active Day**:
A UTC day on which a graduated coin's pool traded at least 1% of the coin's own Graduation Target, in its Quote Asset, by the indexed trades.
Active Days need not follow one another and their count only grows; it is what a coin climbs the Creator Ladder by.
_Avoid_: Trading day, streak (a gap does not reset the count), staying power (the idea it measures)

**Graduation Fee**:
What the platform charges when a coin graduates, a set worth in SOL (0.015 SOL on mainnet, `GRADUATION_FEE_LAMPORTS`), withheld from the Creator's earnings on that coin in the coin's Quote Asset at the Quote Registry's price, from their next Creator Forwards until paid, never out of their wallet and never from the holders' Reward Tax; each withholding is a `graduation_fee` entry on the Ledger against the graduation (ADR 0015).
_Avoid_: Migration fee, listing fee, graduation tax

**Fees page**:
The page at `/fees`, the one place on the site that shows a fee figure (owner, 2026-10-30): every fee a visitor can pay, who pays it, when, in what asset and who receives it, each figure read from `GET /v1/platform` as the page opens; every other page says what a fee is for and links there.
_Avoid_: pricing, fee schedule, tariff

### Revenue

**Operations Wallet**:
The one hot wallet that signs every day-to-day job and receives all platform revenue first (ADR 0004).
_Avoid_: Fee wallet, hot wallet (on its own)

**Treasury**:
The cold wallet or multisig vault that platform revenue is swept to; no server ever holds its key.
_Avoid_: Vault (LaunchLab's fee vaults are something else), cold wallet (on its own)

**Sweep**:
Moving revenue from the Operations Wallet to the Treasury, so the hot wallet never holds much.
_Avoid_: Withdrawal, transfer (on its own)

**Fee Collector**:
The scheduled job that claims every Platform Fee and Fee Key into the Operations Wallet and sweeps it to the Treasury, less what is owed to Creators.
_Avoid_: Fee cron, claimer

**Ledger**:
The append-only public record of every movement of platform revenue, each tied to its transaction signature; Creator Forwards, Holder Dividends, Creator Buybacks, Burns, Flywheel buys and what permanent metadata costs are on it too.
_Avoid_: History, log, audit trail

**Permanent Metadata**:
A coin's image and metadata JSON on Arweave, posted through ArDrive Turbo, where the coin's on-chain metadata URI points and nobody can change them.
_Avoid_: IPFS, pinned metadata, hosted metadata

**Metadata Upload**:
The scheduled job that posts every launched coin's Permanent Metadata to Arweave, buying Turbo credits with SOL from the Operations Wallet when needed.
_Avoid_: Arweave cron, uploader

### Rewards

**Reward Launch**:
A Launch whose coin charges a Reward Tax on every transfer, collected for its holders.
_Avoid_: Tax token, reward token, reflection token

**Reward Tax**:
The percentage withheld from every transfer of a Reward Launch's coin, in that same coin.
_Avoid_: Transfer fee (the chain's mechanism), tax

**Holder Reward**:
A holder's share of collected Reward Tax, by their Weighted Holding at the round's snapshot, paid in the Launch's Payout Asset.
_Avoid_: Dividend, yield, airdrop, reflection

**Payout Asset**:
What a Reward Launch pays its Holder Rewards in, fixed at launch and never changed: the coin itself, never sold, or the paired Quote Asset, bought with the tax through Reward Sales.
_Avoid_: Reward token, reflection asset, payout mode

**Reward Sale**:
One bounded sale of collected Reward Tax into the coin's own market for the Quote Asset, made by the Reward Engine on its schedule for a Launch whose Payout Asset is the Quote Asset, and public down to its transaction.
_Avoid_: Dump, conversion, swap (on its own)

**Reward Burn**:
The share of every harvested Reward Tax that a Reward Launch burns instead of paying out, chosen by its Creator at launch from the offered steps (none, a tenth, a quarter or half) and never changed (#183).
It is burned in the transaction that withdraws the tax, before anything is sold or paid, and recorded on the Ledger; it is the holders' tax, never revenue, and has nothing to do with the Burn of the Platform Token.
_Avoid_: Tax burn, auto-burn, deflation fee, Burn (on its own: that is the Platform Token's)

**Reward Liquidity**:
The share of every harvested Reward Tax that a Reward Launch adds to its own pool as locked liquidity instead of paying out, chosen by its Creator at launch from the same steps as the Reward Burn and never changed; the two together are half of every harvest at most, so holders keep at least half (#214).
It is kept apart in the transaction that withdraws the tax, waits until the coin has graduated and is worth a locked position, and is then added, part sold for the Quote Asset half, with the operations wallet holding the Fee Key; every addition is on the Ledger, and it is the holders' tax, never revenue.
_Avoid_: Auto-liquidity, LP tax, liquidity fee, protocol-owned liquidity (that is the Burn's and the Flywheel's, #184)

**Stoke Launch**:
A Launch whose coin charges a Stoke Tax on every transfer, all of it added to the coin's own pool as locked liquidity; its holders are paid nothing from it, so it has no Reward Round, no Payout Asset, no Reward Burn and no Reward Liquidity share (#215).
The third launch type beside a standard coin and a Reward Launch, fixed at launch and never changed.
The name is display only and may change: in code, the contract, the database and the Ledger it is a Liquidity Launch (`liquidity`).
_Avoid_: Liquidity Launch (in copy; it is the identifier), LP launch, auto-LP coin, Reward Launch (it pays no rewards)

**Stoke Tax**:
The percentage withheld from every transfer of a Stoke Launch's coin, in that same coin, at the rates a Reward Tax may have; collected by the Reward Engine, kept until the coin has graduated and added to its pool as the Reward Liquidity is, with the operations wallet holding the Fee Key.
It is the pool's, never the holders' and never revenue.
_Avoid_: Reward Tax (that pays holders), liquidity tax (in copy; `liquidityTax` is the identifier), LP tax, transfer fee (the chain's mechanism)

**Reward Round**:
One published cycle of paying a coin's holders, with its snapshot, rules version and payout transactions public: collected Reward Tax paid as Holder Rewards, or a coin's pot paid as Holder Dividends when its Creator's earnings go to its holders (ADR 0011).
A round has one source, tax or earnings, and the two never share a pot.
_Avoid_: Distribution, epoch, cycle

**Holding Weight**:
What a coin counts for in a Reward Round by how long its wallet has kept it: once when new, then the weight of the rules' step its Holding Lot has reached (ADR 0022, owner 2026-11-12).
The steps are part of the Reward Round rules, announced ahead like any change of them; holders see the rule under the name Diamond Hands.
_Avoid_: Loyalty program, multiplier tier, level, boost, staking (nothing is locked)

**Holding Lot**:
An amount of a coin a wallet was first seen holding at one Holding Check, with that check's time, which is where the coins' age runs from.
A sell takes a wallet's newest lots first, coins that arrive from another wallet are a new lot, and the treasury's lots never weigh more than once.
_Avoid_: Stake, deposit, tranche, vesting

**Holding Check**:
The Reward Engine's once-a-day reading of every wallet's balance of a coin that can have a Reward Round, which brings the coin's Holding Lots in step with what each wallet holds.
What happens between two checks is not seen.
_Avoid_: Snapshot (that is a Reward Round's own reading), scan, sync

**Weighted Holding**:
A wallet's balance at a Reward Round's snapshot with each coin counted at its Holding Weight; a round's pot is split in proportion to it.
_Avoid_: Score, points, shares

**Region gate**:
The table that removes a feature from the visitors of one country once someone has asked for its removal there (owner, 2026-10-29: nothing is withheld upfront, every feature works everywhere and the disclosure does its job): the API reads the visitor's country from Cloudflare and answers which features are withheld there; the web hides a withheld feature. The table starts empty (ADR 0014).
_Avoid_: Geoblock, ban

### On EVM chains

Decided on 2026-11-23 (#235, ADR 0024 to 0030) and not built.
A term with no entry here means on an EVM chain what it means above.

**Chain family**:
Solana, or the EVM chains taken together; a term can mean one thing in each.
_Avoid_: Ecosystem, network type, VM

**EVM chain**:
A chain of the EVM chain family that Stoker runs on, each with its own contracts, Quote Registry and Admin: Robinhood Chain first.
_Avoid_: L2, network (on its own), EVM (as a noun for one chain)

**Direct Seed**:
The Launch Shape on an EVM chain: one transaction creates the coin, opens its pool against the Quote Asset at the Listing's start price and places the whole sold supply in it, with no curve and no migration (ADR 0024).
_Avoid_: Fair launch, single-sided launch, bonding curve, stealth launch

**Seed Position**:
The one locked position that holds a Direct Seed's sold supply in the coin's pool, which nothing can remove.
_Avoid_: LP, locked liquidity (on its own), the curve

**Opening Value**:
What a coin's whole supply is worth at its start price, a setting of its Quote Asset's Listing.
_Avoid_: Starting market cap, initial FDV, floor

**Graduation Hold**:
The hour a coin's price must stay at or above its Graduation Target, without a break, before the coin graduates on an EVM chain.
_Avoid_: Bonding, TWAP, cooldown

**Listing**:
One Quote Asset's entry in an EVM chain's Quote Registry: the start price, the Graduation multiple and the Referrer Fee's cap every new Launch on it takes (ADR 0028).
_Avoid_: Whitelist entry, pair config, quote config

**Credit**:
An amount in a Quote Asset that the contract has recorded as owed to an address by a trade: a Creator's share, a Referrer Fee or the platform's share (ADR 0025).
It belongs to that address from the trade's own block, and nobody can move it elsewhere.
_Avoid_: Claimable, balance, accrued fee, Creator Forward (that is Solana's payment by us)

**Payout Call**:
The call anyone can make that pays Credits to the addresses they belong to; an owner may also pull their own.
_Avoid_: Claim (nobody has to), withdrawal, harvest

**Keeper**:
Our server wallet on an EVM chain that makes the calls anyone can make, on a schedule, and has no power of its own.
_Avoid_: Bot, operator, relayer, Operations Wallet (that is Solana's, and holds revenue)

**Tax Vault**:
The contract that receives a coin's Reward Tax, Stoke Tax and Opening Fee on an EVM chain and turns them into the Reward Burn, Support Liquidity and the holders' part.
_Avoid_: Treasury, pot (that is a coin's own figure), fee vault

**Support Liquidity**:
Quote Asset alone, added to a coin's own pool in a locked position just below the lower of the current price and the coin's Reference Price, with no coin bought (ADR 0025, #271).
On an EVM chain it is what the Reward Liquidity, the Stoke Tax and the Opening Fee become, from a coin's first trade.
_Avoid_: Floor, price floor, buy wall, Protocol-Owned Liquidity (that is the Burn's and the Flywheel's)

**Reference Price**:
A taxed coin's price as the Tax Vault trusts it on an EVM chain: it follows the pool's price by how long each price has stood, slowly up and fast down, so the vault never places Support Liquidity or buys at a price only just reached (#271).
_Avoid_: Oracle, TWAP (it is neither an average nor an outside feed), floor, fair price

**Opening Fee**:
The extra fee on buys in a Launch's first seconds on an EVM chain, falling to nothing, all of it becoming the coin's Support Liquidity; the Creator's First Buy never pays it (ADR 0026).
_Avoid_: Sniper tax, anti-snipe fee, launch tax, Platform Fee (nobody earns it)

**Referrer Fee**:
A fee the front-end that brought a trade adds on top of it on an EVM chain, capped by the Listing and recorded as a Credit to the address the trade names (ADR 0027).
_Avoid_: Referral share (Solana's mechanism, #21), kickback, affiliate fee, integrator share (that is a Budget Table row)

**Protocol fee** (on an EVM chain):
Uniswap's own fee on a pool, set by Uniswap, never ours; a quote includes it and `/fees` shows it as Uniswap's.
_Avoid_: Platform Fee, pool fee, LP fee

**Distributor**:
The contract that holds each coin's collected tax for its holders on an EVM chain and pays a Reward Round from it, never more than that coin's own (ADR 0029).
_Avoid_: Airdrop contract, Merkle drop, rewards pool

**Round Root**:
The one value posted to the Distributor that fixes every holder's share of a Reward Round, computed from the round's published figures.
_Avoid_: Snapshot (that is the round's reading), proof, epoch root

**Round Delay**:
The 24 hours after a Round Root is posted during which it pays nothing and can be cancelled.
_Avoid_: Timelock, vesting, claim window

**Guard**:
The power to cancel a Round Root inside its Round Delay, and nothing else; the Admin holds it.
_Avoid_: Veto key, pauser, multisig

**Admin**:
The owner's one hardware wallet address on an EVM chain: it writes the Quote Registry, holds the Guard, replaces a server key and receives the platform's share (ADR 0030).
It can reach no coin's liquidity, no Credit and no Creator Lock.
_Avoid_: Owner (the contracts have none), deployer, Treasury (Solana's), multisig

**Stock Token**:
Robinhood Chain's name for one of its tokenized stocks, and the only name the site gives that chain's assets (ADR 0028).
_Avoid_: Tokenized stock (on that chain), stock coin, RWA, synthetic

**Unaudited statement**:
The sentence the site shows wherever money moves on an EVM chain: "Stoker's contracts on [chain] have not been audited by an independent firm. Their source is public and verified: [link]." (ADR 0030).
_Avoid_: Disclaimer (that is the site's country notice), risk warning, audit badge

**Launch** (on an EVM chain):
A new coin created on our platform together with its own pool, for the coin's whole life: nothing ends at Graduation, since the coin never moves pools.
_Avoid_: Token, pool, project, curve

**Launch Shape** (on an EVM chain):
The Direct Seed: 1 trillion coins at 18 decimals, a plain coin with no owner, the sold supply in the Seed Position and the Creator Lock held out of it.
_Avoid_: Tokenomics, curve settings

**Graduation** (on an EVM chain):
The moment a coin's price has held its Graduation Target for the Graduation Hold; recorded once and never undone (ADR 0024).
It starts the Creator Lock's clock and the count of Active Days, and nothing moves.
_Avoid_: Migration, bonding, listing, touching the target

**Graduation Target** (on an EVM chain):
A price, the Listing's start price times its Graduation multiple, fixed for a coin when it launches; not an amount raised.
_Avoid_: Bonding target, market cap target, raise

**Creator Lock** (on an EVM chain):
Coins held out of the Seed Position for the Creator, with the same limits as on Solana; the clock starts at Graduation as defined here.
_Avoid_: Vesting, team allocation, locked liquidity

**Quote Asset** (on an EVM chain):
An existing asset a Launch is priced and traded against that the chain's Quote Registry lists: the chain's native asset, a stablecoin or a Stock Token among them.
Listed only when it takes no fee on a transfer, does not rebase and can be held and paid out by our contracts with nobody's permission; an issuer's powers over it are Quote Risk Labels, never a bar (ADR 0028).
_Avoid_: Pair token, base, collateral, whitelisted token

**Asset category** (on an EVM chain):
The same ten kinds; a tokenized stock on Robinhood Chain is shown as a Stock Token.
_Avoid_: Type, sector, class

**Copy Protection** (on an EVM chain):
The same window, across every chain: a coin launched through Stoker on an EVM chain is protected on Solana too, and a coin on Solana on every EVM chain (ADR 0012, amended).
A coin sent straight to the factory, which Stoker holds no record of, is never protected and carries the label when it copies one that is.
_Avoid_: Cross-chain registry, ticker lock

**First Buy** (on an EVM chain):
The Creator's own buy inside the launch transaction, as on Solana; it pays the Platform Fee and is the one buy the Opening Fee never touches.
_Avoid_: Dev buy, initial buy, snipe

**Snipe Window** (on an EVM chain):
The seconds a Launch's Opening Fee runs.
_Avoid_: Block 0, launch block

**Bundle Radar** (on an EVM chain):
Labels only, as on Solana; the Opening Fee is the one thing a Sniper pays that others do not.
_Avoid_: Anti-sniper, bundle checker

**Platform Fee** (on an EVM chain):
Our share of every trade in a coin's own pool, one rate for the coin's life, taken by the contract in the Quote Asset; the Creator's part of it is theirs as a Credit by the coin's Creator Tier (ADR 0027).
A trade of the coin anywhere else pays none.
_Avoid_: Protocol fee (that is Uniswap's), pool fee, LP fee

**Fee Key** (on an EVM chain):
There is none: a coin's pool pays no fee to liquidity, and no locked position earns anything.
_Avoid_: LP NFT, position NFT

**Creator Fee**, **Creator Forward** (on an EVM chain):
There is neither: the Creator's share is a Credit, paid by a Payout Call.
_Avoid_: Forward, payout by us, claim

**Active Day** (on an EVM chain):
A UTC day on which a graduated coin's pool traded at least 1% of the Quote Asset it took to carry the coin from its start price to its Graduation Target (ADR 0027).
_Avoid_: Trading day, streak

**Graduation Fee** (on an EVM chain):
There is none.
_Avoid_: Migration fee, listing fee

**Operations Wallet**, **Treasury** (on an EVM chain):
There is neither: the Keeper holds no revenue, and the platform's share is paid to the Admin.
_Avoid_: Hot wallet, cold wallet

**Reward Tax**, **Stoke Tax** (on an EVM chain):
The percentage taken from every trade of the coin in its own pool, in the Quote Asset; a transfer between wallets and a trade in any other pool pay none (ADR 0025).
_Avoid_: Transfer fee, tax (on its own), coin tax

**Payout Asset** (on an EVM chain):
The same two choices, fixed at launch: the Quote Asset, paid as it was collected, or the coin, bought with the tax.
_Avoid_: Reward token, payout mode

**Reward Sale** (on an EVM chain):
There is none, since the tax is collected in the Quote Asset; a Payout Asset of the coin is a bounded buy instead.
_Avoid_: Dump, conversion

**Reward Burn** (on an EVM chain):
The same share and steps; the tax buys the coin in bounded pieces and what was bought is burned.
_Avoid_: Tax burn, auto-burn, Burn (on its own)

**Reward Liquidity** (on an EVM chain):
The same share and steps; it becomes Support Liquidity from the coin's first trade and does not wait for Graduation.
_Avoid_: Auto-liquidity, LP tax, floor

**Reward Round** (on an EVM chain):
The same published cycle, paid from the Distributor by its Round Root after the Round Delay; the Keeper sends each payment and anyone may claim for a holder.
_Avoid_: Distribution, epoch, airdrop

### Platform Token

**Platform Token**:
Our own coin, fair-launched as the first Launch on our platform with no presale or team allocation.
_Avoid_: Governance token, utility token, our coin

**Curated Launch**:
a coin the platform has approved and works on with its team, launched by the platform itself (owner, 2026-10-25, #118).
Only a wallet that stakes STOKER can buy one, and the more it stakes, the larger its allocation of that launch.
The header's "Curated" section lists them; none exists before the Platform Token does.

**Platform Net**:
What the platform keeps of its revenue: everything the Ledger records as collected (Platform Fee, pool creator fee, Fee Key) less the Creators' share of it, valued in SOL at the Quote Registry's latest prices (ADR 0019).
Fee Key collections enter it whole, since no Creator's share comes out of them.
_Avoid_: Profit, the platform's half (the Creator's share is more than half on a higher Creator Tier), revenue (that is before the Creators' share)

**Budget Table**:
The one table that divides the Platform Net between the Burn, the Flywheel, the trader programs (volume rebates, referrals on every pair, the integrator share) and the Treasury, each row a share in basis points and the six summing to 100% (ADR 0019).
It is versioned: a version is announced ahead like a fee change, and its shares apply only to what is collected while it is in force.
A row is a budget; what a row has been allotted less what the Ledger shows it spent is what it has left, which the Sweep leaves in the Operations Wallet.
_Avoid_: Revenue split, allocation, tokenomics

**Volume Rebate**:
What a trader earns back for one Rebate Week: their part of the pot the Budget Table's `rebates` row gives that week, split among the week's traders in proportion to the Platform Fees their trades paid, on the curve and in the pool, buys and sells (ADR 0021).
It is never more than the row's own share of the fees the trader paid, the platform's own wallets earn none, and a trade made while the row has no share earns nothing.
A wallet's Volume Rebates wait until together they reach the minimum payout, then are paid in SOL in one transfer, which the Ledger records as a `rebate`.
_Avoid_: Cashback, fee discount (the fee is paid in full and part of it comes back later), trading reward, airdrop

**Rebate Week**:
The period Volume Rebates are counted over: a UTC week, Monday 00:00 to the next Monday.
Its trades are settled together, once, after it has ended.
_Avoid_: Epoch, season, round (a Reward Round is a different thing)

**Burn**:
Using the Burn's row of the Budget Table to buy the Platform Token on the market and destroy it, on a public schedule; or, when the operator points it at liquidity, to add what it buys to the Platform Token's pool as Protocol-Owned Liquidity instead (#184).
_Avoid_: Buyback (on its own), revenue share, dividend

**Flywheel**:
Using the Flywheel's row of the Budget Table to buy the top Launches by an announced rule and burn them, or add them to their pools as Protocol-Owned Liquidity when the operator points it there.
_Avoid_: Top-10 buyback, support buys

**Protocol-Owned Liquidity**:
Liquidity the Burn's or the Flywheel's budget added to a graduated coin's own pool and locked for good, the platform holding each position's Fee Key and collecting its fees as revenue (#184, ADR 0006 amended); shown on the Stats page as its own figure.
A Creator's additions under the Liquidity destination are the Creator's earnings, not this.
_Avoid_: POL (in copy), LP, treasury liquidity
