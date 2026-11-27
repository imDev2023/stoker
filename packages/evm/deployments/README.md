# Where Stoker's EVM contracts are deployed

The one place the API and integrators read a deployment's addresses (#251, user story 44 of #231).
One file per chain, named by its chain id: `<chain id>.json`.
The ABIs are beside it, in `../src/generated/abis.ts`, written from the contracts' own build.

A file here is never written by hand.
`contracts/script/deploy.sh <chain> live` writes it, and only after `contracts/script/CheckDeployment.s.sol` has found every contract on the chain and passed every check there: a script that only simulated a deployment once left a record of contracts that were never sent, elsewhere, and this folder is kept out of that.
A fork's record stays under `contracts/cache/` and is never published.

## The shape

| Field | What it is |
| --- | --- |
| `chain`, `chainId`, `name`, `explorer` | The chain, as its settings file `contracts/script/config/<chain>.json` names it. |
| `deployedAt`, `commit` | When the record was written, and the commit of this repository the contracts were built from. |
| `poolManager` | Uniswap v4's PoolManager on the chain, which every pool of ours lives in. |
| `admin` | The Admin: it writes the Quote Registry, holds the Guard, replaces a server key and receives the platform's share (ADR 0030). |
| `deployer` | The throwaway address that sent the deployment. It holds no power: no contract has an owner. |
| `fromBlock` | The block of the first contract, as the chain's RPC numbers it: an Indexer starts there. |
| `contracts` | The nine addresses: `keys`, `registry`, `distributor`, `taxVault`, `factory`, `hook`, `burnDestination`, `liquidityDestination`, `holdersDestination`. |
| `transactions` | For each of the nine, the transaction that created it and its block. The hook is created by the factory's. |
| `hookSalt` | The CREATE2 salt the factory deployed the hook at; with it, anyone can recompute the hook's address from its creation code. |
| `settings` | Every figure the set was deployed with. A Launch's opening figures are not here: they are each Listing's, read from the registry. |
| `evmDeployment` | The same addresses in the shape the API takes in `EVM_DEPLOYMENTS` (`EvmDeployment` in `../src/chains.ts`). |

The launch form offers a Creator Earnings Destination of the burn, the liquidity or the holders only by the three addresses in `contracts` of the chain's own file.
A Destination serves one hook, so earnings sent to another deployment's, and a Referrer Fee a trade names to one, are stranded for good.

## Checking a file against its chain

```sh
cd contracts
script/deploy.sh <chain> check        # every check of the deployment, against the chain as it is now
script/deploy.sh <chain> check keys   # and the three server keys held, apart from the Admin and each other
```

Neither sends anything.

## The chains

- `46630.json`, Robinhood Chain's testnet: the rehearsal of #251, with a test Admin whose key is a throwaway.
  It is a rehearsal and no coin on it is a Launch of Stoker's; the API has no profile for the chain (`../src/chains.ts`), which is #257's.
  Not written yet on 2026-11-27: the testnet's faucet pays through a form that needs a person, and the deployment waits for one claim (issue #251).
- `4663.json`, Robinhood Chain: not deployed.
  The owner deploys it, with the hardware wallet's address as the Admin (`docs/runbooks/evm-mainnet.md`).
