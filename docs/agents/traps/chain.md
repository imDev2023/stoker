# Traps: the chain, LaunchLab, CPMM and transactions

Read before touching `packages/chain`, `tools/localnet`, `tools/mainnet`, a transaction's accounts or size, or a key.
Moved out of `CLAUDE.md` on 2026-11-12 so it is read on demand; `CLAUDE.md` keeps the index.
The text is the original's, one sentence a line.

## LaunchLab and CPMM

- The `PlatformConfig` address is derived from the admin key and the admin can never change (ADR 0004).
- Our platform sets `restrict_curve_param`, so every launch must pass the curve-rule PDA as the last account; a mismatched shape fails with 6025 `CurveParamNotMatchPlatformRule`.
- Trades must include the platform and creator fee-vault accounts or fail with 6018.
- A Creator Fee vault is per (Creator, Quote Asset) across every LaunchLab platform; ours pays nothing into it (ADR 0009), but every trade must still name it (or fail with 6018), and the program opens it on the first trade that does, at that trader's expense.
  The Indexer tracks no claims and the webhook does not watch the vault authority.
- `migrate_to_cpswap` wants the CPMM `support_mint` PDAs in the pool's token order (sorted mint bytes), not quote then base; WSOL sorts first for all but about 1 in 40 mints, so the wrong order fails only now and then with 2502 `RequireKeysEqViolated`.
- A migrated CPMM pool opens one second after migration by the chain's clock, which lags the wall clock on the local validator; check `Pool.chainTime` against `openTime`, never `Date.now()`.
- The deployed CPMM's `collect_creator_fee` wants one account more than Raydium's published IDL: the `creator_fee_share` PDA (creator, CPMM config) last, even when it doesn't exist, or it fails with 3005 `AccountNotEnoughKeys`.
  Raydium's LP-lock program only has a legacy IDL; `packages/chain/idl/lock.json` is it converted to the current Anchor format.
- CPMM's ExceededSlippage is 6005 (LaunchLab's is 6004), and CPMM emits `SwapEvent` to the log (`Program data:`), not through a self-invocation like LaunchLab's `TradeEvent`.
- A curve's coins sit in `launchlabPdas.vault(pool, mint)`, owned by the LaunchLab vault authority PDA, not in an associated token account; after Graduation the CPMM authority PDA owns the pool's.
- A Quote Asset with no curve rule account is unrestricted even with `restrict_curve_param` on, so the Quote Registry refresh (`/__scheduled`, run once by `tools/stack` at startup) gives every GlobalConfig a rule, a closed one when unpriced (ADR 0005).
  The dev API needs `OPERATIONS_KEY` (the operations key as a JSON byte array, `tools/localnet/.keys/operations.json`) in `apps/api/.dev.vars` and one `curl localhost:8791/__scheduled` before anything can launch.
- LaunchLab's vesting, behind the Creator Lock (ADR 0023, proven on the local chain 2026-11-13): a curve rule holds ten groups at most (6027 on the eleventh), each about 0.0017 SOL of rent, and compares a field with a constant, so no rule can say that the sale and the lock add up.
  A launch that locks nothing must have a cliff and an unlock time of 0 (2501 `RequireEqViolated` otherwise), so one group cannot both admit a lock and demand a least lock time.
  The clock starts at the buy that sells the curve out (`start_time` is that block's time plus the cliff, and the migration leaves it alone), a claim needs the migration (6015), and coins the creator gave to no wallet stay in the vault for ever: the program takes a share until the cliff ends and never after.
  After Graduation LaunchLab's own vault still holds the locked coins, owned by its authority, so anything that counts holders must go on leaving that vault out.
  The local chain's GlobalConfigs are devnet's loose ones; mainnet's want at least 15% of the supply in the pool and, on SOL's, at least 20% sold and at most 80% locked, so a limit that mainnet enforces is checked by arithmetic (`creatorLockCapBps`), never by a launch failing locally.
  A script that starts a local chain and stops it keeps running on web3.js's websocket retries: end it with `process.exit(0)`, and never pipe a long run through `tail`, which shows nothing until it ends.

## Transactions and web3.js

- A SOL transfer of less than an account's rent-exempt minimum (890,880 lamports) to a wallet with no SOL fails; the Creator Forward lets such a share wait, and a Reward Round returns such a payout to the pot.
- `simulateTransaction` returns account lamports with the network fee already taken off; subtracting `getFeeForMessage` again double-counts it.
- A launch transaction is about 980 bytes with the longest name, so a launch with a First Buy only fits Solana's 1,232 bytes through the Platform Lookup Table (`PLATFORM_LOOKUP_TABLE`, owned by the operations wallet, built from `platformLookupAddresses`).
  A SOL First Buy also needs SOL's own accounts in it (1,256 bytes without); other Quote Assets fit on the shared accounts alone (about 1,020 bytes), and a table holds at most 256 addresses, so on mainnet list SOL and the busiest Quote Assets only.
- A compute-unit limit sized on the transactions seen is enough by luck (#282): what a transaction costs moves with the addresses it names, since a program that opens a wallet's account for an asset (its associated token account), checks that an account is the wallet's, or names a program-derived address by its seeds searches for that address on-chain, bump 255 first and then down, at 1,500 units a try.
  One try serves half of all addresses and each further try half of the rest, so an address of 14 tries turns up once in 8,000, and a wallet meets a new address with every asset: the operations wallet with every Quote Asset and every graduated coin, a Creator with their own coin.
  LaunchLab's two claims (`claim_platform_fee_from_vault`, `claim_vested_token`) open the account themselves and derive its address three times between LaunchLab and the program that opens it, 4,500 units a try: the Platform Fee claim costs 47,000 units with lucky addresses, plus 1,500 for every further try of its vault's address, and passed its old limit of 100,000 at 14 tries whatever the vault (at 12 on the day it was found, with an unlucky vault besides), and nothing else opens that account, so the Fee Collector failed on every run; a Creator Lock's claim (50,000) passed the same limit at 13.
  Once the account is open either claim derives its address once, 1,500 a try.
  CPMM's `collect_creator_fee` checks both of the creator's accounts and our own instructions open them, 3,000 a try each; a Fee Key's collection and a trade derive an account's address once, in the instruction of ours that opens it.
  So a limit is the costliest case measured with every address at one try plus room for at least 40 more tries of the address the transaction derives most often (`PLATFORM_FEE_CLAIM_COMPUTE_UNITS` in `packages/chain/src/revenue.ts` holds the arithmetic), never the costliest transaction seen plus a round margin.
  Measure with `UNITS_REPORT=<file> pnpm test:backend` (`tests/backend/src/units.ts`: every kind of transaction of the run, the least and the most it used of its limit, and what the costliest left, in units and in tries), and prove a limit with an unlucky address rather than a lucky run: the backend stack's unlucky Quote Asset (`unluckyQuoteMint` in `tools/localnet`, 14 tries for that stack's operations wallet) and `mintWithUnluckyAccount` in `tests/backend/src/client.ts`.
  Measured on 2026-11-27, the most a transaction of the suite used, its limit, and the tries of room that leaves at 1,500 units a try: a curve buy 126,000 of 200,000 (49), a curve sell 70,000 of 200,000 (86), a pool swap 63,000 of 150,000 (57), a launch 160,000 of 400,000 (160), a launch with a First Buy 243,000 of 600,000 (238), a buy paid with SOL 164,000 of 360,000 (130), a Fee Key's collection 146,000 of 250,000 (69).
  The four limits #282 raised, with the cost at lucky addresses and the room at the transaction's own steepest cost a try: the Platform Fee claim 47,000 of 250,000 (45 tries at 4,500; it was 100,000), a Creator Lock's claim 50,000 of 250,000 (44 at 4,500; it was 100,000), a pool's creator fee 79,000 of 250,000 (56 at 3,000; it was 150,000, which left 23), a liquidity addition 221,000 at most of 400,000 (39 at 4,500, the steepest any program showed, since the lock's own was not measured; it was 300,000, which left 17).
  No transaction of ours sets a compute-unit price, so the room costs nothing; with a price a transaction pays it on the limit it asked for, whatever it used (at 10,000 micro-lamports a unit, 2,500 lamports for a limit of 250,000 against 1,000 for 100,000, on top of the 5,000 a signature costs), and a limit should then come from a simulation of the transaction.
  A transaction that sets no limit (the sweep, the Creator Forward) gets Solana's default of 200,000 units for each instruction that calls a program, 1.4 million at most, which is room for a hundred tries and more.
- A retry must never mint a second coin: launch mint keys are derived from `MINT_KEY_SECRET` and a nonce in `launch_drafts`, so `POST /v1/launches/:mint/prepare` rebuilds the same address.
  Airdrop transactions for a wallet are only handed out again once every earlier one has expired (`airdrop_recipients.sendable_until`).
- A v0 transaction through an address lookup table is dropped until the table's last extension is rooted (about 32 slots, 15 s locally); create tables ahead of use.
  The migration needs one (1,471 bytes as legacy); the local migrate wallet's table is made at bootstrap.
- Sending the same transaction twice in a row (same signers, same instructions) makes web3.js wait for a new finalized blockhash and fail after 10 s ("Unable to obtain a new blockhash"); batch such work into one transaction.
- `Keypair.publicKey` returns a new `PublicKey` on every access: compare keys with `.equals`, never `===`.
- web3.js `confirmTransaction` rejects with a bare object (`{ InstructionError, stacks: [] }` on Surfpool) when the transaction failed before the subscription; `confirmOutcome` and `sendLanding` in `tests/backend/src/client.ts` and `landedError` in the web app treat that as a landed failure, not a lost connection.
- Buys paid with SOL (#19, #64) swap through a route source: Jupiter's Swap API v2 on mainnet (`jupiterSwapIn` in `packages/chain`, `GET /swap/v2/build`), and locally `raydium-cpmm`, the SOL-USDC and SOL-JTO CPMM pools `tools/localnet/src/routes.ts` seeds (NVDAx has none on purpose).
  Jupiter v2 has no exact-out, so every source swaps an exact amount of SOL and promises the least it delivers (`ROUTE_TOLERANCE_BPS`, a fixed 0.3%, owner's choice) into the buyer's own Quote Asset account; the trade spends that minimum and the rest stays in the wallet (`route.kept` on the quote).
  The quote endpoint has no trader, so it prices for a stand-in taker; prepare asks once for the real trader.
  A routed buy only fits a transaction through the Platform Lookup Table, so a `raydium-cpmm` route pool's accounts must be in it (the local chain adds them); Jupiter brings its own tables.
  A Token-2022 transfer-fee Quote Asset can't be routed.
  The local chain has no Jupiter: `pnpm --filter @launchpad/mainnet jupiter-route <wallet with SOL> [mint]` with a mainnet `RPC_URL` simulates the real swap (proven 2026-10-04 for USDC and NVDAx).

## The local chain and keys

- `solana account --output json` dumps `rentEpoch` as u64 max; a JSON round-trip turns it into a float the validator rejects, so write 0. A mainnet account cloned into the local chain must also have its `owner` rewritten to the devnet program id the chain runs (the CPMM is `DRaycpLY...` there, `CPMMoo8L...` on mainnet), or LaunchLab's owner constraint fails (2004) at bootstrap, and a PDA must be moved to the address its seeds derive under that program (a CPMM config at `["amm_config", index]`, bump byte included), or LaunchLab answers `InvalidCpSwapConfig` (6016).
- Surfpool's websocket is not on `rpc+1`; `tools/localnet` forwards the adjacent ports so web3.js's default derivation works.
  `pkill -f` on a pattern that matches the calling shell kills the shell; kill by pid.
- The six quote cases (`tools/localnet/fixtures/quotes`) are clones of mainnet mints whose mint authority the local admin key holds; fund a test wallet with `mintLocalQuote`, never by transfer.
  The development chain's other 600 mints keep their real authorities (the Quote Registry reads an asset's kind from them), so they can't be minted locally, and only the cases and the forty deepest markets are in the lookup tables: a coin paired with any other asset launches, but not with a First Buy.
- A vanity prefix that starts with a letter after `J` costs 1,000 times what 58^n says: 94% of keys encode to 44 base58 characters, which can only begin with `1` to `J`, so a first character from `K` to `z` (every lowercase one included) needs a 43-character key, 1 in 1,000, and the rest of the prefix is 1 in 58 each.
  `Stoker` is therefore 1 in 6.6e11 keys.
  `solana-keygen grind` on this Mac (20 threads, Xeon W-2150B) does about 424,000 keys/s, read from the `Searched N keypairs in Ts` lines of its log (`~/.config/stoker/mainnet/grind.log`), so one `Stoker` key is 18 days expected and four about 72 (measured 2026-10-09: 1.1e11 searched in 74 h and nothing found, which is the 84% case); `Stoke` is 7.4 h a key and `Stok` 8 minutes.
  A suffix is worse again.
  Estimate from the log's rate and this arithmetic, never from 58^n.
  Two chains side by side (the dev stack's and a suite's) slow the longest flows too: `burn.test.ts`'s graduated Reward Launch takes 80 s alone and overran 90 s in a full run next to the dev stack, so it has 180 s.
