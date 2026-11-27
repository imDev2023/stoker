// #253: launching on an EVM chain through the API, on the test stack's fork of Robinhood Chain. Each test asks the API
// what a wallet would ask, sends exactly what it answers with a real key, and reads the result back from the chain.
// The fork needs ROBINHOOD_RPC_URL; without it the stack has no EVM side and these tests skip by name.
import { describe, expect, inject, test } from "vitest";
import { erc20Abi, parseAbi, type Address, type Hex } from "viem";
import { LaunchList } from "@launchpad/contract";
import { NATIVE, ROBINHOOD_CHAIN, stokerFactoryAbi, stokerHookAbi } from "@launchpad/evm";
import { env, launchedCoin, uniqueTag } from "./client";
import { balanceOf, clients, evm, evmWallet, launchCoin, listQuote, runIndexer } from "./evm";
import {
  AAPL, check, coinPage, CRWD, delistQuote, fundWith, launchedIn, launchOptions, launchQuote, listCrwd, listingOnChain, NVDA, optionsListing, ownName, prepared,
  quoted, refusal, report, send, signTypedData, USDG,
} from "./evm-launch-helpers";

const hasEvm = inject("harness").evm !== null;
const WEEK = 7 * 86_400;
const SUPPLY = 10n ** 30n;

/** `ceil(amount x bps / 10,000)`, as the hook takes a fee of a known gross. */
const feeOf = (amount: bigint, bps: bigint) => (amount * bps + 9_999n) / 10_000n;

const termsOf = (pool: string) => clients().public.readContract({ address: evm()!.hook, abi: stokerHookAbi, functionName: "termsOf", args: [pool as Hex] });

/** Prepares a launch, sends it as the wallet would and reads what landed. */
async function launchThroughApi(creator: { key: Hex; address: Address }, form: Parameters<typeof prepared>[0]) {
  const p = await prepared(form);
  expect(p.step).toBe("launch");
  const receipt = await send(creator, p.transaction!);
  return { p, receipt, launched: launchedIn(receipt) };
}

/** The launch's gas: never more than the limit the API gave, and close to what it said the launch would use. */
function expectGasWithin(receipt: { gasUsed: bigint }, p: { transaction: { gas: string } | null; cost: { gas: string; gasPrice: string; fee: string } }) {
  expect(receipt.gasUsed).toBeLessThanOrEqual(BigInt(p.transaction!.gas));
  expect(BigInt(p.transaction!.gas)).toBe((BigInt(p.cost.gas) * 125n) / 100n);
  const ratio = Number(receipt.gasUsed) / Number(p.cost.gas);
  expect(ratio).toBeGreaterThan(0.8);
  expect(ratio).toBeLessThanOrEqual(1.02);
  expect(BigInt(p.cost.fee)).toBe(BigInt(p.cost.gas) * BigInt(p.cost.gasPrice));
}

/**
 * A cost said before the First Buy could be tried (the launch without it and the measured allowance, `FIRST_BUY_GAS`):
 * not under what the launch then used, and not far over it.
 */
function expectGasForeseen(receipt: { gasUsed: bigint }, said: { cost: { gas: string } }) {
  const ratio = Number(receipt.gasUsed) / Number(said.cost.gas);
  expect(ratio).toBeGreaterThan(0.75);
  expect(ratio).toBeLessThanOrEqual(1);
}

describe.skipIf(!hasEvm)("EVM launch: what a chain offers, and what a launch would buy and cost", () => {
  test("the launch options are the chain's own, with only the assets its registry lists, the native asset first", async () => {
    await listCrwd();
    const o = await optionsListing(CRWD);
    const e = evm()!;
    const explorer = ROBINHOOD_CHAIN.explorer;
    expect(o).toMatchObject({
      chain: "robinhood", name: "Robinhood Chain", chainId: 4663, explorer, stockName: "Stock Tokens", native: { symbol: "ETH", name: "Ether", decimals: 18 },
      supply: SUPPLY.toString(), decimals: 18, platformFeeBps: 100, openingFee: { startBps: 9_900, seconds: 20 }, taxRatesBps: [100, 200, 300, 400, 500],
      shareStepsBps: [0, 1_000, 2_500, 5_000], sharesMaxBps: 5_000, payoutAssets: ["coin", "quote"],
      creatorLock: { maxBps: 2_000, minSeconds: WEEK, maxPartSeconds: 4 * 365 * 86_400 }, destinations: ["wallet"],
    });
    // What a wallet that has never met the chain is given to add it: the public RPC, never the API's own.
    expect(o.wallet).toEqual({
      chainId: "0x1237", chainName: "Robinhood Chain", nativeCurrency: { symbol: "ETH", name: "Ether", decimals: 18 }, rpcUrls: [ROBINHOOD_CHAIN.walletRpcUrl],
      blockExplorerUrls: [explorer],
    });
    expect(o.contracts).toEqual({ factory: e.factory, hook: e.hook, registry: e.registry, taxVault: e.taxVault, source: `${explorer}/address/${e.factory}?tab=contract` });

    // Each asset's Listing is the registry's own, as it stands on the shared fork: the start price as whole Quote Asset
    // for a whole coin, and the Opening Value, the start price times the whole supply in raw units (about 1.67 ETH on the
    // stack's native Listing).
    const listingOf = async (asset: Address) => {
      const onChain = await listingOnChain(asset);
      const rawPrice = 1.0001 ** onChain.startTick;
      return { onChain, rawPrice, figures: { graduationMultiple: onChain.graduationMultiple, referrerFeeCapBps: onChain.referrerFeeCapBps } };
    };
    const [native, ...others] = o.quotes;
    const nativeListing = await listingOf(NATIVE);
    expect(native).toMatchObject({ chain: "robinhood", mint: NATIVE, native: true, symbol: "ETH", decimals: 18, category: "native", multiplier: null, listing: nativeListing.figures });
    expect(native!.listing.startPrice / nativeListing.rawPrice).toBeCloseTo(1, 12);
    expect(Number(BigInt(native!.listing.openingValue)) / (nativeListing.rawPrice * 1e30)).toBeCloseTo(1, 9);
    // A Stock Token is one by its multiplier, read from its contract.
    const multiplier = await clients().public.readContract({ address: CRWD, abi: parseAbi(["function uiMultiplier() view returns (uint256)"]), functionName: "uiMultiplier" });
    const crwd = o.quotes.find((q) => q.mint === CRWD);
    const crwdListing = await listingOf(CRWD);
    expect(crwd).toMatchObject({ native: false, symbol: "CRWD", decimals: 18, category: "tokenized_stock", multiplier: multiplier.toString(), listing: crwdListing.figures });
    expect(Number(BigInt(crwd!.listing.openingValue)) / (crwdListing.rawPrice * 1e30)).toBeCloseTo(1, 9);
    expect(others.every((q) => !q.native)).toBe(true);
    // A candidate the registry does not list is never offered: the registry alone gates a Launch.
    for (const candidate of [AAPL, NVDA, USDG]) {
      if (!(await listingOnChain(candidate)).listed) expect(o.quotes.map((q) => q.mint)).not.toContain(candidate);
    }

    expect((await fetch(`${env().apiUrl}/v1/chains/solana/launch-options`)).status).toBe(404);
    expect((await fetch(`${env().apiUrl}/v1/chains/nowhere/launch-options`)).status).toBe(400);
  });

  test("a launch quote says what a First Buy buys and what the launch costs, and refuses what the chain would", async () => {
    const creator = await evmWallet();
    const amount = 10n ** 16n;
    const q = await quoted({ quote: NATIVE, creator: creator.address, firstBuy: amount.toString() });
    expect(q).toMatchObject({ chain: "robinhood", quote: { mint: NATIVE, native: true }, firstBuy: { amountIn: amount.toString(), fees: { platform: feeOf(amount, 100n).toString(), tax: "0" } } });
    expect(BigInt(q.firstBuy!.coinsOut)).toBeGreaterThan(0n);
    expect(q.cost.value).toBe(amount.toString());
    expect(BigInt(q.cost.fee)).toBe(BigInt(q.cost.gas) * BigInt(q.cost.gasPrice));
    // A tax comes out of the First Buy before it reaches the pool, and a Creator Lock leaves less in the seed: fewer coins either way.
    const taxed = await quoted({ quote: NATIVE, firstBuy: amount.toString(), taxBps: "500" });
    expect(taxed.firstBuy!.fees.tax).toBe(feeOf(amount, 500n).toString());
    expect(BigInt(taxed.firstBuy!.coinsOut)).toBeLessThan(BigInt(q.firstBuy!.coinsOut));
    const locked = await quoted({ quote: NATIVE, firstBuy: amount.toString(), lockBps: "2000" });
    expect(BigInt(locked.firstBuy!.coinsOut)).toBeLessThan(BigInt(q.firstBuy!.coinsOut));
    // A lock costs the launch a contract of its own.
    expect(BigInt(locked.cost.gas)).toBeGreaterThan(BigInt(q.cost.gas));
    // With no First Buy there is none to quote and nothing sent with the launch.
    const bare = await quoted({ quote: NATIVE });
    expect(bare.firstBuy).toBeNull();
    expect(bare.cost.value).toBe("0");
    expect(BigInt(bare.cost.gas)).toBeLessThan(BigInt(q.cost.gas));

    // An asset nobody listed: a coin of ours, which is an ERC-20 like any other, and an address with no contract at all.
    const stranger = await launchCoin(creator);
    for (const quote of [stranger.coin, "0x00000000000000000000000000000000000000Aa"]) {
      const unlisted = await launchQuote({ quote });
      expect(unlisted.status).toBe(400);
      expect(await unlisted.json()).toEqual({ error: "That asset isn't a Quote Asset on Robinhood Chain. Choose one from the list." });
    }
    const dust = await launchQuote({ quote: NATIVE, firstBuy: "1" });
    expect(dust.status).toBe(400);
    expect(await dust.json()).toEqual({ error: "The first buy is too small to get any coins. Enter a larger amount." });
    const whole = await launchQuote({ quote: NATIVE, firstBuy: (10n ** 60n).toString() });
    expect(whole.status).toBe(400);
    expect(await whole.json()).toEqual({ error: "A first buy can't take every coin in the pool. Enter a smaller amount." });
    expect((await launchQuote({ quote: NATIVE, taxBps: "150" })).status).toBe(400);
    expect((await launchQuote({ quote: "nothing" })).status).toBe(400);
  });
});

describe.skipIf(!hasEvm)("EVM launch: prepared by the API, sent by the Creator's wallet", () => {
  test("a launch with a First Buy in the native asset is one transaction, and the wallet receives the coins the API said, to the wei", async () => {
    const creator = await evmWallet();
    const amount = 3n * 10n ** 16n;
    const names = ownName();
    const quote = await quoted({ quote: NATIVE, creator: creator.address, firstBuy: amount.toString() });
    const ethBefore = await balanceOf(NATIVE, creator.address);
    const { p, receipt, launched } = await launchThroughApi(creator, { creator: creator.address, ...names, firstBuy: amount.toString() });

    expect(p).toMatchObject({
      chain: "robinhood", step: "launch", permit: null, permitDeadline: null, transaction: { chainId: 4663, to: evm()!.factory, value: amount.toString() },
      terms: { type: "standard", taxBps: 0, burnShareBps: 0, liquidityShareBps: 0, payoutAsset: null, earningsDestination: "wallet", creatorLock: null },
      firstBuy: { amountIn: amount.toString(), fees: { platform: feeOf(amount, 100n).toString(), tax: "0" } }, cost: { value: amount.toString() },
    });
    // The coin exists at the address the API gave before it was sent, with the form's name and ticker, in the pool it named.
    expect(launched).toMatchObject({ coin: p.coin, poolId: p.pool, creator: creator.address, quote: NATIVE, firstBuy: amount });
    const [name, symbol] = await Promise.all([
      clients().public.readContract({ address: p.coin as Address, abi: erc20Abi, functionName: "name" }),
      clients().public.readContract({ address: p.coin as Address, abi: erc20Abi, functionName: "symbol" }),
    ]);
    expect([name, symbol]).toEqual([names.name, names.symbol]);
    // The First Buy, to the wei: what the factory's event says it bought, what the wallet holds, and what the form's quote said.
    expect(launched.firstBuyCoins.toString()).toBe(p.firstBuy!.coinsOut);
    expect((await balanceOf(p.coin as Address, creator.address)).toString()).toBe(p.firstBuy!.coinsOut);
    expect(quote.firstBuy).toEqual(p.firstBuy);
    // One transaction: the wallet paid the First Buy and its gas, and nothing else.
    expect(ethBefore - (await balanceOf(NATIVE, creator.address))).toBe(amount + receipt.gasUsed * receipt.effectiveGasPrice);
    expectGasWithin(receipt, p);
    // The form's own estimate, made before the First Buy could be tried, was not under either.
    expectGasForeseen(receipt, quote);
    expect((await termsOf(p.pool)).launchType).toBe(0);
  });

  test("a launch with a First Buy in a Stock Token takes a signature and a transaction, by the asset's own permit", async () => {
    await listCrwd();
    const creator = await evmWallet();
    const amount = 4n * 10n ** 16n;
    await fundWith(CRWD, creator.address, 10n ** 17n);
    const form = { creator: creator.address, quote: CRWD, ...ownName(), firstBuy: amount.toString() };

    // The first answer is a permit to sign: no transaction, nothing spent, the factory as the spender of exactly the First Buy.
    const first = await prepared(form);
    expect(first).toMatchObject({ step: "permit", transaction: null, firstBuy: { amountIn: amount.toString() }, cost: { value: "0" } });
    const now = (await clients().public.getBlock()).timestamp;
    expect(BigInt(first.permitDeadline!) - now).toBeGreaterThan(1_700n);
    expect(BigInt(first.permitDeadline!) - now).toBeLessThanOrEqual(1_800n);
    expect(first.permit).toMatchObject({
      primaryType: "Permit", domain: { chainId: 4663, verifyingContract: CRWD },
      message: { owner: creator.address, spender: evm()!.factory, value: amount.toString(), deadline: first.permitDeadline },
    });
    const signature = await signTypedData(creator, first.permit!);

    // The second call carries the salt, the deadline and the signature back, and needs no picture: the launch itself.
    const second = await prepared({ ...form, salt: first.salt, permitDeadline: first.permitDeadline!, permitSignature: signature, image: null });
    expect(second).toMatchObject({ step: "launch", coin: first.coin, pool: first.pool, salt: first.salt, metadataUri: first.metadataUri, permit: null, transaction: { to: evm()!.factory, value: "0" } });
    expect(second.firstBuy).toEqual(first.firstBuy);
    const crwdBefore = await balanceOf(CRWD, creator.address);
    const receipt = await send(creator, second.transaction!);
    // What the first answer said the launch would cost, before the First Buy could be tried, was not under.
    expectGasForeseen(receipt, first);
    const launched = launchedIn(receipt);
    expect(launched).toMatchObject({ coin: first.coin, poolId: first.pool, quote: CRWD, firstBuy: amount });
    // To the wei, in whichever order the coin's address put the pool's two currencies.
    expect(launched.firstBuyCoins.toString()).toBe(second.firstBuy!.coinsOut);
    expect((await balanceOf(first.coin as Address, creator.address)).toString()).toBe(second.firstBuy!.coinsOut);
    expect(crwdBefore - (await balanceOf(CRWD, creator.address))).toBe(amount);
    // The permit was for exactly the First Buy: nothing is left for the factory to take.
    expect(await clients().public.readContract({ address: CRWD, abi: erc20Abi, functionName: "allowance", args: [creator.address, evm()!.factory] })).toBe(0n);
    expectGasWithin(receipt, second);

    // A permit signed for one launch does not serve another amount, and an expired one is refused in words.
    const other = { creator: creator.address, quote: CRWD, ...ownName(), firstBuy: (amount / 2n).toString() };
    const again = await prepared(other);
    expect(again.step).toBe("permit");
    const reused = await refusal({ ...other, salt: again.salt, permitDeadline: first.permitDeadline!, permitSignature: signature, image: null });
    expect(reused.status).toBe(400);
    expect(reused.error).toContain("That permit doesn't let the factory take the first buy");
    const expired = await refusal({ ...other, salt: again.salt, permitDeadline: "1", permitSignature: signature, image: null });
    expect(expired).toMatchObject({ status: 400, error: "That permit has expired. Prepare the launch again and sign the new one." });
    const half = await refusal({ ...other, salt: again.salt, permitSignature: signature, image: null });
    expect(half).toMatchObject({ status: 400, error: "A permit's signature and its deadline come together. Send both, or neither." });
  });

  test("a First Buy in an asset with no permit takes an approval of exactly the First Buy, then the launch", async () => {
    // A coin of ours is a plain ERC-20 with no permit: listed on the fork's registry, it is a Quote Asset like any other.
    const creator = await evmWallet();
    const plain = await launchCoin(creator, { firstBuy: 10n ** 17n });
    await listQuote(plain.coin, 0);
    const held = await balanceOf(plain.coin, creator.address);
    const amount = held / 4n;
    const form = { creator: creator.address, quote: plain.coin, ...ownName(), firstBuy: amount.toString() };

    const first = await prepared(form);
    expect(first).toMatchObject({ step: "approve", permit: null, permitDeadline: null, transaction: { to: plain.coin, value: "0" } });
    await send(creator, first.transaction!);
    expect(await clients().public.readContract({ address: plain.coin, abi: erc20Abi, functionName: "allowance", args: [creator.address, evm()!.factory] })).toBe(amount);

    const second = await prepared({ ...form, salt: first.salt, image: null });
    expect(second).toMatchObject({ step: "launch", coin: first.coin, pool: first.pool, transaction: { to: evm()!.factory, value: "0" } });
    const receipt = await send(creator, second.transaction!);
    expectGasForeseen(receipt, first);
    const launched = launchedIn(receipt);
    expect(launched.firstBuyCoins.toString()).toBe(second.firstBuy!.coinsOut);
    expect((await balanceOf(first.coin as Address, creator.address)).toString()).toBe(second.firstBuy!.coinsOut);
    expect(held - (await balanceOf(plain.coin, creator.address))).toBe(amount);
    expectGasWithin(receipt, second);

    // The registry alone gates a Launch. While it lists the asset the form offers it; once the Admin delists it, it
    // leaves the form within the seconds the options are kept, and a launch against it is refused in words at once.
    expect((await optionsListing(plain.coin)).quotes.find((q) => q.mint === plain.coin)).toMatchObject({ native: false, category: "community", multiplier: null });
    await delistQuote(plain.coin);
    const unlisted = { status: 400, error: "That asset isn't a Quote Asset on Robinhood Chain. Choose one from the list." };
    expect(await refusal({ creator: creator.address, quote: plain.coin })).toMatchObject(unlisted);
    await expect.poll(async () => (await launchOptions()).quotes.map((q) => q.mint), { timeout: 15_000, interval: 1_000 }).not.toContain(plain.coin);
    const quote = await launchQuote({ quote: plain.coin });
    expect([quote.status, await quote.json()]).toEqual([400, { error: unlisted.error }]);
  });

  test("a standard, a Reward and a Stoke Launch each land with the terms the API answered", async () => {
    const creator = await evmWallet();
    const amount = 10n ** 16n;

    // A standard Launch with no First Buy: nothing is sent with it, and the wallet holds no coin.
    const standard = await launchThroughApi(creator, { creator: creator.address });
    expect(standard.p).toMatchObject({ firstBuy: null, cost: { value: "0" }, transaction: { value: "0" }, terms: { type: "standard" } });
    expect(standard.launched).toMatchObject({ firstBuy: 0n, firstBuyCoins: 0n });
    expect(await balanceOf(standard.p.coin as Address, creator.address)).toBe(0n);
    expect(await termsOf(standard.p.pool)).toMatchObject({ registered: true, launchType: 0, taxBps: 0, burnShareBps: 0, liquidityShareBps: 0, payoutAsset: 0, creatorDestination: creator.address });
    expectGasWithin(standard.receipt, standard.p);

    // A Reward Launch: its tax comes out of the First Buy beside the Platform Fee, and its shares and Payout Asset are the form's.
    const reward = await launchThroughApi(creator, {
      creator: creator.address, firstBuy: amount.toString(), rewardTax: "300", rewardPayout: "quote", rewardBurn: "1000", rewardLiquidity: "2500",
    });
    expect(reward.p.terms).toEqual({ type: "reward", taxBps: 300, burnShareBps: 1_000, liquidityShareBps: 2_500, payoutAsset: "quote", earningsDestination: "wallet", creatorLock: null });
    expect(reward.p.firstBuy!.fees).toEqual({ platform: feeOf(amount, 100n).toString(), tax: feeOf(amount, 300n).toString() });
    expect(reward.launched.firstBuyCoins.toString()).toBe(reward.p.firstBuy!.coinsOut);
    expect((await balanceOf(reward.p.coin as Address, creator.address)).toString()).toBe(reward.p.firstBuy!.coinsOut);
    expect(await termsOf(reward.p.pool)).toMatchObject({ launchType: 1, taxBps: 300, burnShareBps: 1_000, liquidityShareBps: 2_500, payoutAsset: 0 });
    expectGasWithin(reward.receipt, reward.p);
    // The Payout Asset is the coin unless the form says otherwise, as on Solana.
    const inCoin = await launchThroughApi(creator, { creator: creator.address, rewardTax: "100" });
    expect(inCoin.p.terms).toMatchObject({ type: "reward", taxBps: 100, payoutAsset: "coin", burnShareBps: 0, liquidityShareBps: 0 });
    expect(await termsOf(inCoin.p.pool)).toMatchObject({ launchType: 1, taxBps: 100, payoutAsset: 1 });

    // A Stoke Launch: its whole tax is Support Liquidity, which the factory writes as the whole share.
    const stoke = await launchThroughApi(creator, { creator: creator.address, firstBuy: amount.toString(), liquidityTax: "200" });
    expect(stoke.p.terms).toEqual({ type: "liquidity", taxBps: 200, burnShareBps: 0, liquidityShareBps: 10_000, payoutAsset: null, earningsDestination: "wallet", creatorLock: null });
    expect(stoke.p.firstBuy!.fees.tax).toBe(feeOf(amount, 200n).toString());
    expect(stoke.launched.firstBuyCoins.toString()).toBe(stoke.p.firstBuy!.coinsOut);
    expect(await termsOf(stoke.p.pool)).toMatchObject({ launchType: 2, taxBps: 200, burnShareBps: 0, liquidityShareBps: 10_000, payoutAsset: 0 });
  });

  test("a Creator Lock of a fifth is held out of the seed, and the First Buy against the smaller seed is still exact", async () => {
    const creator = await evmWallet();
    const amount = 2n * 10n ** 16n;
    const { p, receipt, launched } = await launchThroughApi(creator, {
      creator: creator.address, firstBuy: amount.toString(), lockBps: "2000", lockCliffSeconds: String(WEEK), lockUnlockSeconds: String(3 * WEEK),
    });
    expect(p.terms.creatorLock).toEqual({ bps: 2_000, cliffSeconds: WEEK, unlockSeconds: 3 * WEEK });
    expect(launched.firstBuyCoins.toString()).toBe(p.firstBuy!.coinsOut);
    expect((await balanceOf(p.coin as Address, creator.address)).toString()).toBe(p.firstBuy!.coinsOut);
    const lock = await clients().public.readContract({ address: evm()!.factory, abi: stokerFactoryAbi, functionName: "creatorLockOf", args: [p.pool as Hex] });
    expect(await balanceOf(p.coin as Address, lock)).toBe(SUPPLY / 5n);
    expectGasWithin(receipt, p);
    // Fewer coins than the same First Buy gets from a whole seed.
    const whole = await quoted({ quote: NATIVE, firstBuy: amount.toString() });
    expect(BigInt(p.firstBuy!.coinsOut)).toBeLessThan(BigInt(whole.firstBuy!.coinsOut));
  });

  test("a launch the chain would refuse is refused before the wallet is asked for anything, in words", async () => {
    const creator = await evmWallet(1n);
    const base = { creator: creator.address };
    const says = async (form: Parameters<typeof refusal>[0], status: number, error: string | RegExp) => {
      const r = await refusal(form);
      expect([r.status, r.error], JSON.stringify(form)).toEqual([status, expect.stringMatching(error)]);
      return r;
    };

    // The form's fields, and the chain.
    expect(await says({ creator: "0x1234" as Address }, 400, /^invalid launch fields$/)).toHaveProperty("details");
    await says({ ...base, chain: "nowhere" }, 400, /^invalid launch fields$/);
    await says({ ...base, symbol: "not a ticker" }, 400, /^invalid launch fields$/);
    // The chain's own rules for a name, with the field and the sentence for the form.
    const named = await says({ ...base, name: "Robinhood Moon" }, 400, /^A coin's name can't use the name Robinhood/);
    expect(named.refusals).toEqual([{ field: "name", reason: named.error }]);
    // The picture.
    await says({ ...base, image: null }, 400, /^an image is required$/);
    await says({ ...base, image: new TextEncoder().encode("not a picture at all") }, 400, /^image must be PNG, JPEG, WebP or GIF$/);
    // An asset the registry does not list: a coin of ours nobody listed, and an address with no contract at all.
    const unlisted = /^That asset isn't a Quote Asset on Robinhood Chain\. Choose one from the list\.$/;
    await says({ ...base, quote: (await launchCoin(creator)).coin }, 400, unlisted);
    await says({ ...base, quote: "0x00000000000000000000000000000000000000Bb" }, 400, unlisted);
    // The terms.
    await says({ ...base, rewardTax: "100", liquidityTax: "100" }, 400, /never both/);
    await says({ ...base, rewardPayout: "quote" }, 400, /^A payout asset is only for a Reward Launch/);
    await says({ ...base, rewardBurn: "1000" }, 400, /^A Reward Burn is only for a Reward Launch/);
    await says({ ...base, rewardTax: "100", rewardBurn: "5000", rewardLiquidity: "2500" }, 400, /^Holders keep at least half of every reward/);
    await says({ ...base, liquidityTax: "100", rewardBurn: "1000" }, 400, /has no Reward Burn/);
    await says({ ...base, earningsDestination: "holders" }, 400, /^On Robinhood Chain a Creator's earnings go to the Creator's own wallet for now/);
    await says({ ...base, lockBps: "2500", lockCliffSeconds: String(WEEK) }, 400, /^A Creator Lock can hold 20% of the supply at most/);
    await says({ ...base, lockBps: "1000", lockCliffSeconds: "86400" }, 400, /^A Creator Lock lasts 7 days at least/);
    await says({ ...base, lockBps: "1000", lockCliffSeconds: String(5 * 365 * 86_400) }, 400, /can each be 1460 days at most/);
    await says({ ...base, lockCliffSeconds: String(WEEK) }, 400, /^A lock's schedule needs coins to lock/);
    // The First Buy: one too small to buy anything, and one the wallet cannot pay, with or without the network's fee.
    await says({ ...base, firstBuy: "1" }, 400, /^The first buy is too small to get any coins/);
    await says({ ...base, firstBuy: (2n * 10n ** 18n).toString() }, 400, /^Your wallet doesn't hold enough ETH for this first buy and the network's fee/);
    await says({ ...base, firstBuy: (10n ** 18n).toString() }, 400, /^Your wallet doesn't hold enough ETH for this first buy and the network's fee/);
    await listCrwd();
    await says({ ...base, quote: CRWD, firstBuy: "1000000" }, 400, /^Your wallet doesn't hold enough CRWD for this first buy\. Add CRWD or buy less\.$/);
    // A later call for a launch the API never prepared.
    await says({ ...base, salt: `0x${"ab".repeat(32)}`, image: null }, 400, /^This launch wasn't prepared here with that salt/);

    // A coin that has landed cannot be launched again: the same launch prepared once more is refused as taken.
    const form = { ...base, ...ownName() };
    const first = await prepared(form);
    await send(creator, first.transaction!);
    await says({ ...form, salt: first.salt, image: null }, 409, /^This coin has already been launched/);
  });
});

describe.skipIf(!hasEvm)("EVM launch: the coin on the site", () => {
  test("a reported launch turns from pending to indexed, and the coin's page shows what the form held", async () => {
    const creator = await evmWallet();
    const names = ownName();
    const { p, receipt } = await launchThroughApi(creator, {
      creator: creator.address, ...names, description: "Forged where the fork was hottest", website: "https://example.com/forge", x: "https://x.com/forgecoin",
      telegram: "https://t.me/forgecoin", firstBuy: (10n ** 16n).toString(),
    });
    // Before the Indexer has read it the coin has no page, and its metadata is nowhere yet.
    expect((await fetch(`${env().apiUrl}/v1/launches/${p.coin}`)).status).toBe(404);
    expect((await fetch(p.metadataUri)).status).toBe(404);

    // The chain has not made the transaction final yet: the report says so, and nothing is read.
    expect(await report(receipt.transactionHash)).toEqual({ status: 200, body: { chain: "robinhood", status: "pending", block: Number(receipt.blockNumber) } });
    await clients().test.mine({ blocks: ROBINHOOD_CHAIN.finalityDepth });
    // Final now: the report runs the chain's Indexer once, and the same report asked again answers from what is written.
    const indexed = { status: 200, body: { chain: "robinhood", status: "indexed", block: Number(receipt.blockNumber) } };
    expect(await report(receipt.transactionHash)).toEqual(indexed);
    expect(await report(receipt.transactionHash)).toEqual(indexed);

    const coin = await coinPage(p.coin);
    expect(coin).toMatchObject({
      chain: "robinhood", mint: p.coin, pool: p.pool, creator: creator.address, name: names.name, symbol: names.symbol, metadataUri: p.metadataUri,
      description: "Forged where the fork was hottest", image: `${env().apiUrl}/metadata/${p.coin}/image`, createdSignature: receipt.transactionHash, copyOf: null,
      links: { website: "https://example.com/forge", x: "https://x.com/forgecoin", telegram: "https://t.me/forgecoin", discord: null },
    });
    const picture = await fetch(coin.image!);
    expect([picture.status, picture.headers.get("content-type")]).toEqual([200, "image/png"]);

    // Its permanent metadata is uploaded once the launch has landed, like a Solana coin's, and names its chain by its id.
    await expect.poll(async () => (await fetch(p.metadataUri)).status, { timeout: 30_000 }).toBe(200);
    const document = (await (await fetch(p.metadataUri)).json()) as { name: string; symbol: string; description: string; image: string; extensions: Record<string, string> };
    expect(document).toMatchObject({ name: names.name, symbol: names.symbol, description: "Forged where the fork was hottest", extensions: { website: "https://example.com/forge", twitter: "https://x.com/forgecoin" } });
    expect((await fetch(document.image)).status).toBe(200);
    const held = (await (await fetch(`${env().turbo.url}/stand-in/items`)).json()) as { id: string; tags: { name: string; value: string }[] }[];
    const item = held.find((i) => p.metadataUri.endsWith(`/${i.id}`));
    expect(item!.tags).toEqual(expect.arrayContaining([{ name: "Launch-Mint", value: p.coin }, { name: "Chain-Id", value: "4663" }]));

    // A hash nobody sent, one that is no hash, and a transaction with nothing of ours in it.
    expect((await report(`0x${"12".repeat(32)}`)).status).toBe(404);
    expect((await fetch(`${env().apiUrl}/v1/transactions/0x1234?chain=robinhood`, { method: "POST" })).status).toBe(400);
    const plain = await clients().public.waitForTransactionReceipt({ hash: await clients().wallet(creator.key).sendTransaction({ to: creator.address, value: 1n }) });
    await clients().test.mine({ blocks: ROBINHOOD_CHAIN.finalityDepth });
    expect((await report(plain.transactionHash)).body).toEqual({ chain: "robinhood", status: "indexed", block: Number(plain.blockNumber) });
  });

  test("a coin paired with a Stock Token carries the asset exactly as the launch options offered it", async () => {
    await listCrwd();
    const options = await optionsListing(CRWD);
    const creator = await evmWallet();
    const { p } = await launchThroughApi(creator, { creator: creator.address, quote: CRWD });
    await runIndexer();
    const coin = await coinPage(p.coin);
    const offered = options.quotes.find((q) => q.mint === CRWD)!;
    expect({ ...coin.quote, native: offered.native, listing: offered.listing }).toEqual(offered);
  });

  test("the board and its Quote Assets take the chains a site shows", async () => {
    const creator = await evmWallet();
    const { p } = await launchThroughApi(creator, { creator: creator.address });
    await runIndexer();
    const solana = await launchedCoin();
    const board = async (query: string) => LaunchList.parse(await (await fetch(`${env().apiUrl}/v1/launches?limit=100&${query}`)).json()).launches;

    const solanaOnly = await board("chains=solana");
    expect(solanaOnly.map((l) => l.mint)).toContain(solana.mint);
    expect(solanaOnly.every((l) => l.chain === "solana")).toBe(true);
    const both = (await board("chains=solana,robinhood")).map((l) => l.mint);
    expect(both).toEqual(expect.arrayContaining([solana.mint, p.coin]));
    expect((await board("chains=robinhood")).every((l) => l.chain === "robinhood")).toBe(true);
    // With one chain asked for as well, only that chain when the site shows it.
    expect(await board("chains=solana&chain=robinhood")).toEqual([]);
    expect((await fetch(`${env().apiUrl}/v1/launches?chains=solana,nowhere`)).status).toBe(400);

    const quotes = async (query: string) => ((await (await fetch(`${env().apiUrl}/v1/launches/quotes?${query}`)).json()) as { quotes: { chain: string; mint: string }[] }).quotes;
    expect((await quotes("chains=solana")).every((q) => q.chain === "solana")).toBe(true);
    expect((await quotes("chains=solana")).length).toBeGreaterThan(0);
    const everyChain = await quotes("chains=solana,robinhood");
    expect(everyChain.map((q) => q.chain)).toEqual(expect.arrayContaining(["solana", "robinhood"]));
    expect(everyChain).toEqual(await quotes(""));
    expect((await quotes("chains=robinhood")).every((q) => q.chain === "robinhood")).toBe(true);
    expect(await quotes("chains=solana&chain=robinhood")).toEqual([]);
    expect((await fetch(`${env().apiUrl}/v1/launches/quotes?chains=nowhere`)).status).toBe(400);
  });
});

describe.skipIf(!hasEvm)("EVM launch: Robinhood Chain's rules for a coin's text", () => {
  const refusals = async (fields: Parameters<typeof check>[0]) => (await check({ chain: "robinhood", ...fields })).refusals;

  test("the chain's name, its short form, HOOD and a Stock Token's ticker are refused in any spelling, and ordinary words are not", async () => {
    await listCrwd();
    await optionsListing(CRWD);
    const refused: [Parameters<typeof check>[0], string, RegExp][] = [
      // The chain's name in a coin's name: any case, spacing or punctuation, digits for letters, letters of other scripts.
      [{ name: "Robinhood Cat" }, "name", /^A coin's name can't use the name Robinhood or a spelling that looks like it/],
      [{ name: "robin hood" }, "name", /the name Robinhood/],
      [{ name: "ROBIN-HOOD CHAIN" }, "name", /the name Robinhood/],
      [{ name: "R0b1n H00d" }, "name", /the name Robinhood/],
      [{ name: "R.o.b.i.n.h.o.o.d" }, "name", /the name Robinhood/],
      // Greek omicrons for the three o's.
      [{ name: "Rοbinhοοd" }, "name", /the name Robinhood/],
      [{ name: "MyRobinhoodCoin" }, "name", /the name Robinhood/],
      // The short form of the chain's name.
      [{ name: "Hood Chain Dog" }, "name", /^A coin's name can't use "Hood Chain"/],
      [{ name: "the hood-chain" }, "name", /"Hood Chain"/],
      // HOOD alone as a name, and "Robinhood Token", which is how every Stock Token is named.
      [{ name: "HOOD" }, "name", /^A coin on Robinhood Chain can't be named HOOD alone/],
      [{ name: "$hood" }, "name", /named HOOD alone/],
      [{ name: "Tesla • Robinhood Token" }, "name", /^A coin's name can't contain "Robinhood Token"/],
      // The ticker HOOD, with or without its dollar sign, and a Stock Token's own ticker.
      [{ symbol: "HOOD" }, "symbol", /^The ticker HOOD can't be used on Robinhood Chain/],
      [{ symbol: "$hood" }, "symbol", /The ticker HOOD/],
      [{ symbol: "H00D" }, "symbol", /The ticker HOOD/],
      [{ symbol: "CRWD" }, "symbol", /^CRWD is the ticker of a Stock Token on Robinhood Chain, which a coin launched there can't take\.$/],
      [{ symbol: "$crwd" }, "symbol", /is the ticker of a Stock Token/],
      [{ symbol: "ROBINHOOD" }, "symbol", /^A ticker can't use the name Robinhood/],
      // The description and each link, named by its own field.
      [{ description: "The official robin-hood coin, backed by nobody" }, "description", /^A coin's description can't use the name Robinhood/],
      [{ links: "https://x.com/robinhoodcat" }, "x", /^An X link can't use the name Robinhood/],
      [{ links: "https://example.com/about\nhttps://t.me/hoodchain" }, "telegram", /^A Telegram link can't use "Hood Chain"/],
      [{ links: "https://robinhood.example.com" }, "website", /^A website link can't use the name Robinhood/],
    ];
    for (const [fields, field, reason] of refused) {
      const found = await refusals(fields);
      expect(found, JSON.stringify(fields)).toEqual([{ field, reason: expect.stringMatching(reason) }]);
      // One plain sentence for the Creator.
      expect(found![0]!.reason).toMatch(/^[A-Z$"][^\n]*\.$/);
    }
    const allowed: Parameters<typeof check>[0][] = [
      { name: "Neighborhood Cat" }, { name: "Childhood" }, { name: "Neighborhood Chain" }, { name: "Robin" }, { name: "Hoodwink" }, { name: "Hood Ornament" },
      { symbol: "HOODIE" }, { symbol: "ROBIN" }, { symbol: "HOODS" }, { symbol: "CRWDX" },
      { description: "A robin sat in the neighborhood, hood up, on a chain-link fence." },
      { links: "https://x.com/childhood\nhttps://example.com/neighborhood-chain\nhttps://t.me/motherhood" },
    ];
    for (const fields of allowed) expect(await refusals(fields), JSON.stringify(fields)).toEqual([]);
    // Every field at once: one refusal a field, in the form's order.
    const all = await refusals({ name: "Robinhood", symbol: "HOOD", description: "robinhood", links: "https://robinhood.example.com" });
    expect(all!.map((r) => r.field)).toEqual(["name", "symbol", "description", "website"]);
  });

  test("Solana has no such rules, and its check answers as it always did", async () => {
    const tag = uniqueTag();
    const solana = await check({ name: `Robinhood ${tag}`, symbol: "HOOD" });
    expect(solana.keys).toEqual(["name", "symbol", "image", "protectionSeconds"]);
    expect(solana).toMatchObject({ name: { status: "free" }, image: null });
    const named = await check({ chain: "solana", name: `Robinhood ${tag}` });
    expect(named.keys).toEqual(["name", "symbol", "image", "protectionSeconds"]);
    // On the EVM chain the same check carries the refusals beside the verdicts.
    const evmCheck = await check({ chain: "robinhood", name: `Plain ${tag}` });
    expect(evmCheck.keys).toEqual(["name", "symbol", "image", "protectionSeconds", "refusals"]);
    expect(evmCheck).toMatchObject({ name: { status: "free" }, refusals: [] });
  });
});
