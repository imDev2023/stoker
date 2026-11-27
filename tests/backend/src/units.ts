// What every transaction of a run used of the compute-unit limit it asked for, by kind of transaction (#282).
// A limit is a guess at build time, and what a transaction then costs moves with the addresses it names: a program
// that derives an address searches for it at about 1,500 units a try. `UNITS_REPORT=<file> pnpm test:backend` writes
// this table when the suite ends, which is how a limit's margin is measured, and measured again after Raydium
// upgrades a program.
import { writeFileSync } from "node:fs";
import { ComputeBudgetProgram, Connection } from "@solana/web3.js";
import { cpmmCoder, launchlabCoder, lockCoder, programsFor } from "@launchpad/chain";

export type UnitsRow = {
  /** The limit asked for and what the transaction did: our programs' instructions by name, in order. */
  kind: string;
  limit: number;
  transactions: number;
  /** Those that ran out of compute units. */
  ranOut: number;
  /** The least and the most a transaction that landed used. */
  least: number;
  most: number;
  /** The token accounts the costliest one opened, and its signature. */
  mostOpened: number;
  mostSignature: string;
  /** What the costliest left of the limit, in units and in tries of an address search at 1,500 units each. */
  spare: number;
  spareTries: number;
};

const SET_LIMIT = 2;
const UNITS_A_TRY = 1_500;

/** Every transaction on the chain that set a compute-unit limit and called one of Raydium's programs, grouped by that limit and by what it did. */
export async function unitsReport(rpcUrl: string): Promise<UnitsRow[]> {
  const connection = new Connection(rpcUrl, "confirmed");
  const programs = programsFor("localnet");
  const coders = new Map([
    [programs.launchlab.toBase58(), launchlabCoder], [programs.cpmm.toBase58(), cpmmCoder], [programs.lock.toBase58(), lockCoder],
  ]);
  const signatures: string[] = [];
  for (let before: string | undefined; ; ) {
    const page = await connection.getSignaturesForAddress(ComputeBudgetProgram.programId, { limit: 1000, ...(before ? { before } : {}) }, "confirmed");
    signatures.push(...page.map((s) => s.signature));
    if (page.length < 1000) break;
    before = page.at(-1)!.signature;
  }
  const rows = new Map<string, UnitsRow>();
  const read = async (signature: string) => {
    const tx = await connection.getTransaction(signature, { commitment: "confirmed", maxSupportedTransactionVersion: 0 });
    if (!tx?.meta || tx.meta.computeUnitsConsumed === undefined) return;
    const keys = tx.transaction.message.getAccountKeys({ accountKeysFromLookups: tx.meta.loadedAddresses ?? { writable: [], readonly: [] } });
    const top = tx.transaction.message.compiledInstructions;
    const programOf = (ix: (typeof top)[number]) => keys.get(ix.programIdIndex)!.toBase58();
    const limitIx = top.find((ix) => programOf(ix) === ComputeBudgetProgram.programId.toBase58() && ix.data[0] === SET_LIMIT);
    if (!limitIx) return;
    const limit = Buffer.from(limitIx.data).readUInt32LE(1);
    const names = top.flatMap((ix) => {
      const coder = coders.get(programOf(ix));
      if (!coder) return [];
      try {
        return [coder.instruction.decode(Buffer.from(ix.data))?.name ?? "?"];
      } catch {
        return ["?"];
      }
    });
    if (!names.length) return;
    const logs = tx.meta.logMessages ?? [];
    const kind = `${limit} ${names.join(" + ")}`;
    const row = rows.get(kind) ?? { kind, limit, transactions: 0, ranOut: 0, least: Infinity, most: 0, mostOpened: 0, mostSignature: "", spare: 0, spareTries: 0 };
    rows.set(kind, row);
    row.transactions++;
    if (tx.meta.err) {
      if (logs.some((l) => l.includes("exceeded CUs meter") || l.includes("Computational budget exceeded"))) row.ranOut++;
      return;
    }
    const used = tx.meta.computeUnitsConsumed;
    row.least = Math.min(row.least, used);
    // Both token programs log the instruction that makes a new account a token account.
    const opened = logs.filter((l) => /Instruction: InitializeAccount3?$/.test(l)).length;
    if (used > row.most) Object.assign(row, { most: used, mostOpened: opened, mostSignature: signature });
  };
  for (let i = 0; i < signatures.length; i += 20) await Promise.all(signatures.slice(i, i + 20).map(read));
  for (const row of rows.values()) {
    row.spare = row.limit - row.most;
    row.spareTries = Math.floor(row.spare / UNITS_A_TRY);
  }
  return [...rows.values()].sort((a, b) => a.spare - b.spare);
}

/** Writes the report as JSON, and prints it as a table. */
export async function writeUnitsReport(rpcUrl: string, path: string) {
  const rows = await unitsReport(rpcUrl);
  writeFileSync(path, JSON.stringify(rows, null, 2));
  console.table(rows.map((r) => ({ kind: r.kind, transactions: r.transactions, ranOut: r.ranOut, least: r.least, most: r.most, mostOpened: r.mostOpened, spare: r.spare, spareTries: r.spareTries })));
}
