// The operator's view of each EVM chain's keys and the owner's record of a Burn budget carried to Solana (#254, ADR 0030).
import { Hono } from "hono";
import { Connection } from "@solana/web3.js";
import { zeroAddress, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { RecordBurnCarry, type EvmChainKeys, type EvmKey, type EvmKeysPage } from "@launchpad/contract";
import { WSOL_MINT } from "@launchpad/chain";
import { NATIVE, stokerKeysAbi } from "@launchpad/evm";
import { ledgerEntries } from "@launchpad/db";
import { operationsKey, type AppEnv } from "../env";
import { withoutRpcUrl, type EvmChainConfig } from "../chains/evm/config";
import { evmClient } from "../chains/evm/indexer";
import { keeperMinBalanceOf, readableChains } from "../chains/evm/keeper";

export const operatorEvmRoutes = new Hono<AppEnv>();

/** `StokerKeys.Role`, in its declared order. */
const ROLE = { round_key: 0, ladder_key: 1, keeper: 2 } as const;

/** What each key can do and what it can never do (ADR 0030): the operator view's words, from the decision itself. */
const POWERS: Record<EvmKey["role"], { can: string[]; cannot: string[] }> = {
  admin: {
    can: ["write the Quote Registry's Listings", "cancel a Round Root inside its Round Delay (the Guard)", "replace a server key, or itself, in two steps", "receive the platform's share"],
    cannot: ["reach a coin's liquidity, a Credit or a Creator Lock", "change a launched coin's terms", "raise a Creator Tier", "pause trading"],
  },
  round_key: {
    can: ["post a Round Root to the Distributor"],
    cannot: ["pay a round inside its Round Delay", "pay more than a coin's own tax", "cancel a root", "move a Credit"],
  },
  ladder_key: {
    can: ["raise a graduated coin's Creator Tier"],
    cannot: ["lower a tier", "raise a coin that has not graduated", "touch a pool, a Credit or a coin's terms"],
  },
  keeper: {
    can: ["make the calls anyone may make: Payout Calls, the Tax Vault's calls, Graduation's call, a Destination's call", "pay the chain's Volume Rebates from its balance"],
    cannot: ["anything another wallet cannot do: it holds no power"],
  },
};

async function chainKeys(c: EvmChainConfig): Promise<EvmChainKeys> {
  const client = evmClient(c);
  const read = (role: number) => client.readContract({ address: c.keys, abi: stokerKeysAbi, functionName: "holderOf", args: [role] });
  const [admin, round, ladder, keeper] = await Promise.all([
    client.readContract({ address: c.keys, abi: stokerKeysAbi, functionName: "admin" }), read(ROLE.round_key), read(ROLE.ladder_key), read(ROLE.keeper),
  ]);
  const held = (key: `0x${string}` | null, on: Address) => key !== null && privateKeyToAccount(key).address.toLowerCase() === on.toLowerCase();
  const named = (a: Address) => (a === zeroAddress ? null : a);
  const keeperAddress = c.keeperKey ? privateKeyToAccount(c.keeperKey).address : null;
  const balance = keeperAddress ? await client.getBalance({ address: keeperAddress }) : null;
  const least = keeperMinBalanceOf(c);
  return {
    chain: c.chain,
    name: c.profile.name,
    keys: [
      { role: "admin", address: admin, heldByApi: false, ...POWERS.admin },
      { role: "round_key", address: named(round), heldByApi: false, ...POWERS.round_key },
      { role: "ladder_key", address: named(ladder), heldByApi: held(c.ladderKey, ladder), ...POWERS.ladder_key },
      // The Keeper holds no power, so the chain's record of it is a label: the API's key is what pays.
      { role: "keeper", address: keeperAddress ?? named(keeper), heldByApi: keeperAddress !== null, ...POWERS.keeper },
    ],
    keeper: {
      balance: balance?.toString() ?? null, symbol: c.profile.native.symbol, decimals: c.profile.native.decimals, minBalance: least.toString(),
      low: balance !== null && balance < least,
    },
  };
}

/** `GET /v1/operator/evm-keys`: each EVM chain's Admin and server keys with their powers, and the Keeper's balance. */
operatorEvmRoutes.get("/evm-keys", async (c) => {
  const { chains, problem } = readableChains(c.env);
  const answered: EvmChainKeys[] = [];
  const problems = problem ? [problem] : [];
  for (const chain of chains) {
    try {
      answered.push(await chainKeys(chain));
    } catch (e) {
      problems.push(`${chain.chain}: ${withoutRpcUrl(e, chain).message.split("\n")[0]}`);
    }
  }
  const res: EvmKeysPage = { chains: answered, problem: problems.length ? problems.join("; ") : null };
  return c.json(res);
});

/**
 * `POST /v1/operator/burn-carries`: the owner's record of an EVM chain's Burn budget carried to Solana by hand (ADR
 * 0030): one Ledger entry on the EVM chain for what left the Admin's address and one on Solana for what reached the
 * operations wallet. Both transactions are read from their chains first, so the record names real payments.
 */
operatorEvmRoutes.post("/burn-carries", async (c) => {
  const body = RecordBurnCarry.safeParse(await c.req.json().catch(() => null));
  if (!body.success) return c.json({ error: "invalid burn carry", details: body.error.issues }, 400);
  const { chains } = readableChains(c.env);
  const chain = chains.find((x) => x.chain === body.data.chain);
  if (!chain) return c.json({ error: `this API reads no EVM chain called ${body.data.chain}` }, 400);
  const client = evmClient(chain);
  const receipt = await client.getTransactionReceipt({ hash: body.data.evmTransaction as `0x${string}` }).catch(() => null);
  if (!receipt || receipt.status !== "success") return c.json({ error: `${chain.profile.name} has no successful transaction ${body.data.evmTransaction}` }, 400);
  const admin = await client.readContract({ address: chain.keys, abi: stokerKeysAbi, functionName: "admin" });
  if (receipt.from.toLowerCase() !== admin.toLowerCase()) return c.json({ error: `${body.data.evmTransaction} was not sent from the Admin's address ${admin}` }, 400);
  const evmBlock = await client.getBlock({ blockNumber: receipt.blockNumber });
  const cfg = c.get("cfg");
  const connection = new Connection(cfg.rpcUrl, "confirmed");
  const solana = await connection.getTransaction(body.data.solanaSignature, { commitment: "confirmed", maxSupportedTransactionVersion: 0 }).catch(() => null);
  if (!solana || solana.meta?.err) return c.json({ error: `Solana has no successful transaction ${body.data.solanaSignature}` }, 400);
  const operations = operationsKey(c.env).publicKey.toBase58();
  const inserted = await c.get("db").insert(ledgerEntries).values([
    {
      chain: chain.chain, signature: receipt.transactionHash, eventIndex: 0, kind: "burn_carry", assetMint: NATIVE, assetDecimals: chain.profile.native.decimals, amount: body.data.amount,
      source: admin, destination: receipt.to ?? admin, launchMint: null, slot: Number(receipt.blockNumber), blockTime: new Date(Number(evmBlock.timestamp) * 1000),
    },
    {
      chain: "solana", signature: body.data.solanaSignature, eventIndex: 0, kind: "burn_carry", assetMint: WSOL_MINT.toBase58(), assetDecimals: 9, amount: body.data.lamports,
      source: chain.chain, destination: operations, launchMint: null, slot: solana.slot, blockTime: new Date((solana.blockTime ?? Math.floor(Date.now() / 1000)) * 1000),
    },
  ]).onConflictDoNothing().returning({ chain: ledgerEntries.chain });
  return c.json({ recorded: inserted.length });
});
