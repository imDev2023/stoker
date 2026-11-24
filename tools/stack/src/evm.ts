// The test stack's EVM side (#252): a local fork of Robinhood Chain at the contracts' pinned block with our contracts
// deployed against the chain's real PoolManager, as the local chain with Raydium's programs serves Solana. The bytecode
// is the contracts' own build (`@launchpad/evm/bytecode`, checked equal to `forge build` in CI), deployed in the order
// contracts/README.md gives for #251: the keys, the Quote Registry, then the factory, whose constructor makes the hook
// at the salt mined here, and the native asset listed.
import {
  concat, createPublicClient, createWalletClient, encodeAbiParameters, getContractAddress, http, keccak256, numberToHex, pad, parseAbiParameters,
  type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { NATIVE, quoteRegistryAbi, ROBINHOOD_CHAIN, stokerFactoryAbi, stokerKeysAbi } from "@launchpad/evm";
import { quoteRegistryBytecode, stokerFactoryBytecode, stokerHookBytecode, stokerKeysBytecode } from "@launchpad/evm/bytecode";

/** L2 block 120,800,000 (2026-11-22): the contracts' fork tests' block, so the chain facts they prove hold here. */
export const FORK_BLOCK = 120_800_000;
/** The tick spacing, the Platform Fee and the first Creator Tier's share the contracts' tests deploy with (ADR 0027). */
const TICK_SPACING = 200;
const PLATFORM_FEE_BPS = 100;
const CREATOR_SHARE_BPS = 5_000;
/**
 * The native asset's start price: the whole supply worth about 1.7 ETH, near the Opening Value's $5,000 (ADR 0024); a
 * tick of wei per coin raw unit. The Graduation multiple and the Referrer Fee cap are the contracts' tests' too.
 */
export const NATIVE_START_TICK = -271_200;
const GRADUATION_MULTIPLE = 20;
const REFERRER_FEE_CAP_BPS = 100;
/** The hook's permission bits (StokerHook.getHookPermissions, contracts/test/utils/StokerTestBase.sol's HOOK_FLAGS). */
const HOOK_FLAGS = (1n << 13n) | (1n << 11n) | (1n << 9n) | (1n << 7n) | (1n << 6n) | (1n << 5n) | (1n << 3n) | (1n << 2n);
const ALL_HOOK_MASK = (1n << 14n) - 1n;
/** Anvil's first account, which every fork starts with ether in: the deployer and the Admin of the stack's contracts. */
const ADMIN_KEY: Hex = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

export type EvmStackEnv = {
  chain: "robinhood";
  rpcUrl: string;
  chainId: number;
  poolManager: Address;
  factory: Address;
  hook: Address;
  registry: Address;
  keys: Address;
  tickSpacing: number;
  fromBlock: number;
  /** The Admin, which writes the Quote Registry: a test lists a Quote Asset with it. */
  admin: { address: Address; key: Hex };
};

/** The deployment as the API takes it in `EVM_DEPLOYMENTS`. */
export const deploymentOf = (e: EvmStackEnv) => [{ chain: e.chain, factory: e.factory, hook: e.hook, registry: e.registry, keys: e.keys, fromBlock: e.fromBlock }];

/** Finds the salt that gives the hook, made by the factory at `factory`, an address carrying exactly its permission bits. */
function mineHookSalt(factory: Address, poolManager: Address, keys: Address): Hex {
  const initHash = keccak256(concat([stokerHookBytecode, encodeAbiParameters(parseAbiParameters("address, address"), [poolManager, keys])]));
  for (let i = 0n; ; i++) {
    const salt = pad(numberToHex(i), { size: 32 });
    const hook = getContractAddress({ opcode: "CREATE2", from: factory, salt, bytecodeHash: initHash });
    if ((BigInt(hook) & ALL_HOOK_MASK) === HOOK_FLAGS) return salt;
  }
}

/**
 * Deploys our contracts to the EVM chain at `rpcUrl` (a fork) and lists the native asset. The fork's clock is first set
 * to now: a fork otherwise carries on from its block's time, two days back, and every trade would fall outside the
 * board's last 24 hours.
 */
export async function deployStoker(rpcUrl: string): Promise<EvmStackEnv> {
  const chain = { id: ROBINHOOD_CHAIN.chainId, name: ROBINHOOD_CHAIN.name, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } };
  const pub = createPublicClient({ chain, transport: http(rpcUrl) });
  const admin = privateKeyToAccount(ADMIN_KEY);
  const wallet = createWalletClient({ chain, transport: http(rpcUrl), account: admin });
  await pub.request({ method: "evm_setNextBlockTimestamp" as never, params: [numberToHex(Math.floor(Date.now() / 1000))] as never });
  await pub.request({ method: "evm_mine" as never, params: [] as never });

  const poolManager = ROBINHOOD_CHAIN.uniswap.poolManager;
  const deployed = async (hash: Hex) => {
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success" || !r.contractAddress) throw new Error(`deploying our contracts failed in ${hash}`);
    return r;
  };
  const keysReceipt = await deployed(await wallet.deployContract({ abi: stokerKeysAbi, bytecode: stokerKeysBytecode, args: [admin.address] }));
  const keys = keysReceipt.contractAddress!;
  const registry = (await deployed(await wallet.deployContract({ abi: quoteRegistryAbi, bytecode: quoteRegistryBytecode, args: [keys, TICK_SPACING] }))).contractAddress!;
  const nonce = await pub.getTransactionCount({ address: admin.address, blockTag: "pending" });
  const factoryAt = getContractAddress({ from: admin.address, nonce: BigInt(nonce) });
  const salt = mineHookSalt(factoryAt, poolManager, keys);
  const factory = (
    await deployed(await wallet.deployContract({ abi: stokerFactoryAbi, bytecode: stokerFactoryBytecode, args: [poolManager, registry, PLATFORM_FEE_BPS, CREATOR_SHARE_BPS, salt] }))
  ).contractAddress!;
  if (factory.toLowerCase() !== factoryAt.toLowerCase()) throw new Error(`the factory landed at ${factory}, not the ${factoryAt} its hook's salt was mined for`);
  const hook = await pub.readContract({ address: factory, abi: stokerFactoryAbi, functionName: "hook" });
  const list = await wallet.writeContract({ address: registry, abi: quoteRegistryAbi, functionName: "list", args: [NATIVE, NATIVE_START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS] });
  await pub.waitForTransactionReceipt({ hash: list });
  return {
    chain: "robinhood", rpcUrl, chainId: ROBINHOOD_CHAIN.chainId, poolManager, factory, hook, registry, keys, tickSpacing: TICK_SPACING,
    fromBlock: Number(keysReceipt.blockNumber), admin: { address: admin.address, key: ADMIN_KEY },
  };
}

/**
 * Anvil's arguments for a fork of Robinhood Chain at the pinned block. The block is pinned, so Foundry keeps what it
 * reads under `~/.foundry/cache/rpc/` and a later start reads the remote only for state it has not seen: the free RPC
 * tier is shared with the contract lanes. The chain id is given, so a start with everything cached needs no remote call.
 */
export const forkArgs = (forkUrl: string, port: number) => [
  "--fork-url", forkUrl, "--fork-block-number", String(FORK_BLOCK), "--fork-chain-id", String(ROBINHOOD_CHAIN.chainId), "--no-fork-node-info",
  "--port", String(port), "--host", "127.0.0.1", "--quiet",
];
