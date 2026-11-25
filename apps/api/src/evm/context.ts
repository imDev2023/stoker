import type { Context } from "hono";
import { HTTPException } from "hono/http-exception";
import type { PublicClient } from "viem";
import { Chain, familyOf } from "@launchpad/contract";
import type { AppEnv } from "../env";
import { evmChains, withoutRpcUrl, type EvmChainConfig } from "../chains/evm/config";
import { evmClient } from "../chains/evm/indexer";

/** One EVM chain as a request reads it (#253): the deployment, and a client on the Worker's own RPC. */
export type EvmContext = { config: EvmChainConfig; client: PublicClient };

/**
 * The EVM chain a request names, or a refusal in words: 400 for a name that is no chain, 404 for Solana (these routes
 * are the EVM chain family's) and for a chain this deployment of the API does not read. A deployment whose
 * `EVM_DEPLOYMENTS` cannot be read answers 503 with the fault, never the RPC's URL.
 */
export function evmContext(c: Context<AppEnv>, named: string | undefined): EvmContext {
  const chain = Chain.safeParse(named);
  if (!chain.success) throw new HTTPException(400, { message: `unknown chain "${named ?? ""}"` });
  if (familyOf(chain.data) !== "evm") throw new HTTPException(404, { message: `${chain.data} is not an EVM chain` });
  let chains: EvmChainConfig[];
  try {
    chains = evmChains(c.env);
  } catch (e) {
    console.error(`EVM_DEPLOYMENTS cannot be read: ${(e as Error).message}`);
    throw new HTTPException(503, { message: "this chain's settings cannot be read" });
  }
  const config = chains.find((x) => x.chain === chain.data);
  if (!config) throw new HTTPException(404, { message: `${chain.data} is not available on this deployment` });
  return { config, client: evmClient(config) };
}

/** The EVM chain a coin's address is on, from this deployment's chains; today one, so the first. Null on a Solana-only deployment. */
export function evmContextOfCoin(c: Context<AppEnv>, chain: string | null | undefined): EvmContext {
  return evmContext(c, chain ?? undefined);
}

/** Runs a chain read and turns a provider's failure into 503 without the RPC's URL; a refusal thrown inside passes through. */
export async function reading<T>(x: EvmContext, work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (e) {
    if (e instanceof HTTPException) throw e;
    const clean = withoutRpcUrl(e, x.config);
    console.error(`reading ${x.config.chain} failed: ${clean.message}`);
    throw new HTTPException(503, { message: `${x.config.profile.name} could not be read just now. Try again.` });
  }
}
