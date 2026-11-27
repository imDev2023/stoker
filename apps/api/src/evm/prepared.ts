import { and, eq } from "drizzle-orm";
import type { LaunchEvent } from "@launchpad/evm";
import { launches, launchMetadata, type Db } from "@launchpad/db";
import type { EvmChainConfig } from "../chains/evm/config";
import { checkCopies, firstCopy, launchKeys } from "../copies/check";
import { arweaveUrl, signedItems } from "../metadata";

type Columns = Pick<typeof launches.$inferInsert, "metadataUri" | "nameKey" | "symbolKey" | "imageHash" | "copyOf" | "copyKind">;

/**
 * What the Indexer writes on an EVM coin from the record its launch was prepared with (#253), and from Copy Protection.
 *
 * A coin's address is fixed by its Creator, the launch's salt, its name and its ticker (the factory's CREATE2), and a
 * record is stored at an address only by a prepare that tried that very launch out on the chain. So a record at the
 * coin's address describes that coin: its metadata address, and its picture's hash. The Creator, the name and the
 * ticker are compared all the same, and a record that disagrees is passed over.
 *
 * A coin with a record was launched through this API and is protected from then on, on every chain: its metadata
 * address is what `checkCopies` reads that by. A coin sent straight to the factory has none, is never protected, and
 * keeps an empty metadata address. Either is labelled when it takes an earlier protected coin's name, ticker or image,
 * as Solana's Indexer labels: a refusal is prepare's alone.
 */
export async function preparedColumns(db: Db, c: EvmChainConfig, e: LaunchEvent, coin: { name: string; symbol: string }, launchedAt: Date): Promise<Columns> {
  // Never written half: without the platform's settings the run stops, and the next reads the launch again.
  if (!c.platform) throw new Error(`${c.chain}'s Indexer was started without the platform's settings, so a launch's record cannot be written`);
  const [stored] = await db.select().from(launchMetadata).where(and(eq(launchMetadata.id, e.coin), eq(launchMetadata.chain, c.chain))).limit(1);
  const record = stored && stored.creator === e.creator && stored.name === coin.name && stored.symbol === coin.symbol ? stored : null;
  const items = record ? await signedItems(db, e.coin) : null;
  const imageHash = record?.imageHash ?? null;
  const copy = firstCopy(await checkCopies(db, c.platform, { name: coin.name, symbol: coin.symbol, imageHash, creator: e.creator }, launchedAt, { window: false }));
  return {
    ...launchKeys(coin.name, coin.symbol),
    imageHash,
    copyOf: copy?.of?.mint ?? null,
    copyKind: copy?.kind ?? null,
    metadataUri: record && items ? arweaveUrl(c.platform.arweave, items.metadata.arweaveId) : "",
  };
}
