// Sending a job's transaction on an EVM chain (#254), as Solana's jobs send theirs (`job_transactions`): written down
// with its hash and its signed bytes before it goes out, and settled by its hash. A run that dies after sending finds
// it and records what landed; one that died before sending sends the same bytes again while their nonce is free; and a
// transaction whose nonce another took is dropped, never sent twice. Every call a job makes is simulated first, so a
// call the contract refuses (a Tax Vault piece too soon, nothing waiting) is a reason in the run's summary, never gas.
import {
  decodeErrorResult, keccak256, type Abi, type Account, type Address, type Hex, type PublicClient, type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { and, eq } from "drizzle-orm";
import { evmJobTransactions, type Db } from "@launchpad/db";
import { withoutRpcUrl, type EvmChainConfig } from "./config";
import { evmClient, nodeSaysRevert } from "./indexer";

/** How long a run waits for a transaction it sent to land before leaving it to the next run to settle. */
const LAND_TIMEOUT_MS = 30_000;
/** The gas a call is sent with over the node's estimate, for a state that moves between the estimate and the block. */
const GAS_MARGIN_PERCENT = 30n;

export type Call = { to: Address; data: Hex; value?: bigint; gas?: bigint };

/** A call the contract refused when it was simulated, with the error it named: nothing was sent. */
export class Refused extends Error {
  constructor(readonly reason: string) {
    super(reason);
  }
}

export class EvmSender {
  readonly account: Account;
  readonly client: PublicClient;

  constructor(readonly db: Db, readonly c: EvmChainConfig, key: Hex, readonly job: string) {
    this.account = privateKeyToAccount(key);
    this.client = evmClient(c);
  }

  get address(): Address {
    return this.account.address;
  }

  /** Whether a transaction for `purpose` on `subject` is still waiting to settle: the next one waits behind it. */
  async waiting(purpose: string, subject: string) {
    const [row] = await this.db
      .select({ hash: evmJobTransactions.hash })
      .from(evmJobTransactions)
      .where(and(eq(evmJobTransactions.chain, this.c.chain), eq(evmJobTransactions.sender, this.address), eq(evmJobTransactions.purpose, purpose), eq(evmJobTransactions.subject, subject), eq(evmJobTransactions.status, "pending")))
      .limit(1);
    return row !== undefined;
  }

  /**
   * Simulates a call as this sender: the gas it needs, or `Refused` with the error the contract named (decoded from
   * `abi`). A failure of the provider is thrown as it is, so a run never mistakes it for the contract's answer.
   */
  async simulate(call: Call, abi: Abi): Promise<bigint> {
    try {
      return await this.client.estimateGas({ account: this.account, to: call.to, data: call.data, value: call.value ?? 0n });
    } catch (e) {
      // A revert is the node's JSON-RPC code 3 or revert data, never `-32603` (the provider's own failure), whatever viem calls it (#279).
      if (!nodeSaysRevert(e)) throw withoutRpcUrl(e, this.c);
      throw new Refused(revertReason(e, abi));
    }
  }

  /**
   * Sends a call that `simulate` passed: signed here, written down with its hash, then sent, then waited for. `recorded`
   * runs once the row is written and before anything is sent, for a job that marks its own rows with the hash (a
   * rebate's). Answers the receipt, or null when it has not landed within the wait (the next run settles it).
   */
  async send(purpose: string, subject: string, call: Call, gas: bigint, recorded?: (hash: Hex) => Promise<void>): Promise<TransactionReceipt | null> {
    const [nonce, fees] = await Promise.all([this.client.getTransactionCount({ address: this.address, blockTag: "pending" }), this.client.estimateFeesPerGas()]);
    const raw = await this.account.signTransaction!({
      type: "eip1559", chainId: this.c.profile.chainId, to: call.to, data: call.data, value: call.value ?? 0n, nonce,
      gas: call.gas ?? (gas * (100n + GAS_MARGIN_PERCENT)) / 100n, maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
    });
    const hash = keccak256(raw);
    await this.db.insert(evmJobTransactions).values({ chain: this.c.chain, hash, job: this.job, purpose, subject, sender: this.address, nonce, raw });
    if (recorded) await recorded(hash);
    try {
      await this.client.sendRawTransaction({ serializedTransaction: raw });
    } catch (e) {
      // A node that already has it, or a nonce taken meanwhile: the settlement tells which.
      if (!/already known|nonce too low|known transaction/i.test(String((e as Error).message))) {
        await this.resolve(hash, "failed", withoutRpcUrl(e, this.c).message.split("\n")[0]!.slice(0, 400));
        throw withoutRpcUrl(e, this.c);
      }
    }
    return this.land(hash);
  }

  /** Waits for a transaction to land and records how it ended; null when it has not landed within the wait. */
  async land(hash: Hex): Promise<TransactionReceipt | null> {
    const receipt = await this.client.waitForTransactionReceipt({ hash, timeout: LAND_TIMEOUT_MS }).catch(() => null);
    if (!receipt) return null;
    await this.resolve(hash, receipt.status === "success" ? "landed" : "failed", receipt.status === "success" ? null : "reverted on-chain", Number(receipt.blockNumber));
    return receipt;
  }

  /**
   * Settles every transaction this sender left waiting (#254): landed or failed by its receipt; dropped when its nonce
   * was taken by another; otherwise sent again as it was signed. Answers how each ended.
   */
  async settle(): Promise<{ hash: Hex; purpose: string; subject: string; status: "pending" | "landed" | "failed" | "dropped" }[]> {
    const open = await this.db
      .select()
      .from(evmJobTransactions)
      .where(and(eq(evmJobTransactions.chain, this.c.chain), eq(evmJobTransactions.sender, this.address), eq(evmJobTransactions.status, "pending")));
    const out = [];
    for (const t of open) {
      const hash = t.hash as Hex;
      const receipt = await this.client.getTransactionReceipt({ hash }).catch(() => null);
      if (receipt) {
        const status = receipt.status === "success" ? "landed" : "failed";
        await this.resolve(hash, status, status === "failed" ? "reverted on-chain" : null, Number(receipt.blockNumber));
        out.push({ hash, purpose: t.purpose, subject: t.subject, status } as const);
        continue;
      }
      const used = await this.client.getTransactionCount({ address: this.address, blockTag: "latest" });
      if (used > t.nonce) {
        await this.resolve(hash, "dropped", `nonce ${t.nonce} was taken by another transaction`);
        out.push({ hash, purpose: t.purpose, subject: t.subject, status: "dropped" } as const);
        continue;
      }
      await this.client.sendRawTransaction({ serializedTransaction: t.raw as Hex }).catch(() => undefined);
      const landed = await this.land(hash);
      out.push({ hash, purpose: t.purpose, subject: t.subject, status: landed ? (landed.status === "success" ? "landed" : "failed") : "pending" } as const);
    }
    return out;
  }

  private resolve(hash: Hex, status: "landed" | "failed" | "dropped", error: string | null, block?: number) {
    return this.db
      .update(evmJobTransactions)
      .set({ status, error, block: block ?? null, resolvedAt: new Date() })
      .where(and(eq(evmJobTransactions.chain, this.c.chain), eq(evmJobTransactions.hash, hash), eq(evmJobTransactions.status, "pending")));
  }
}

/** The error a refused call named, decoded from the contract's ABI where it can be, in one line. */
function revertReason(e: unknown, abi: Abi): string {
  let data: Hex | undefined;
  for (let x: unknown = e, i = 0; x && i < 12; x = (x as { cause?: unknown }).cause, i++) {
    const d = (x as { data?: unknown }).data;
    if (typeof d === "string" && /^0x[0-9a-fA-F]{8,}$/.test(d)) data = d as Hex;
    else if (d && typeof d === "object" && typeof (d as { data?: unknown }).data === "string") data = (d as { data: Hex }).data;
  }
  if (data) {
    try {
      const err = decodeErrorResult({ abi, data });
      return `${err.errorName}(${(err.args ?? []).map(String).join(", ")})`;
    } catch {
      return `reverted with ${data.slice(0, 10)}`;
    }
  }
  return String((e as Error).message ?? e).split("\n")[0]!.slice(0, 200);
}
