// #254: the scheduled jobs on an EVM chain, on the test stack's fork of Robinhood Chain. The Keeper makes the Payout
// Calls, a Destination's call and the Tax Vault's calls as anyone could, the Indexer writes the Ledger from what they
// did, revenue and the Platform Net count the chain, the operator sees each key, and an Indexer that stays behind its
// head is alerted. Every test launches and trades as a wallet would; each skips by name when the stack has no fork.
import { afterAll, beforeAll, describe, expect, inject, test } from "vitest";
import { erc20Abi, type Address, type Hex } from "viem";
import { BudgetsPage, EvmKeysPage, LaunchSummary, Revenue } from "@launchpad/contract";
import { NATIVE, stokerHookAbi } from "@launchpad/evm";
import { deploymentOf, freePort, startApi, startRpcStandIn, type RpcStandIn } from "@launchpad/stack";
import { env } from "./client";
import {
  balanceOf, clients, evm, evmWallet, launchCoin, ledgerOf, operatorAlerts, runApiJob, runIndexer, runKeeper, swapExactIn, swapExactOut, type EvmLaunch,
} from "./evm";

const hasEvm = inject("harness").evm !== null;
const operator = () => ({ authorization: `Bearer ${env().operatorToken}` });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function api(path: string, init?: RequestInit): Promise<unknown> {
  const res = await fetch(`${env().apiUrl}${path}`, init);
  if (!res.ok) throw new Error(`${path}: ${res.status} ${await res.text()}`);
  return res.json();
}

/** The Credit the hook holds for `owner` in `asset` now. */
const creditOf = (owner: Address, asset: Address = NATIVE) =>
  clients().public.readContract({ address: evm()!.hook, abi: stokerHookAbi, functionName: "creditOf", args: [owner, asset] });

/** A buy and a sell of what it bought: the coin's price comes back near where it was, and both pay their fees and tax. */
async function roundTrip(trader: { key: Hex; address: Address }, l: EvmLaunch, spend: bigint) {
  await swapExactIn(trader, l, "buy", spend);
  const coins = await clients().public.readContract({ address: l.coin, abi: erc20Abi, functionName: "balanceOf", args: [trader.address] });
  await swapExactIn(trader, l, "sell", coins);
}

describe.skipIf(!hasEvm)("EVM chain: the Keeper's Payout Calls", () => {
  test("after trades and one scheduled run the Creator's wallet holds its share, and the Ledger shows each payment with its chain and transaction", async () => {
    const creator = await evmWallet();
    const trader = await evmWallet();
    const referrer = await evmWallet();
    const l = await launchCoin(creator);
    await swapExactOut(trader, l, "buy", 10n ** 28n, { referrer: referrer.address, bps: 50 });
    await swapExactIn(trader, l, "buy", 10n ** 16n);
    await runIndexer();
    const [owed, referred] = [await creditOf(creator.address), await creditOf(referrer.address)];
    expect(owed).toBeGreaterThan(0n);
    expect(referred).toBeGreaterThan(0n);
    const before = await balanceOf(NATIVE, creator.address);

    const run = await runKeeper();

    // Nobody claimed: the Keeper's call paid the Creator and the referrer, each into their own wallet, the whole Credit.
    expect(await balanceOf(NATIVE, creator.address)).toBe(before + owed);
    expect(await creditOf(creator.address)).toBe(0n);
    expect(await creditOf(referrer.address)).toBe(0n);
    const payouts = run.paid.filter((p) => p.asset === NATIVE).map((p) => p.hash);
    expect(payouts.length).toBeGreaterThan(0);

    const entries = await ledgerOf("chain=robinhood");
    const share = entries.find((e) => e.kind === "creator_credit" && e.destination === creator.address);
    expect(share).toMatchObject({ chain: "robinhood", amount: owed.toString(), source: evm()!.hook, asset: { mint: NATIVE, decimals: 18 }, launch: { mint: l.coin } });
    expect(payouts).toContain(share!.signature);
    expect(entries.find((e) => e.kind === "referrer_fee" && e.destination === referrer.address)).toMatchObject({ amount: referred.toString(), launch: null });
    // The platform's share went to the Admin by the same call, and it is revenue.
    const platform = entries.filter((e) => e.kind === "platform_fee" && e.destination === evm()!.admin.address);
    expect(platform.length).toBeGreaterThan(0);
    expect(platform.every((e) => e.chain === "robinhood" && /^0x[0-9a-f]{64}$/.test(e.signature))).toBe(true);
    // A run with nothing owed sends no Payout Call for it.
    const again = await runKeeper();
    expect(again.paid.filter((p) => p.asset === NATIVE)).toEqual([]);
  }, 240_000);

  test("a Creator the asset refuses is skipped and stays owed, and the run pays everyone else", async () => {
    // A Creator Earnings Destination whose every receipt of ether reverts, as a blocked address refuses a Stock Token.
    const refusing = (await evmWallet(0n)).address;
    await clients().test.setCode({ address: refusing, bytecode: "0x60006000fd" });
    const trader = await evmWallet();
    const paid = await evmWallet();
    const blocked = await launchCoin(await evmWallet(), { destination: refusing });
    const fine = await launchCoin(paid);
    await swapExactIn(trader, blocked, "buy", 10n ** 16n);
    await swapExactIn(trader, fine, "buy", 10n ** 16n);
    await runIndexer();
    const [stuck, owed] = [await creditOf(refusing), await creditOf(paid.address)];
    expect(stuck).toBeGreaterThan(0n);
    const before = await balanceOf(NATIVE, paid.address);

    await runKeeper();

    expect(await creditOf(refusing)).toBe(stuck);
    expect(await balanceOf(NATIVE, paid.address)).toBe(before + owed);
    const entries = await ledgerOf("chain=robinhood&kind=creator_credit");
    expect(entries.some((e) => e.destination === refusing)).toBe(false);
    expect(entries.find((e) => e.destination === paid.address)).toMatchObject({ amount: owed.toString(), launch: { mint: fine.coin } });
  }, 240_000);
});

describe.skipIf(!hasEvm)("EVM chain: the Tax Vault's calls and the Destinations' work", () => {
  let reward: EvmLaunch;
  let stoke: EvmLaunch;
  let burning: EvmLaunch;
  let liquid: EvmLaunch;
  let run: Awaited<ReturnType<typeof runKeeper>>;
  const supplyOf = async (coin: Address) => BigInt(LaunchSummary.parse(await api(`/v1/launches/${coin}`)).supply);
  let supplies: { reward: bigint; burning: bigint };

  beforeAll(async () => {
    const e = evm()!;
    reward = await launchCoin(await evmWallet(), { reward: { taxBps: 300, burnShareBps: 2500, liquidityShareBps: 2500 } });
    stoke = await launchCoin(await evmWallet(), { stoke: { taxBps: 300 } });
    burning = await launchCoin(await evmWallet(), { destination: e.destinations.burn });
    liquid = await launchCoin(await evmWallet(), { destination: e.destinations.liquidity });
    // The Tax Vault buys nothing while a Launch's Opening Fee runs (#246): twenty seconds of the chain's own clock,
    // which follows the wall's on the suite's fork.
    await sleep(21_000);
    const trader = await evmWallet(100n);
    for (const l of [reward, stoke, burning, liquid]) await roundTrip(trader, l, 10n ** 17n);
    await runIndexer();
    supplies = { reward: await supplyOf(reward.coin), burning: await supplyOf(burning.coin) };
    run = await runKeeper();
  }, 300_000);

  test("a Reward Launch's liquidity share and a Stoke Launch's tax are Support Liquidity after a run, and the burn share has lowered the supply, each on the Ledger", async () => {
    expect(run.refused.filter((r) => [reward.coin, stoke.coin].includes(r.subject as Address))).toEqual([]);
    expect(run.support.map((s) => s.coin)).toEqual(expect.arrayContaining([reward.coin, stoke.coin]));
    expect(run.burned.map((s) => s.coin)).toContain(reward.coin);
    const entries = await ledgerOf("chain=robinhood");
    for (const l of [reward, stoke]) {
      const added = entries.find((e) => e.kind === "support_liquidity" && e.launch?.mint === l.coin);
      expect(added, l.coin).toMatchObject({ chain: "robinhood", source: evm()!.taxVault, destination: l.poolId, asset: { mint: NATIVE } });
      expect(BigInt(added!.amount)).toBeGreaterThan(0n);
      expect(run.support.find((s) => s.coin === l.coin)!.hash).toBe(added!.signature);
    }
    const burned = entries.find((e) => e.kind === "reward_burn" && e.launch?.mint === reward.coin);
    expect(burned).toMatchObject({ asset: { mint: reward.coin, decimals: 18 }, source: evm()!.taxVault });
    const coins = BigInt(burned!.amount);
    expect(coins).toBeGreaterThan(0n);
    const onChain = await clients().public.readContract({ address: reward.coin, abi: erc20Abi, functionName: "totalSupply" });
    expect(await supplyOf(reward.coin)).toBe(supplies.reward - coins);
    expect(onChain).toBe(supplies.reward - coins);
    // A Stoke Launch burns nothing: its whole tax is Support Liquidity.
    expect(entries.some((e) => e.kind === "reward_burn" && e.launch?.mint === stoke.coin)).toBe(false);
  });

  test("a Destination's work appears on the coin's own Ledger and on the Ledger, from the chain's own events", async () => {
    const e = evm()!;
    expect(run.applied.map((a) => a.coin)).toEqual(expect.arrayContaining([burning.coin, liquid.coin]));
    const coinLedger = async (coin: Address) => ((await api(`/v1/launches/${coin}/ledger`)) as { entries: { kind: string; source: string; destination: string; amount: string; chain: string }[] }).entries;

    const burnEntries = await coinLedger(burning.coin);
    const credited = burnEntries.find((x) => x.kind === "creator_credit");
    expect(credited).toMatchObject({ chain: "robinhood", destination: e.destinations.burn });
    expect(burnEntries.find((x) => x.kind === "earnings_applied")).toMatchObject({ source: e.destinations.burn, destination: e.taxVault, amount: credited!.amount });
    const burned = burnEntries.find((x) => x.kind === "funded_burn");
    expect(BigInt(burned!.amount)).toBeGreaterThan(0n);
    expect(await supplyOf(burning.coin)).toBe(supplies.burning - BigInt(burned!.amount));
    // The Destination's funding is the one entry for that movement: never a second one from the Tax Vault's event.
    expect(burnEntries.some((x) => x.kind === "burn_funded")).toBe(false);

    const liquidEntries = await coinLedger(liquid.coin);
    const applied = liquidEntries.find((x) => x.kind === "earnings_applied");
    expect(applied).toMatchObject({ source: e.destinations.liquidity, destination: e.taxVault });
    expect(liquidEntries.find((x) => x.kind === "funded_liquidity")).toMatchObject({ amount: applied!.amount, destination: liquid.poolId });
    // The same entries are on the Ledger itself, and the Ledger pages through EVM transactions as through Solana's.
    const all = await ledgerOf(`chain=robinhood&kind=funded_liquidity`);
    expect(all.some((x) => x.launch?.mint === liquid.coin)).toBe(true);
    const first = (await api("/v1/ledger?chain=robinhood&limit=1")) as { next: string | null };
    expect(first.next).not.toBeNull();
    expect((await fetch(`${env().apiUrl}/v1/ledger?chain=robinhood&limit=1&before=${first.next}`)).status).toBe(200);
  });
});

describe.skipIf(!hasEvm)("EVM chain: revenue, the Platform Net and the keys", () => {
  test("GET /v1/revenue and the Platform Net count the chain's collections, per chain and together", async () => {
    const l = await launchCoin(await evmWallet());
    await swapExactIn(await evmWallet(), l, "buy", 10n ** 17n);
    await runIndexer();
    await runKeeper();
    expect((await runApiJob("evm-quotes")).status).toBe("succeeded");

    const revenue = Revenue.parse(await api("/v1/revenue"));
    const eth = revenue.totals.find((t) => t.chain === "robinhood" && t.asset.mint === NATIVE);
    expect(eth).toMatchObject({ asset: { symbol: "ETH", decimals: 18 }, creatorForwarded: "0", creatorPending: "0" });
    expect(BigInt(eth!.platformFee)).toBeGreaterThan(0n);
    const net = new Map(revenue.platformNet.chains.map((c) => [c.chain, BigInt(c.lamports)]));
    expect(net.get("robinhood")).toBeGreaterThan(0n);
    expect(BigInt(revenue.platformNet.lamports)).toBe([...net.values()].reduce((a, b) => a + b, 0n));
    // ETH is priced at 20 SOL on the stack: the chain's net is what reached the Admin, valued at it.
    // Another file's coins paired with a Stock Token collect in it too, unpriced, which counts for nothing.
    const collected = (await ledgerOf("chain=robinhood&kind=platform_fee")).filter((e) => e.asset.mint === NATIVE).reduce((sum, e) => sum + BigInt(e.amount), 0n);
    expect(net.get("robinhood")).toBe((collected * 20n * 10n ** 9n) / 10n ** 18n);
    const robinhoodOnly = Revenue.parse(await api("/v1/revenue?chain=robinhood"));
    expect(robinhoodOnly.totals.every((t) => t.chain === "robinhood")).toBe(true);
    expect(Revenue.parse(await api("/v1/revenue?chain=solana")).totals.every((t) => t.chain === "solana")).toBe(true);

    const solanaRows = BudgetsPage.parse(await api("/v1/budgets"));
    const chainRows = BudgetsPage.parse(await api("/v1/budgets?chain=robinhood"));
    expect(solanaRows).toMatchObject({ chain: "solana", netLamports: net.get("solana")!.toString(), togetherLamports: revenue.platformNet.lamports });
    expect(chainRows).toMatchObject({ chain: "robinhood", netLamports: net.get("robinhood")!.toString(), togetherLamports: revenue.platformNet.lamports });
    expect((await fetch(`${env().apiUrl}/v1/budgets?chain=nowhere`)).status).toBe(400);
  }, 240_000);

  test("the operator view lists each server key and the Admin with what each can do, and the Keeper's native balance", async () => {
    const e = evm()!;
    const page = EvmKeysPage.parse(await api("/v1/operator/evm-keys", { headers: operator() }));
    expect(page.problem).toBeNull();
    const chain = page.chains.find((c) => c.chain === "robinhood")!;
    const role = (r: string) => chain.keys.find((k) => k.role === r)!;
    expect(role("admin")).toMatchObject({ address: e.admin.address, heldByApi: false });
    expect(role("round_key")).toMatchObject({ address: e.serverKeys.round.address, heldByApi: false });
    expect(role("ladder_key")).toMatchObject({ address: e.serverKeys.ladder.address, heldByApi: true });
    expect(role("keeper")).toMatchObject({ address: e.serverKeys.keeper.address, heldByApi: true });
    for (const k of chain.keys) expect(k.can.length * k.cannot.length, k.role).toBeGreaterThan(0);
    expect(BigInt(chain.keeper.balance!)).toBe(await balanceOf(NATIVE, e.serverKeys.keeper.address));
    expect(chain.keeper).toMatchObject({ symbol: "ETH", decimals: 18, low: false });
    expect((await fetch(`${env().apiUrl}/v1/operator/evm-keys`)).status).toBe(401);
  });
});

describe.skipIf(!hasEvm)("EVM chain: an Indexer that stays behind its head", () => {
  let rpc: RpcStandIn;
  let behind: Awaited<ReturnType<typeof startApi>>;

  beforeAll(async () => {
    const e = inject("harness");
    rpc = await startRpcStandIn(e.evm!.rpcUrl, await freePort());
    const port = await freePort();
    // The same deployment, read through a provider the test can throttle, alerted two seconds behind the head.
    behind = await startApi({
      port, databaseUrl: e.databaseUrl,
      vars: { ...e.apiVars, PUBLIC_API_URL: `http://127.0.0.1:${port}`, ROBINHOOD_RPC_URL: rpc.url, EVM_DEPLOYMENTS: JSON.stringify([{ ...deploymentOf(e.evm!)[0], behindAlertSeconds: 2 }]) },
    });
  }, 240_000);

  afterAll(async () => {
    await behind?.stop();
    await rpc?.stop();
  });

  test("a rate limit that lasts raises the chain's alert, and a run that catches up resolves it", async () => {
    const open = async () => (await operatorAlerts()).find((a) => a.kind === "indexer_behind" && a.subject === "robinhood" && a.resolvedAt === null);
    await runIndexer(behind.url);
    expect(await open()).toBeUndefined();
    // Seconds pass on the chain, and the provider refuses every log: each run ends rate-limited, as succeeded.
    await sleep(3_500);
    await clients().test.mine({ blocks: 1 });
    const limit = rpc.fail({ method: "eth_getLogs", fault: { http: 429 } });
    const run = (await runIndexer(behind.url)) as { status: string; summary: { chains: { rateLimited: boolean; secondsBehind: number }[] } };
    expect(run.status).toBe("succeeded");
    expect(run.summary.chains[0]).toMatchObject({ rateLimited: true });
    expect(run.summary.chains[0]!.secondsBehind).toBeGreaterThan(2);
    expect((await open())?.message).toMatch(/behind the chain's head/);
    limit.stop();
    const caught = (await runIndexer(behind.url)) as { summary: { chains: { secondsBehind: number }[] } };
    expect(caught.summary.chains[0]!.secondsBehind).toBeLessThanOrEqual(2);
    expect(await open()).toBeUndefined();
    expect((await operatorAlerts()).find((a) => a.kind === "indexer_behind" && a.subject === "robinhood")?.resolvedAt).not.toBeNull();
  }, 120_000);
});
