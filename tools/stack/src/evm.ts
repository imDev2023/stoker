// The test stack's EVM side (#252): a local fork of Robinhood Chain at the contracts' pinned block with our contracts
// deployed against the chain's real PoolManager, as the local chain with Raydium's programs serves Solana. The bytecode
// is the contracts' own build (`@launchpad/evm/bytecode`, checked equal to `forge build` in CI), deployed in the order
// contracts/README.md gives for #251: the keys, the Quote Registry, then the factory, whose constructor makes the hook
// at the salt mined here, and the native asset listed.
import {
  concat, createPublicClient, createWalletClient, encodeAbiParameters, getAddress, getContractAddress, http, keccak256, numberToHex, pad, parseAbiParameters,
  type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { distributorAbi, NATIVE, quoteRegistryAbi, ROBINHOOD_CHAIN, stokerFactoryAbi, stokerKeysAbi, taxVaultAbi } from "@launchpad/evm";
import {
  distributorBytecode, quoteRegistryBytecode, stokerFactoryBytecode, stokerHookBytecode, stokerKeysBytecode, taxVaultBytecode,
} from "@launchpad/evm/bytecode";

/** L2 block 120,800,000 (2026-11-22): the contracts' fork tests' block, so the chain facts they prove hold here. */
export const FORK_BLOCK = 120_800_000;
/** The tick spacing, the Platform Fee and the first Creator Tier's share the contracts' tests deploy with (ADR 0027). */
const TICK_SPACING = 200;
const PLATFORM_FEE_BPS = 100;
/** The Creator Ladder's three shares of the Platform Fee (#248, ADR 0027): the first Creator Tier's, the second's and the top's. */
const CREATOR_SHARE_BPS = 5_000;
const SECOND_TIER_SHARE_BPS = 6_000;
const TOP_TIER_SHARE_BPS = 7_000;
/** The Opening Fee (#246, ADR 0026): 99% of a buy at a Launch's first second, falling to nothing over 20 seconds. */
const OPENING_FEE_START_BPS = 9_900;
const OPENING_FEE_DURATION = 20;
/**
 * The native asset's start price: the whole supply worth about 1.7 ETH, near the Opening Value's $5,000 (ADR 0024); a
 * tick of wei per coin raw unit. The Graduation multiple and the Referrer Fee cap are the contracts' tests' too.
 */
export const NATIVE_START_TICK = -271_200;
const GRADUATION_MULTIPLE = 20;
/** The Tax Vault's settings the contracts' tests deploy with (#245): a piece of 0.5% of the pool's depth a minute, Support Liquidity ten spacings wide. */
const PIECE_BPS = 50;
const PIECE_INTERVAL = 60;
const SUPPORT_WIDTH_SPACINGS = 10;
/**
 * The Tax Vault's Reference Price (#271): it rises 2 ticks a minute and falls at once (60,000 ticks a minute), as the
 * contracts' tests set it, and a Reward Burn or a holders' buy waits while the price stands more than 100 ticks above
 * it. The tests' band is 0; a band lets a test burn once a pool is back near its opening price (a round trip leaves it
 * a tick off by rounding) without moving the fork's clock, which would date every later coin in the future. #251 sets
 * a live deployment's figures.
 */
const REFERENCE_RISE = 2;
const REFERENCE_FALL = 60_000;
const BUY_BAND = 100;
const REFERRER_FEE_CAP_BPS = 100;
/** The hook's permission bits (StokerHook.getHookPermissions, contracts/test/utils/StokerTestBase.sol's HOOK_FLAGS). */
const HOOK_FLAGS = (1n << 13n) | (1n << 11n) | (1n << 9n) | (1n << 7n) | (1n << 6n) | (1n << 5n) | (1n << 3n) | (1n << 2n);
const ALL_HOOK_MASK = (1n << 14n) - 1n;
/** EIP-2935's history storage contract, at the same address on every chain that has it. */
const BLOCK_HASH_HISTORY: Address = "0x0000F90827F1C53a10cb7A02335B175320002935";
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
  taxVault: Address;
  distributor: Address;
  tickSpacing: number;
  fromBlock: number;
  /** The Admin, which writes the Quote Registry: a test lists a Quote Asset with it. */
  admin: { address: Address; key: Hex };
};

/** The deployment as the API takes it in `EVM_DEPLOYMENTS`. */
/**
 * The deployment as the API takes it in `EVM_DEPLOYMENTS`. Anvil serves any `getLogs` range, so the stack starts wide
 * (2,000 blocks, a paid tier's size); a test behind a stricter RPC sees the range shrink.
 */
export const deploymentOf = (e: EvmStackEnv) => [
  { chain: e.chain, factory: e.factory, hook: e.hook, registry: e.registry, keys: e.keys, taxVault: e.taxVault, distributor: e.distributor, fromBlock: e.fromBlock, logBlockRange: 2_000 },
];

/** Finds the salt that gives the hook, made by the factory at `factory`, an address carrying exactly its permission bits. */
function mineHookSalt(factory: Address, poolManager: Address, keys: Address, taxVault: Address): Hex {
  const initHash = keccak256(concat([stokerHookBytecode, encodeAbiParameters(parseAbiParameters("address, address, address"), [poolManager, keys, taxVault])]));
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
export async function deployStoker(rpcUrl: string, { setClock = true }: { setClock?: boolean } = {}): Promise<EvmStackEnv> {
  const chain = { id: ROBINHOOD_CHAIN.chainId, name: ROBINHOOD_CHAIN.name, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } };
  const pub = createPublicClient({ chain, transport: http(rpcUrl) });
  const admin = privateKeyToAccount(ADMIN_KEY);
  const wallet = createWalletClient({ chain, transport: http(rpcUrl), account: admin });
  // Every block anvil mines calls the chain's block-hash history contract (EIP-2935), which writes a storage slot the
  // fork first reads from the remote RPC: one remote read a block until all 8,191 slots are cached (1,000 blocks took
  // 147 s on the free tier, and an hour's 34,200 failed at its rate limit, #279). Emptied, the call does nothing, as
  // the EIP has it for an address without code; nothing of ours reads a block hash.
  await pub.request({ method: "anvil_setCode" as never, params: [BLOCK_HASH_HISTORY, "0x"] as never });
  // A second deployment on a fork already at now (a factory deployed again, #279) leaves the clock alone.
  if (setClock) {
    await pub.request({ method: "evm_setNextBlockTimestamp" as never, params: [numberToHex(Math.floor(Date.now() / 1000))] as never });
    await pub.request({ method: "evm_mine" as never, params: [] as never });
  }

  const poolManager = ROBINHOOD_CHAIN.uniswap.poolManager;
  const deployed = async (hash: Hex) => {
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success" || !r.contractAddress) throw new Error(`deploying our contracts failed in ${hash}`);
    return r;
  };
  const keysReceipt = await deployed(await wallet.deployContract({ abi: stokerKeysAbi, bytecode: stokerKeysBytecode, args: [admin.address] }));
  const keys = keysReceipt.contractAddress!;
  const registry = (await deployed(await wallet.deployContract({ abi: quoteRegistryAbi, bytecode: quoteRegistryBytecode, args: [keys, TICK_SPACING] }))).contractAddress!;
  // The Distributor (#247), the Tax Vault and the factory each name another, so each is made for the address the next
  // deployments will have: the Distributor for the vault's, the vault for the Distributor's and the factory's.
  const nonce = await pub.getTransactionCount({ address: admin.address, blockTag: "pending" });
  const [distributorAt, vaultAt, factoryAt] = [0, 1, 2].map((i) => getContractAddress({ from: admin.address, nonce: BigInt(nonce + i) }));
  const distributor = (await deployed(await wallet.deployContract({ abi: distributorAbi, bytecode: distributorBytecode, args: [keys, vaultAt!] }))).contractAddress!;
  const taxVault = (
    await deployed(await wallet.deployContract({ abi: taxVaultAbi, bytecode: taxVaultBytecode, args: [poolManager, factoryAt!, distributorAt!, PIECE_BPS, PIECE_INTERVAL, SUPPORT_WIDTH_SPACINGS, REFERENCE_RISE, REFERENCE_FALL, BUY_BAND] }))
  ).contractAddress!;
  if (distributor.toLowerCase() !== distributorAt!.toLowerCase() || taxVault.toLowerCase() !== vaultAt!.toLowerCase()) {
    throw new Error("the Distributor and the Tax Vault did not land at the addresses they were made for");
  }
  const salt = mineHookSalt(factoryAt!, poolManager, keys, taxVault);
  const factory = (
    await deployed(await wallet.deployContract({ abi: stokerFactoryAbi, bytecode: stokerFactoryBytecode, args: [poolManager, registry, PLATFORM_FEE_BPS, CREATOR_SHARE_BPS, SECOND_TIER_SHARE_BPS, TOP_TIER_SHARE_BPS, salt, taxVault, OPENING_FEE_START_BPS, OPENING_FEE_DURATION] }))
  ).contractAddress!;
  if (factory.toLowerCase() !== factoryAt!.toLowerCase()) throw new Error(`the factory landed at ${factory}, not the ${factoryAt} its hook's salt was mined for`);
  const hook = await pub.readContract({ address: factory, abi: stokerFactoryAbi, functionName: "hook" });
  const list = await wallet.writeContract({ address: registry, abi: quoteRegistryAbi, functionName: "list", args: [NATIVE, NATIVE_START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS] });
  await pub.waitForTransactionReceipt({ hash: list });
  // A receipt names a new contract in lower case; the API stores and answers every EVM address checksummed.
  return {
    chain: "robinhood", rpcUrl, chainId: ROBINHOOD_CHAIN.chainId, poolManager, factory: getAddress(factory), hook: getAddress(hook), registry: getAddress(registry),
    keys: getAddress(keys), taxVault: getAddress(taxVault), distributor: getAddress(distributor), tickSpacing: TICK_SPACING,
    fromBlock: Number(keysReceipt.blockNumber), admin: { address: admin.address, key: ADMIN_KEY },
  };
}

/**
 * Anvil's arguments for a fork of Robinhood Chain at the pinned block. The block is pinned, so Foundry keeps what it
 * reads under `~/.foundry/cache/rpc/` and a later start reads the remote only for state it has not seen: the free RPC
 * tier is shared with the contract lanes. The chain id is given, so a start with everything cached needs no remote call.
 * Past blocks' states are kept in memory alone (the last 500) and never written to disk: nothing reads one (#279: the
 * Indexer asks for no past state, and a fork's state read back from disk has lost its contracts' code), and a block
 * then mines in a twentieth of the time.
 */
export const forkArgs = (forkUrl: string, port: number) => [
  "--fork-url", forkUrl, "--fork-block-number", String(FORK_BLOCK), "--fork-chain-id", String(ROBINHOOD_CHAIN.chainId), "--no-fork-node-info",
  "--port", String(port), "--host", "127.0.0.1", "--quiet", "--prune-history",
];
