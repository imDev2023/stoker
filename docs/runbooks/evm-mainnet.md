# Robinhood Chain mainnet: deploying Stoker's contracts (#251, for #257)

What the owner does to put Stoker's EVM contracts on Robinhood Chain (4663), in order, and how each step is checked.
No agent deploys to a mainnet: every step here that sends a transaction is the owner's.
The contracts have not been audited by an independent firm (ADR 0030); `contracts/GATE.md` is what stands in an audit's place and what it does not cover.

## 0. Before anything is sent

Each of these is a condition, not advice.

- The rehearsal on testnet 46630 has run whole and its transactions are on #251.
- #250 is answered: Robinhood has said what the site may show.
- The API's two alarms exist (#254, #255) and the EVM Indexer is on (#279 closed): the API recomputes every posted Round Root and wakes the owner on a mismatch, and it alarms on a `CreatorTierRaised` its own job did not send.
  Without the first, the Guard's 24 hours protect nothing.
- A security contact is named for the contracts page (#256).
- The owner has decided two things the gate leaves open: whether to start with few Listings, and whether to offer a bug bounty.
- CI is green on the commit being deployed, the gate included, and `contracts/GATE.md` has been read by the owner.

## 1. The keys

| Key | Where it is kept | What it can do |
| --- | --- | --- |
| The Admin | The owner's hardware wallet, its seed phrase on paper. One address per chain. | Writes the Quote Registry, holds the Guard (cancels a Round Root inside its 24 hours), replaces a server key in two steps, receives the platform's share. |
| The round key | The Worker secret `ROBINHOOD_ROUND_KEY` on `stoker-api`. | Posts a Round Root, bounded by each coin's own pot, the Round Delay and the Guard. |
| The ladder key | The Worker secret `ROBINHOOD_LADDER_KEY`. | Raises one graduated coin's Creator Tier, never lowers one. |
| The Keeper | The Worker secret `ROBINHOOD_KEEPER_KEY`. | Nothing: it pays gas for calls anyone can make. |
| The deployer | A throwaway key in a file, funded with a little ETH. | Nothing once the set is deployed: no contract has an owner. |

Only the owner writes a Worker secret, and the three secrets' names are #254's and #255's to fix; these are the names proposed.
Each of the five is a different address: the deployment's check refuses the Admin as a server key or as the deployer, and one address in two roles.
If the device and the paper are both lost, Listings, price writes, the Guard and key replacement stop for good and the platform's unpaid share is lost; coins keep trading and every other Credit is still paid.

## 2. The settings

Every figure of the deployment is in `contracts/script/config/robinhood.json`, and none is a constant of a script.
The owner writes one value there: `admin`, the hardware wallet's address, read off the device's own screen and compared character by character.
While it is the zero address the deployment refuses to run.
The figures the ADRs fix (the Platform Fee of 100 basis points, the Creator Ladder's 5000, 6000 and 7000, a piece of 50) are also in `contracts/script/config/decided.json`, and the check refuses a deployment that carries another, whatever the chain's file says.
The Opening Value and the Graduation multiple are not here: they are each Listing's, written by the Admin in step 6.

## 3. The command

```sh
cd contracts
./script/deps.sh && forge build
script/deploy.sh robinhood fork
DEPLOYER_KEY_FILE=~/.config/stoker/robinhood/deployer.key script/deploy.sh robinhood live
```

The first `deploy.sh` deploys the whole set to a fresh fork of the chain and runs every check there; run it on the day.
The second sends eight transactions from the deployer, in the one order that works:

1. `StokerKeys`, with the Admin's address.
2. `QuoteRegistry`, with the keys and the tick spacing.
3. `Distributor`, for the Tax Vault's future address.
4. `TaxVault`, for the factory's future address and with the Distributor's.
5. `StokerFactory`, which deploys `StokerHook` at a salt mined so its address carries exactly its permission bits.
6. `BurnDestination`, `LiquidityDestination` and `HoldersDestination`, each with the hook's address.

Forge simulates all eight and runs the checks on the result before it sends any, so a set that would fail a check is never sent.
The deployer's key is read from the file into the one process's environment and is never an argument.
`ROBINHOOD_RPC_URL` must be set; the script never prints it.

## 4. How it is checked afterwards

`script/deploy.sh` runs `script/CheckDeployment.s.sol` against the chain straight after the transactions, and publishes `packages/evm/deployments/4663.json` only when every check passes.
It can be run again at any time, and sends nothing:

```sh
script/deploy.sh robinhood check
script/deploy.sh robinhood check keys
```

| What is asserted | Why |
| --- | --- |
| All nine contracts and the PoolManager have code, on chain 4663. | A record of a deployment that was never sent has been committed before, elsewhere. |
| `distributor.taxVault()` is the Tax Vault; `taxVault.distributor()` and `taxVault.factory()` are the real ones; the hook, the factory and the three Destinations each name the others. | The Distributor is made for an address computed ahead, which no constructor checks; a Destination serves one hook, and earnings sent to another deployment's are stranded. |
| The Admin is the settings file's address, has no code, is not the deployer, and nobody waits to take its place. | A mistyped Admin can never be replaced. |
| The round key, the ladder key and the Keeper are not the Admin, not each other and not the deployer; with `keys`, all three are held. | The contracts refuse the Admin's own raise and post; the check keeps every role apart. |
| Every setting is the chain file's; the Platform Fee, the three shares and `pieceBps` are the decided figures; the Round Delay is 24 hours and the Graduation Hold one hour. | Each is fixed for good at deployment; a piece of 100 would move a price about as much as a round trip costs. |
| The hook's address carries exactly the eight permission bits it reports, and is the address this build's hook creation code gives at the mined salt. | A CREATE2 address commits to its code. |
| Seven runtimes are byte for byte this build's (keys, registry, Distributor, Tax Vault, the three Destinations). | Each is redeployed inside the check's simulation and compared by code hash. |

What the check cannot assert, and how the owner checks it:

- **The factory's runtime.**
  It cannot be redeployed for comparison (a second factory would make its hook elsewhere), so it rests on the explorer: `script/verify.sh robinhood` verifies all nine sources and asks the explorer for each one's status.
  Robinhood Chain's explorer has refused forge's route before (a Cloudflare page, 2026-09-10); then the `blockscout-verify` skill's browser route is used, and the script's last lines must still say `verified` nine times.
- **That the Admin's address is the hardware wallet's.**
  Only the device can say: read `keys.admin()` from the explorer and compare it with the device's screen.
- **The Listings.**
  They are the Admin's writes (step 6); `registry.listingOf(asset)` reads each back.

## 5. The server keys

The Admin proposes each key from the hardware wallet, and the key accepts; nobody holds a role until it has.

```sh
cast send <keys> "proposeKey(uint8,address)" 0 <round key's address> --ledger --rpc-url robinhood
KEYS=<keys> ROLE=round SERVER_KEY=<the round key> forge script script/AcceptKey.s.sol --rpc-url robinhood --broadcast
```

The roles are 0 the round key, 1 the ladder key, 2 the Keeper (`round`, `ladder`, `keeper` for `ROLE`).
`SERVER_KEY` is read from the environment, so the key is set there for the one command and is never an argument.
Then `script/deploy.sh robinhood check keys` must pass, and each key becomes its Worker secret.
The `--ledger` line was not run by an agent: no hardware wallet is within one's reach.

## 6. The Listings

No coin can launch until an asset is listed.
`contracts/script/ListingWrite.s.sol` prepares each write from an Opening Value and a Graduation multiple and prints the target and the calldata; the Admin sends it:

```sh
REGISTRY=<registry> ACTION=list QUOTE=<asset, 0x0 for ETH> OPENING_VALUE=<raw units> MULTIPLE=20 CAP_BPS=100 \
  forge script script/ListingWrite.s.sol --rpc-url robinhood
cast send <registry> <the calldata it printed> --ledger --rpc-url robinhood
```

The launch form offers only this deployment's three Destination addresses, from `packages/evm/deployments/4663.json`, and names none of them as a referrer: a Referrer Fee named to a Destination, and earnings sent to another deployment's, are stranded for good.

## 7. If something goes wrong

- **A false Round Root, or a stolen round key.**
  `keys.revokeKey(0)` stops the key at once, then `distributor.cancelRoots(first, last)` cancels every root still inside its 24 hours in one call; a root not reached in time pays as posted.
- **A stolen ladder key.**
  `keys.revokeKey(1)`.
  Raises already made stand for those coins' lives; the loss is the platform's part of the Platform Fee on them, from half to three tenths.
- **A lost Keeper.**
  Nothing is lost and anyone can make its calls; the Admin appoints another.
- **A wrong Listing.**
  `registry.delist(asset)` stops new Launches on it at once; it comes back only by a scheduled change, 48 hours later.
  Coins already launched keep their terms.
- **A defect in a contract.**
  Nothing can be paused or upgraded.
  The Admin delists every asset, which stops new Launches; coins already launched trade on, and a new deployment serves later ones.
