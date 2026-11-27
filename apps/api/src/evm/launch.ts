import type { Context } from "hono";
import { HTTPException } from "hono/http-exception";
import { and, eq } from "drizzle-orm";
import {
  ContractFunctionRevertedError, decodeErrorResult, domainSeparator, encodeFunctionData, erc20Abi, getTypesForEIP712Domain, parseAbi, parseSignature, toHex,
  type Address, type ContractFunctionArgs, type Hex, type TypedDataDomain,
} from "viem";
import {
  LAUNCH_IMAGE_MAX_BYTES, LAUNCH_IMAGE_TYPES, PrepareEvmLaunchFields, REWARD_TAX_RATES, type EvmFirstBuy, type EvmLaunchCost, type EvmLaunchTerms, type EvmTransaction,
  type EvmTypedData, type PreparedEvmLaunch,
} from "@launchpad/contract";
import { checksum, feeOnGross, FIRST_BUY_GAS, NATIVE, quoteFirstBuy, seedPosition, stokerFactoryAbi, stokerHookAbi, type FirstBuyQuote } from "@launchpad/evm";
import { launchMetadata } from "@launchpad/db";
import { checkCopies, firstCopy } from "../copies/check";
import { imageHash } from "../copies/imageHash";
import { operationsKey, type AppEnv } from "../env";
import { sniffImageType } from "../images";
import { checkLiquidityLaunch, checkRewardShares, creatorLockChoice, LaunchModeError, taxChoice, type CreatorLockChoice } from "../launch";
import { arweaveUrl, signedItems, signMetadataItems } from "../metadata";
import { evmContext, reading, type EvmContext } from "./context";
import { launchRefusals } from "./names";
import { chainOptions, listedQuote, stockSymbols, type FactorySettings, type ListedQuote } from "./options";

/** `StokerFactory.LaunchParams`, as the contracts' own build types it. */
export type LaunchParams = ContractFunctionArgs<typeof stokerFactoryAbi, "payable", "launch">[0];

/** `StokerHook.LaunchType` and `StokerHook.PayoutAsset`, in their declared order. */
const LAUNCH_TYPE = { standard: 0, reward: 1, liquidity: 2 } as const;
const PAYOUT_ASSET = { quote: 0, coin: 1 } as const;

/**
 * The gas limit a prepared transaction carries: the estimate of that very transaction and a quarter more. An estimate
 * is the least gas the transaction needs in the state it was made in, and the state moves before the wallet's
 * transaction lands: a slot another transaction has since written costs differently (a Stock Token's own books, the
 * PoolManager's balance of the Quote Asset), and a swap's cost depends on the second it lands in, since the hook moves
 * a pool's Reference Price on the first swap of a new second (#271). On an Arbitrum Orbit chain the limit also covers
 * the cost of posting the transaction to the parent chain, which follows that chain's fee. Gas a transaction does not
 * use is not charged, so the margin costs the Creator nothing; it only asks the wallet to hold that much more.
 */
const GAS_MARGIN_PERCENT = 125n;
export const withMargin = (gas: bigint) => (gas * GAS_MARGIN_PERCENT) / 100n;

/** How long a permit the Creator signs for the First Buy stays good, counted from the chain's own time. */
const PERMIT_SECONDS = 30n * 60n;

/** The sender an estimate is made from when no wallet is connected: an address nobody has the key of, which holds no code. */
const NEUTRAL: Address = "0x000000000000000000000000000000000000dEaD";

const permitAbi = parseAbi([
  "function nonces(address owner) view returns (uint256)",
  "function DOMAIN_SEPARATOR() view returns (bytes32)",
  "function eip712Domain() view returns (bytes1 fields, string name, string version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] extensions)",
  "function version() view returns (string)",
]);

const refuse = (status: 400 | 409, message: string): never => {
  throw new HTTPException(status, { message });
};

const randomSalt = (): Hex => toHex(crypto.getRandomValues(new Uint8Array(32)));

/**
 * A contract's refusal of a call the API tried out, or null when the failure is the provider's. viem reads a
 * provider's internal error (-32603) as a revert too; a real one carries revert data, or says it reverted.
 */
function revertOf(e: unknown): { name: string | null; empty: boolean } | null {
  for (let x: unknown = e, i = 0; x && i < 10; x = (x as { cause?: unknown }).cause, i++) {
    if (!(x instanceof ContractFunctionRevertedError)) continue;
    const hasData = !!x.raw && x.raw !== "0x";
    if (!hasData && !/revert/i.test(x.reason ?? "")) return null;
    if (x.data) return { name: x.data.errorName, empty: false };
    // An error the factory's ABI does not name is the hook's, taken in the First Buy's swap.
    let name: string | null = null;
    if (hasData) {
      try {
        name = decodeErrorResult({ abi: stokerHookAbi, data: x.raw! }).errorName;
      } catch {
        // Some other contract's: the Quote Asset's own, most likely.
      }
    }
    return { name, empty: !hasData };
  }
  return null;
}

const TOO_SMALL = "The first buy is too small to get any coins. Enter a larger amount.";
const TOO_LARGE = "A first buy can't take every coin in the pool. Enter a smaller amount.";
const notListed = (chainName: string) => `That asset isn't a Quote Asset on ${chainName}. Choose one from the list.`;

/**
 * A refusal of the launch by the chain, in words; the provider's own failure is thrown on for `reading`. The factory's
 * `new` reverts with nothing when the coin's address is taken, so where `collision` is set (the launch tried out with
 * no First Buy, when no Quote Asset is touched) a revert with no data means this very launch has landed already.
 */
function refuseRevert(e: unknown, chainName: string, { collision = false } = {}): never {
  const revert = revertOf(e);
  if (!revert) throw e;
  if (revert.empty && collision)
    return refuse(409, "This coin has already been launched: a launch from this wallet with this name, ticker and salt has landed. Start a new launch.");
  return refuse(400, wordsFor(chainName, revert.name) ?? `${chainName} refused this launch when it was tried out${revert.name ? ` (${revert.name})` : ""}. Nothing was sent.`);
}

/** What the factory's and the hook's own refusals of a launch mean, by their names in the contracts; undefined for any other. */
function wordsFor(chainName: string, errorName: string | null): string | undefined {
  const words = launchRefusalWords(chainName);
  return errorName !== null && Object.hasOwn(words, errorName) ? words[errorName] : undefined;
}

const launchRefusalWords = (chainName: string): Record<string, string> => ({
  NotListed: notListed(chainName),
  InvalidStartTick: `That asset's Listing on ${chainName} can't open a Launch right now. Choose another asset.`,
  InvalidGraduationMultiple: `That asset's Listing on ${chainName} can't open a Launch right now. Choose another asset.`,
  InvalidCreatorLock: "The Creator Lock is outside the limits. Lock a fifth of the supply at most, for seven days at least.",
  InvalidTaxRate: "A tax is 1% to 5% in whole percents.",
  InvalidShares: "A Reward Launch's burn and liquidity shares are none, a tenth, a quarter or half, and half together at most.",
  InvalidPayoutAsset: "Only a Reward Launch has a payout asset.",
  ValueMismatch: "The launch must be sent exactly its first buy in the native asset, and nothing with any other asset.",
  SwapTooSmall: TOO_SMALL,
  SwapStoppedEarly: TOO_LARGE,
});

/** The First Buy as the contract answers it. */
const firstBuyToContract = (q: Extract<FirstBuyQuote, { ok: true }>): EvmFirstBuy => ({
  amountIn: q.amountIn.toString(), coinsOut: q.coinsOut.toString(), fees: { platform: q.platformFee.toString(), tax: q.tax.toString() },
});

/**
 * What a First Buy buys from a new Launch's seed, or a refusal in words. The pool's currency order follows the two
 * addresses, and each order rounds on its own, so the figure is exact only with the order known.
 */
export function firstBuyOrRefuse(
  listed: ListedQuote, settings: FactorySettings, p: { amountIn: bigint; taxBps: number; lockBps: number; quoteIsCurrency0: boolean },
): Extract<FirstBuyQuote, { ok: true }> {
  let quote: FirstBuyQuote;
  try {
    const seed = seedPosition({ startTick: listed.startTick, tickSpacing: settings.tickSpacing, quoteIsCurrency0: p.quoteIsCurrency0, lockBps: p.lockBps });
    quote = quoteFirstBuy(seed, { amountIn: p.amountIn, platformFeeBps: settings.platformFeeBps, taxBps: p.taxBps });
  } catch (e) {
    // A start price so far out that the seed's liquidity or its price leaves Uniswap's own ranges: the factory could not
    // place such a seed either, in this currency order.
    if (!(e instanceof RangeError)) throw e;
    return refuse(400, `${listed.option.symbol ?? "That asset"}'s Listing can't take a first buy right now. Launch without one, or choose another asset.`);
  }
  if (!quote.ok) return refuse(400, quote.reason === "too_small" ? TOO_SMALL : TOO_LARGE);
  return quote;
}

/** A launch's cost: the gas at the chain's price of the moment, and the native asset the launch itself is sent. */
const costOf = (gas: bigint, gasPrice: bigint, value: bigint): EvmLaunchCost => ({ gas: gas.toString(), gasPrice: gasPrice.toString(), fee: (gas * gasPrice).toString(), value: value.toString() });

/**
 * The gas a launch is estimated to use before its First Buy can be tried (no allowance yet, or only a form's choices):
 * `eth_estimateGas` of the launch without its First Buy, and a measured allowance for the First Buy's swap when there
 * is one.
 */
async function estimateWithoutFirstBuy(x: EvmContext, from: Address, params: LaunchParams, hasFirstBuy: boolean) {
  const gas = await x.client
    .estimateContractGas({ address: x.config.factory, abi: stokerFactoryAbi, functionName: "launch", args: [{ ...params, firstBuy: 0n }], account: from })
    .catch((e: unknown) => refuseRevert(e, x.config.profile.name));
  return gas + (hasFirstBuy ? FIRST_BUY_GAS : 0n);
}

/**
 * The cost of a launch as a form's choices stand, for GET /v1/chains/:chain/launch-quote: estimated from the Creator's
 * wallet when one is connected, and for a coin with the longest name and ticker the form takes, so the figure is never
 * under for the coin's text.
 */
export async function launchCost(
  x: EvmContext, settings: FactorySettings, p: { quote: Address; creator?: Address | undefined; firstBuy: bigint | null; taxBps: number; lockBps: number },
): Promise<EvmLaunchCost> {
  if (p.taxBps !== 0 && !(REWARD_TAX_RATES as readonly number[]).includes(p.taxBps)) refuse(400, "A tax is 1% to 5% in whole percents.");
  if (p.lockBps > settings.creatorLock.maxBps) refuse(400, lockTooLarge(settings));
  const params: LaunchParams = {
    name: "N".repeat(32), symbol: "S".repeat(10), quote: p.quote, salt: randomSalt(), creatorDestination: NATIVE, firstBuy: 0n,
    launchType: p.taxBps ? LAUNCH_TYPE.reward : LAUNCH_TYPE.standard, taxBps: p.taxBps, burnShareBps: 0, liquidityShareBps: 0, payoutAsset: PAYOUT_ASSET.quote,
    creatorLockBps: p.lockBps, creatorLockCliff: p.lockBps ? settings.creatorLock.minSeconds : 0, creatorLockUnlock: 0,
  };
  return reading(x, async () => {
    const [gas, gasPrice] = await Promise.all([estimateWithoutFirstBuy(x, p.creator ?? NEUTRAL, params, p.firstBuy !== null), x.client.getGasPrice()]);
    return costOf(gas, gasPrice, p.firstBuy !== null && p.quote === NATIVE ? p.firstBuy : 0n);
  });
}

const days = (seconds: number) => `${Math.round(seconds / 86_400)} days`;
const lockTooLarge = (s: FactorySettings) => `A Creator Lock can hold ${s.creatorLock.maxBps / 100}% of the supply at most. Lock less.`;

/** Checks a Creator Lock against the factory's own limits, so the chain is never asked for one it would refuse. */
function checkCreatorLock(lock: CreatorLockChoice, s: FactorySettings) {
  if (lock.bps > s.creatorLock.maxBps) refuse(400, lockTooLarge(s));
  if (lock.cliffSeconds + lock.unlockSeconds < s.creatorLock.minSeconds)
    refuse(400, `A Creator Lock lasts ${days(s.creatorLock.minSeconds)} at least, its cliff and its unlock time together. Make it longer.`);
  if (lock.cliffSeconds > s.creatorLock.maxPartSeconds || lock.unlockSeconds > s.creatorLock.maxPartSeconds)
    refuse(400, `A Creator Lock's cliff and its unlock time can each be ${days(s.creatorLock.maxPartSeconds)} at most. Make it shorter.`);
}

/**
 * The domain an asset signs ERC-2612 permits under, or null when it has no permit the API can prepare: it must answer
 * the owner's nonce and its domain separator, and the separator must be the hash of a domain the API can name, from
 * the asset's own `eip712Domain()` (EIP-5267) or from its name and version (version "1" when it has none), so the
 * wallet signs exactly what the asset checks.
 */
async function permitOf(x: EvmContext, asset: Address, owner: Address): Promise<{ domain: TypedDataDomain; nonce: bigint } | null> {
  const token = { address: asset, abi: permitAbi } as const;
  const [nonce, separator, described, name, version] = await x.client.multicall({
    allowFailure: true,
    multicallAddress: x.config.profile.multicall3,
    batchSize: 0,
    contracts: [
      { ...token, functionName: "nonces", args: [owner] }, { ...token, functionName: "DOMAIN_SEPARATOR" }, { ...token, functionName: "eip712Domain" },
      { address: asset, abi: erc20Abi, functionName: "name" }, { ...token, functionName: "version" },
    ],
  });
  if (nonce.status !== "success" || separator.status !== "success") return null;
  const candidates: TypedDataDomain[] = [];
  if (described.status === "success") {
    const [fields, itsName, itsVersion, chainId, verifyingContract, salt, extensions] = described.result;
    const has = (bit: number) => (Number(fields) & bit) !== 0;
    if (extensions.length === 0)
      candidates.push({
        ...(has(1) ? { name: itsName } : {}), ...(has(2) ? { version: itsVersion } : {}), ...(has(4) ? { chainId: Number(chainId) } : {}),
        ...(has(8) ? { verifyingContract } : {}), ...(has(16) ? { salt } : {}),
      });
  }
  if (name.status === "success")
    candidates.push({ name: name.result, version: version.status === "success" ? version.result : "1", chainId: x.config.profile.chainId, verifyingContract: asset });
  const domain = candidates.find((d) => domainSeparator({ domain: d }) === separator.result);
  return domain ? { domain, nonce: nonce.result } : null;
}

/** The typed data of a permit for the factory to take exactly the First Buy, as a wallet signs it (`eth_signTypedData_v4`). */
function permitTypedData(domain: TypedDataDomain, p: { owner: Address; spender: Address; value: bigint; nonce: bigint; deadline: bigint }): EvmTypedData {
  return {
    domain: domain as Record<string, unknown>,
    types: {
      EIP712Domain: getTypesForEIP712Domain({ domain }),
      Permit: [
        { name: "owner", type: "address" }, { name: "spender", type: "address" }, { name: "value", type: "uint256" }, { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Permit",
    message: { owner: p.owner, spender: p.spender, value: p.value.toString(), nonce: p.nonce.toString(), deadline: p.deadline.toString() },
  };
}

/**
 * POST /v1/launches/prepare for an EVM chain (#253): checks the launch as the chain would, stores the coin's picture
 * and record under the address the launch will give it, and answers the next thing for the Creator's wallet to do: an
 * approval or a permit for a First Buy in an ERC-20, or the launch itself. Nothing is signed or sent here (ADR 0003).
 */
export async function prepareEvmLaunch(c: Context<AppEnv>, form: FormData): Promise<Response> {
  const cfg = c.get("cfg");
  const db = c.get("db");
  // 1. The form's fields, and the chain, which this deployment must read.
  const fields = PrepareEvmLaunchFields.safeParse(Object.fromEntries([...form.entries()].filter(([, v]) => typeof v === "string")));
  if (!fields.success) return c.json({ error: "invalid launch fields", details: fields.error.issues }, 400);
  const f = fields.data;
  const x = evmContext(c, f.chain);
  const { config, client } = x;
  const chainName = config.profile.name;
  const creator = checksum(f.creator.toLowerCase());
  const quote = checksum(f.quote.toLowerCase());
  const { settings, body: options } = await chainOptions(db, x);

  // 2. The chain's own rules for a coin's text.
  const links = { website: f.website, x: f.x, telegram: f.telegram, discord: f.discord, tiktok: f.tiktok, instagram: f.instagram, youtube: f.youtube };
  const refusals = launchRefusals(f.chain, { name: f.name, symbol: f.symbol, description: f.description, links }, await stockSymbols(db, x));
  if (refusals.length > 0) return c.json({ error: refusals[0]!.reason, refusals }, 400);

  // 3. The picture: required with the first call, which stores it; a later call names the stored one by its salt.
  const image = form.get("image");
  let picture: { bytes: Uint8Array; contentType: string; hash: string | null } | null = null;
  if (!f.salt) {
    if (!(image instanceof File) || image.size === 0) return c.json({ error: "an image is required" }, 400);
    if (image.size > LAUNCH_IMAGE_MAX_BYTES) return c.json({ error: "image is larger than 2 MB" }, 400);
    const bytes = new Uint8Array(await image.arrayBuffer());
    const contentType = sniffImageType(bytes);
    if (!contentType || !(LAUNCH_IMAGE_TYPES as readonly string[]).includes(contentType)) return c.json({ error: "image must be PNG, JPEG, WebP or GIF" }, 400);
    picture = { bytes, contentType, hash: await imageHash(bytes, contentType) };
  }

  // 4. Copy Protection, on every chain (ADR 0012). A later call's picture was checked when it was stored.
  const copy = firstCopy(await checkCopies(db, cfg, { name: f.name, symbol: f.symbol, ...(picture ? { imageHash: picture.hash } : {}), creator }));
  if (copy) return c.json({ error: copy.reason, copy }, 409);

  // 5. The Quote Asset must be listed, as the registry says now: it alone gates a Launch.
  const listed = (await listedQuote(db, x, quote, { fresh: true })) ?? refuse(400, notListed(chainName));
  const ticker = listed.option.symbol ?? "the Quote Asset";

  // 6. The terms, refused here wherever the factory would revert.
  const tax = inWords(() => taxChoice(f));
  const reward = tax.taxKind === "reward";
  inWords(() => {
    if (tax.taxKind === "liquidity") checkLiquidityLaunch({ rewardPayout: f.rewardPayout ?? null, rewardBurnBps: f.rewardBurn ?? null, rewardLiquidityBps: f.rewardLiquidity ?? null });
    if (f.rewardPayout && !tax.rewardTaxBps) throw new LaunchModeError("A payout asset is only for a Reward Launch. Choose a Reward Tax, or leave the payout asset out.");
    checkRewardShares(tax.rewardTaxBps, f.rewardBurn ?? null, f.rewardLiquidity ?? null);
  });
  const destination = f.earningsDestination ?? "wallet";
  if (!options.destinations.includes(destination)) refuse(400, `On ${chainName} a Creator's earnings go to the Creator's own wallet for now. Choose your wallet.`);
  const lock = inWords(() => creatorLockChoice(f));
  if (lock) checkCreatorLock(lock, settings);
  const terms: EvmLaunchTerms = {
    type: tax.taxKind === "liquidity" ? "liquidity" : reward ? "reward" : "standard",
    taxBps: tax.rewardTaxBps ?? 0,
    burnShareBps: reward ? (f.rewardBurn ?? 0) : 0,
    // A Stoke Launch's whole tax becomes Support Liquidity, which the factory writes as the whole share (`_writeTaxTerms`).
    liquidityShareBps: tax.taxKind === "liquidity" ? 10_000 : reward ? (f.rewardLiquidity ?? 0) : 0,
    payoutAsset: reward ? (f.rewardPayout ?? "coin") : null,
    earningsDestination: destination,
    creatorLock: lock,
  };

  const amount = f.firstBuy ? BigInt(f.firstBuy) : null;
  const native = quote === NATIVE;
  const salt = (f.salt as Hex | undefined) ?? randomSalt();
  const params: LaunchParams = {
    name: f.name, symbol: f.symbol, quote, salt,
    // Zero is the Creator's own wallet, the one Destination today; another names its contract here (#248).
    creatorDestination: NATIVE,
    firstBuy: amount ?? 0n,
    launchType: LAUNCH_TYPE[terms.type], taxBps: terms.taxBps, burnShareBps: terms.burnShareBps,
    // The factory takes no liquidity share for a Stoke Launch: it writes the whole one itself.
    liquidityShareBps: reward ? terms.liquidityShareBps : 0,
    payoutAsset: PAYOUT_ASSET[terms.payoutAsset ?? "quote"],
    creatorLockBps: lock?.bps ?? 0, creatorLockCliff: lock?.cliffSeconds ?? 0, creatorLockUnlock: lock?.unlockSeconds ?? 0,
  };
  const factory = { address: config.factory, abi: stokerFactoryAbi } as const;

  const tried = await reading(x, async () => {
    // 7. The First Buy: the Creator's wallet must hold it, and in the native asset something for the network's fee too.
    let held = 0n;
    if (amount !== null) {
      // The fees are the same in either currency order, so a buy they swallow whole is refused before any chain call.
      if (feeOnGross(amount, BigInt(settings.platformFeeBps)) + feeOnGross(amount, BigInt(terms.taxBps)) >= amount) refuse(400, TOO_SMALL);
      held = native ? await client.getBalance({ address: creator }) : await client.readContract({ address: quote, abi: erc20Abi, functionName: "balanceOf", args: [creator] });
      if (held < amount || (native && held === amount))
        refuse(400, `Your wallet doesn't hold enough ${ticker} for this first buy${native ? " and the network's fee" : ""}. Add ${ticker} or buy less.`);
    }
    // 8. The coin's address: the launch tried out from the Creator's wallet without its First Buy, which answers the
    // address the factory will give the coin and proves the launch would not revert.
    const { result } = await client
      .simulateContract({ ...factory, functionName: "launch", args: [{ ...params, firstBuy: 0n }], account: creator })
      .catch((e: unknown) => refuseRevert(e, chainName, { collision: true }));
    return { coin: checksum(result[0]), pool: result[1], held };
  });
  const { coin, pool } = tried;
  const [stored] = await db.select().from(launchMetadata).where(and(eq(launchMetadata.id, coin), eq(launchMetadata.chain, f.chain))).limit(1);
  if (f.salt && !stored) refuse(400, "This launch wasn't prepared here with that salt. Prepare it again from the start, with its picture.");

  // 10. What the wallet does next, worked out before anything is stored, so a launch refused here leaves nothing behind.
  // The pool's currency order follows the two addresses, so the First Buy is exact only now that the coin's is known.
  const firstBuy = amount === null ? null : firstBuyOrRefuse(listed, settings, { amountIn: amount, taxBps: terms.taxBps, lockBps: lock?.bps ?? 0, quoteIsCurrency0: BigInt(quote) < BigInt(coin) });
  const step = await reading(x, async (): Promise<Pick<PreparedEvmLaunch, "step" | "transaction" | "permit" | "permitDeadline" | "cost">> => {
    const gasPrice = await client.getGasPrice();
    const transaction = (to: Address, data: Hex, value: bigint, gas: bigint): EvmTransaction => ({
      chainId: config.profile.chainId, to, data, value: value.toString(), gas: withMargin(gas).toString(),
    });
    const launch = async () => {
      const value = native ? (amount ?? 0n) : 0n;
      const gas = await client.estimateContractGas({ ...factory, functionName: "launch", args: [params], account: creator, value }).catch((e: unknown) => refuseRevert(e, chainName));
      if (value > 0n && tried.held < value + gas * gasPrice) refuse(400, `Your wallet holds the first buy but not the network's fee on top of it. Add ${ticker} or buy less.`);
      const data = encodeFunctionData({ abi: stokerFactoryAbi, functionName: "launch", args: [params] });
      return { step: "launch" as const, permit: null, permitDeadline: null, transaction: transaction(config.factory, data, value, gas), cost: costOf(gas, gasPrice, value) };
    };
    if (amount === null || native) return launch();
    const allowance = await client.readContract({ address: quote, abi: erc20Abi, functionName: "allowance", args: [creator, config.factory] });
    if (allowance >= amount) return launch();

    // A First Buy in an ERC-20 the factory may not take yet: a permit where the asset has one, an approval otherwise.
    if (!f.permitSignature !== !f.permitDeadline) refuse(400, "A permit's signature and its deadline come together. Send both, or neither.");
    const waiting = costOf(await estimateWithoutFirstBuy(x, creator, params, true), gasPrice, 0n);
    const permit = await permitOf(x, quote, creator);
    const now = (await client.getBlock()).timestamp;
    if (permit && f.permitSignature && f.permitDeadline) {
      const deadline = BigInt(f.permitDeadline);
      if (deadline <= now) refuse(400, "That permit has expired. Prepare the launch again and sign the new one.");
      const { r, s, yParity } = parseSignature(f.permitSignature as Hex);
      const args = [params, { deadline, v: 27 + yParity, r, s }] as const;
      const gas = await client.estimateContractGas({ ...factory, functionName: "launchWithPermit", args, account: creator }).catch((e: unknown) => {
        // The factory goes on when a permit fails, so a bad one shows as the Quote Asset refusing the transfer, by
        // whatever error that asset has; a refusal the factory or the hook names is the launch's own.
        const revert = revertOf(e);
        if (!revert) throw e;
        if (wordsFor(chainName, revert.name)) refuseRevert(e, chainName);
        return refuse(400, "That permit doesn't let the factory take the first buy: it was signed for another launch or amount, or has been used. Prepare the launch again and sign the new one.");
      });
      const data = encodeFunctionData({ abi: stokerFactoryAbi, functionName: "launchWithPermit", args });
      return { step: "launch", permit: null, permitDeadline: null, transaction: transaction(config.factory, data, 0n, gas), cost: costOf(gas, gasPrice, 0n) };
    }
    if (permit) {
      const deadline = now + PERMIT_SECONDS;
      const typedData = permitTypedData(permit.domain, { owner: creator, spender: config.factory, value: amount, nonce: permit.nonce, deadline });
      return { step: "permit", transaction: null, permit: typedData, permitDeadline: deadline.toString(), cost: waiting };
    }
    // An asset with no permit the API can prepare: an approval of exactly the First Buy, a transaction of its own.
    const approval = { address: quote, abi: erc20Abi, functionName: "approve", args: [config.factory, amount] } as const;
    const gas = await client.estimateContractGas({ ...approval, account: creator }).catch((e: unknown) => {
      if (!revertOf(e)) throw e;
      return refuse(400, `${ticker} refused to let the factory take the first buy from your wallet. Nothing was sent.`);
    });
    return { step: "approve", permit: null, permitDeadline: null, transaction: transaction(quote, encodeFunctionData(approval), 0n, gas), cost: waiting };
  });

  // 9. The picture and the record, as Solana's are stored, under the coin's address; a later call finds them there.
  let metadataUri: string;
  if (stored) {
    const items = await signedItems(db, coin);
    if (!items) throw new Error(`the prepared launch ${coin} has no signed metadata items`);
    metadataUri = arweaveUrl(cfg.arweave, items.metadata.arweaveId);
  } else {
    if (!picture) throw new Error(`the launch ${coin} has neither a stored record nor a picture`);
    const imageKey = `images/${coin}`;
    await c.env.METADATA_BUCKET.put(imageKey, picture.bytes, { httpMetadata: { contentType: picture.contentType } });
    const [record] = await db
      .insert(launchMetadata)
      .values({
        chain: f.chain, id: coin, creator, name: f.name, symbol: f.symbol, description: f.description, imageKey, imageContentType: picture.contentType,
        website: f.website ?? null, x: f.x ?? null, telegram: f.telegram ?? null, discord: f.discord ?? null, tiktok: f.tiktok ?? null,
        instagram: f.instagram ?? null, youtube: f.youtube ?? null, imageHash: picture.hash,
      })
      .returning();
    // Signed now, so the coin's permanent address is known before it launches; uploaded only once the launch has landed.
    ({ metadataUri } = await signMetadataItems(db, c.env.METADATA_BUCKET, cfg, operationsKey(c.env), record!, picture));
  }

  const body: PreparedEvmLaunch = { chain: f.chain, coin, pool, salt, metadataUri, ...step, terms, firstBuy: firstBuy && firstBuyToContract(firstBuy) };
  return c.json(body);
}

/** Runs a launch-mode check and turns its refusal into a 400 with its reason; anything else stays what it was. */
function inWords<T>(check: () => T): T {
  try {
    return check();
  } catch (e) {
    if (e instanceof LaunchModeError) throw new HTTPException(400, { message: e.message });
    throw e;
  }
}
