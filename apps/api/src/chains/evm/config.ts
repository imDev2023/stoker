import { checksum, EVM_CHAINS, isEvmChain, type EvmChainProfile, type EvmDeployment } from "@launchpad/evm";
import type { Bindings } from "../../env";

/** One EVM chain this API reads: its profile, the deployment of our contracts on it, and the RPC the Worker reads it through. */
export type EvmChainConfig = EvmDeployment & { profile: EvmChainProfile; rpcUrl: string };

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
  return {
    chain: d.chain, factory: addr("factory"), hook: addr("hook"), registry: addr("registry"), keys: addr("keys"), taxVault: addr("taxVault"),
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
    return { ...d, profile: EVM_CHAINS[d.chain], rpcUrl };
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
