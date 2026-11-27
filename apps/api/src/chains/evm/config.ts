import type { Hex } from "viem";
import { checksum, EVM_CHAINS, isEvmChain, type EvmChainProfile, type EvmDeployment } from "@launchpad/evm";
import type { Bindings } from "../../env";

/**
 * One EVM chain this API reads: its profile, the deployment of our contracts on it, the RPC the Worker reads it
 * through, and the server keys this API holds on it (ADR 0030, #254): the Keeper, which pays the gas of every call
 * anyone may make and the chain's Volume Rebates, and the ladder key, which raises a coin's Creator Tier. Each is the
 * Worker secret `<CHAIN>_KEEPER_KEY` or `<CHAIN>_LADDER_KEY`, a 32-byte hex private key, and either may be absent: the
 * jobs that need it then do nothing on that chain and say so. The round key is #255's.
 */
export type EvmChainConfig = EvmDeployment & { profile: EvmChainProfile; rpcUrl: string; keeperKey: Hex | null; ladderKey: Hex | null };

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;

function deployment(raw: unknown, i: number): EvmDeployment {
  const d = raw as Record<string, unknown>;
  const fail = (what: string) => new Error(`EVM_DEPLOYMENTS[${i}]: ${what}`);
  if (typeof d?.chain !== "string" || !isEvmChain(d.chain)) throw fail(`chain must be one of ${Object.keys(EVM_CHAINS).join(", ")}`);
  const addr = (key: string) => {
    const v = d[key];
    if (typeof v !== "string" || !ADDRESS.test(v)) throw fail(`${key} must be an address`);
    return checksum(v);
  };
  if (!Number.isSafeInteger(d.fromBlock) || (d.fromBlock as number) < 0) throw fail("fromBlock must be a block number");
  const positive = (key: string) => {
    const v = d[key];
    if (v === undefined) return undefined;
    if (!Number.isSafeInteger(v) || (v as number) < 1) throw fail(`${key} must be a whole number above zero`);
    return v as number;
  };
  const destinations = d.destinations === undefined ? undefined : (() => {
    const o = d.destinations as Record<string, unknown> | null;
    const one = (key: string) => {
      const v = o?.[key];
      if (typeof v !== "string" || !ADDRESS.test(v)) throw fail(`destinations.${key} must be an address`);
      return checksum(v);
    };
    return { holders: one("holders"), burn: one("burn"), liquidity: one("liquidity") };
  })();
  const keeperMin = d.keeperMinBalance;
  if (keeperMin !== undefined && (typeof keeperMin !== "string" || !/^\d+$/.test(keeperMin))) throw fail("keeperMinBalance must be a whole number of raw units, as a string");
  return {
    ...(destinations ? { destinations } : {}), behindAlertSeconds: positive("behindAlertSeconds"),
    ...(keeperMin !== undefined ? { keeperMinBalance: BigInt(keeperMin as string) } : {}),
    chain: d.chain, factory: addr("factory"), hook: addr("hook"), registry: addr("registry"), keys: addr("keys"), taxVault: addr("taxVault"), distributor: addr("distributor"),
    fromBlock: d.fromBlock as number, logBlockRange: positive("logBlockRange"), maxRangesPerRun: positive("maxRangesPerRun"), maxRunSeconds: positive("maxRunSeconds"),
    maxRequestsPerRun: positive("maxRequestsPerRun"), retryRuns: positive("retryRuns"), retryRunsUnclear: positive("retryRunsUnclear"),
  };
}

/**
 * The EVM chains this deployment of the API reads (#252), from `EVM_DEPLOYMENTS`: none unless it is set, so the mainnet
 * API and the devnet rehearsal read Solana alone until a deployment of the contracts exists (#251). Each chain's RPC is
 * the secret `<CHAIN>_RPC_URL` (`ROBINHOOD_RPC_URL`), whose key is never logged; a deployment without one is refused.
 */
export function evmChains(env: Bindings): EvmChainConfig[] {
  if (!env.EVM_DEPLOYMENTS) return [];
  const list: unknown = JSON.parse(env.EVM_DEPLOYMENTS);
  if (!Array.isArray(list)) throw new Error("EVM_DEPLOYMENTS must be a JSON list of deployments");
  const deployments = list.map(deployment);
  // One deployment a chain: two would share the chain's coins and its Indexer's work (the review of #252, item 14).
  const twice = deployments.find((d, i) => deployments.findIndex((o) => o.chain === d.chain) !== i);
  if (twice) throw new Error(`EVM_DEPLOYMENTS names ${twice.chain} twice`);
  return deployments.map((d) => {
    const rpcUrl = (env as unknown as Record<string, string | undefined>)[`${d.chain.toUpperCase()}_RPC_URL`];
    if (!rpcUrl) throw new Error(`EVM_DEPLOYMENTS names ${d.chain}, but ${d.chain.toUpperCase()}_RPC_URL is not set`);
    return { ...d, profile: EVM_CHAINS[d.chain], rpcUrl, keeperKey: serverKey(env, `${d.chain.toUpperCase()}_KEEPER_KEY`), ladderKey: serverKey(env, `${d.chain.toUpperCase()}_LADDER_KEY`) };
  });
}

/**
 * An error from a chain's RPC with its URL taken out: viem names the URL it called in every request error, and an RPC
 * URL carries the provider's key, which must never reach a log, a job's record or the operator's alert.
 */
export function withoutRpcUrl(e: unknown, c: Pick<EvmChainConfig, "chain" | "rpcUrl">): Error {
  const message = String((e as Error)?.message ?? e).replaceAll(c.rpcUrl, `<${c.chain.toUpperCase()}_RPC_URL>`);
  return new Error(message);
}

/** The platform's own contracts on the EVM chains that buy coins (the Tax Vaults), which are never holders; none when unreadable. */
export function evmBuyers(env: Bindings): string[] {
  try {
    return evmChains(env).map((c) => c.taxVault);
  } catch {
    return [];
  }
}

/** A server key from its Worker secret, or null when it is not set; a malformed one is refused without being repeated. */
function serverKey(env: Bindings, name: string): Hex | null {
  const v = (env as unknown as Record<string, string | undefined>)[name]?.trim();
  if (!v) return null;
  const key = v.startsWith("0x") ? v : `0x${v}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) throw new Error(`${name} must be a 32-byte private key in hex`);
  return key as Hex;
}

/** Every address of a deployment that is ours (#254): never a trader earning a rebate, never a Creator or a referrer. */
export const ourAddresses = (c: EvmChainConfig) =>
  [c.factory, c.hook, c.registry, c.keys, c.taxVault, c.distributor, ...(c.destinations ? Object.values(c.destinations) : [])].map((a) => a.toLowerCase());
