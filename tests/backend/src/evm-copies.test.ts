// #253: Copy Protection covers every chain (ADR 0012). A coin's name, ticker and image are protected on Solana and on
// every EVM chain for the window: every Solana coin, and an EVM coin launched through the API. A coin sent straight to
// the factory, which costs cents, protects nothing and is labelled when it copies. Black box, on the stack's fork; the
// window here is 45 seconds, and every coin has a name, a ticker and a picture no other test's has.
import { describe, expect, inject, test } from "vitest";
import type { Address } from "viem";
import { deliverWebhook, fundedWallet, getLaunch, launch, prepare, uniqueTag } from "./client";
import { evmWallet, launchCoin, runIndexer } from "./evm";
import { check, coinPage, png, prepared, prepareEvm, refusal, send } from "./evm-launch-helpers";

const hasEvm = inject("harness").evm !== null;

/**
 * Two pictures in four upright stripes, each the other's negative, and the first again at twice the size in other
 * shades: by the API's own hash the two are 40 bits apart, each is 40 or more from `copies.test.ts`'s, and the larger
 * one is 8 from the first, inside the 10 that make a copy.
 */
const PICTURE = png([250, 240, 60], [30, 20, 90], 32, 4);
const PICTURE_AGAIN = png([240, 230, 80], [20, 30, 100], 64, 4);
const OTHER_PICTURE = png([30, 20, 90], [250, 240, 60], 32, 4);
const image = (bytes: Uint8Array) => ({ bytes, type: "image/png" });

describe.skipIf(!hasEvm)("Copy Protection across chains", () => {
  test("a coin launched on Solana refuses its name, ticker and image on the EVM chain", async () => {
    const tag = uniqueTag();
    const name = `Ember Wolf ${tag}`;
    const ticker = `EMB${tag.slice(0, 3)}X`;
    const original = await fundedWallet();
    const launched = await launch(original, { name, symbol: ticker, image: image(PICTURE), exact: true });
    await deliverWebhook([launched.signature]);
    const protectedCoin = { mint: launched.prepared.mint, chain: "solana", symbol: ticker, name };

    // The check, as the EVM launch form asks it, and the prepare, which refuses with the same verdict, the ticker first.
    const copier = await evmWallet();
    const asked = await check({ chain: "robinhood", creator: copier.address, name, symbol: ticker.toLowerCase() });
    expect(asked.symbol).toMatchObject({ status: "taken", kind: "ticker", of: protectedCoin });
    expect(asked.name).toMatchObject({ status: "taken", kind: "name", of: protectedCoin });
    expect(asked.refusals).toEqual([]);
    const refused = await refusal({ creator: copier.address, name, symbol: ticker });
    expect(refused).toMatchObject({ status: 409, copy: { kind: "ticker", of: protectedCoin } });
    expect(refused.error).toBe((await check({ chain: "robinhood", symbol: ticker })).symbol!.reason);
    // By any fold, and one edit away, as on Solana.
    expect((await refusal({ creator: copier.address, name: `Official ${name}` })).copy).toMatchObject({ kind: "name", of: protectedCoin });
    const oneEdit = ticker.slice(0, 6) + "Q";
    expect((await refusal({ creator: copier.address, symbol: oneEdit })).copy).toMatchObject({ kind: "near", of: protectedCoin });
    // The image, compared across chains: the same picture at another size, in other shades.
    expect((await check({ chain: "robinhood", image: PICTURE_AGAIN })).image).toMatchObject({ status: "taken", kind: "image", of: protectedCoin });
    const byImage = await refusal({ creator: copier.address, image: PICTURE_AGAIN });
    expect(byImage).toMatchObject({ status: 409, copy: { kind: "image", of: protectedCoin } });
    // Another name, ticker and picture launch freely.
    expect((await prepareEvm({ creator: copier.address })).status).toBe(200);
  });

  test("a coin launched through the API on the EVM chain refuses its name, ticker and image on Solana", async () => {
    const tag = uniqueTag();
    const name = `Slate Heron ${tag}`;
    const ticker = `SLA${tag.slice(0, 3)}X`;
    const creator = await evmWallet();
    const p = await prepared({ creator: creator.address, name, symbol: ticker, image: OTHER_PICTURE });
    await send(creator, p.transaction!);
    // Until the launch is indexed nothing is protected: a coin that never lands holds no name.
    expect((await check({ symbol: ticker })).symbol).toMatchObject({ status: "free" });
    await runIndexer();
    const coin = await coinPage(p.coin);
    expect(coin.copyOf).toBeNull();
    const protectedCoin = { mint: p.coin, chain: "robinhood", symbol: ticker, name, protectedUntil: coin.protection.until };
    // A coin is protected from its launch's own time. The fork stamps blocks mined in one second a second apart, so its
    // clock can stand a few seconds ahead of the wall's, which no real chain's does: wait for the wall clock to pass it.
    await new Promise((r) => setTimeout(r, Math.max(0, new Date(coin.createdAt).getTime() - Date.now() + 1_000)));

    const copier = await fundedWallet();
    const who = copier.publicKey.toBase58();
    // Solana's check (no chain named) and Solana's prepare, with the verdict naming the coin and its chain.
    const asked = await check({ creator: who, name, symbol: ticker });
    expect(asked.symbol).toMatchObject({ status: "taken", kind: "ticker", of: protectedCoin });
    expect(asked.name).toMatchObject({ status: "taken", kind: "name", of: protectedCoin });
    const refused = await prepare({ creator: who, name, symbol: ticker, exact: true });
    expect(refused.status).toBe(409);
    const body = (await refused.json()) as { error: string; copy: unknown };
    expect(body.copy).toMatchObject({ kind: "ticker", of: protectedCoin });
    expect(body.error).toBe(asked.symbol!.reason);
    const byImage = await prepare({ creator: who, image: image(OTHER_PICTURE) });
    expect(byImage.status).toBe(409);
    expect(((await byImage.json()) as { copy: unknown }).copy).toMatchObject({ kind: "image", of: protectedCoin });
    // And on its own chain, from another wallet; the Creator may reuse their own, in whatever case the wallet gives its address.
    const other = await evmWallet();
    expect(await refusal({ creator: other.address, name, symbol: ticker })).toMatchObject({ status: 409, copy: { kind: "ticker", of: protectedCoin } });
    const lowerCase = creator.address.toLowerCase() as Address;
    expect((await check({ chain: "robinhood", creator: lowerCase, name, symbol: ticker, image: OTHER_PICTURE })).symbol).toMatchObject({ status: "free" });
    expect((await prepareEvm({ creator: lowerCase, name, symbol: ticker, image: OTHER_PICTURE })).status).toBe(200);
  });

  test("a coin sent straight to the factory protects nothing, on either chain", async () => {
    const tag = uniqueTag();
    const name = `Quiet Lynx ${tag}`;
    const ticker = `LYN${tag.slice(0, 3)}X`;
    const oneEdit = { name: `${name}s`, symbol: ticker.slice(0, 6) + "Q" };
    const direct = await launchCoin(await evmWallet(), { name, symbol: ticker });
    await runIndexer();
    const coin = await coinPage(direct.coin);
    expect(coin).toMatchObject({ name, symbol: ticker, metadataUri: "", copyOf: null });

    // Its own name and ticker, and one edit from them, stay free to launch on Solana and on the EVM chain.
    const solana = await fundedWallet();
    const evmCreator = await evmWallet();
    for (const text of [{ name, symbol: ticker }, oneEdit]) {
      expect(await check({ creator: solana.publicKey.toBase58(), ...text })).toMatchObject({ name: { status: "free" }, symbol: { status: "free" } });
      expect(await check({ chain: "robinhood", creator: evmCreator.address, ...text })).toMatchObject({ name: { status: "free" }, symbol: { status: "free" } });
    }
    expect((await prepare({ creator: solana.publicKey.toBase58(), name, symbol: ticker, exact: true })).status).toBe(200);
    expect((await prepareEvm({ creator: evmCreator.address, ...oneEdit })).status).toBe(200);
  });

  test("a coin sent straight to the factory that copies a protected Solana coin lands with the label", async () => {
    const tag = uniqueTag();
    const name = `Brass Otter ${tag}`;
    const ticker = `BRA${tag.slice(0, 3)}X`;
    const original = await launch(await fundedWallet(), { name, symbol: ticker, exact: true });
    await deliverWebhook([original.signature]);

    const copy = await launchCoin(await evmWallet(), { name: name.toLowerCase(), symbol: ticker.toLowerCase() });
    await runIndexer();
    expect((await coinPage(copy.coin)).copyOf).toMatchObject({ kind: "ticker", mint: original.prepared.mint, chain: "solana", symbol: ticker, name });
    // It stays on the board, and the original is not a copy of it.
    expect((await getLaunch(original.prepared.mint)).launch!.copyOf).toBeNull();
  });
});
