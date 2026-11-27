// A stand-in for an EVM chain's RPC provider (#279): a JSON-RPC proxy in front of the stack's fork that can be told to
// answer as a real provider does on a bad day, so the Indexer is tested against a provider's behaviour and not only
// against anvil, which never throttles, never refuses a range and is never behind. Everything it is not told to change
// goes to the fork untouched.
import { createServer } from "node:http";

/** What a rule answers with, in place of the fork's answer. */
export type RpcFault =
  /** A JSON-RPC error in a 200, as a node answers one: -32603 "Internal error" for a provider's own failure. */
  | { rpc: { code: number; message: string; data?: unknown } }
  /** An HTTP status with a provider's body: 429 for a rate limit (Alchemy's wording is the default), 503 for an outage. */
  | { http: number; message?: string };

/**
 * One fault: the calls it applies to and what they are answered. `data` is a prefix of an `eth_call`'s calldata (a
 * function's selector), `to` its target; `times` is how many calls it answers before it is spent (every one when unset).
 */
export type RpcRule = { method: string; data?: string; to?: string; times?: number; fault: RpcFault };

export type RpcBehaviour = {
  /**
   * `eth_getLogs` over more blocks than this is refused as Alchemy's free tier refuses one past 10 (measured on
   * 2026-11-25): HTTP 400 with the JSON-RPC error -32600 in its body, in its words.
   */
  maxLogRange: number | null;
  /**
   * How many blocks behind the fork's head this provider's logs are, as a node behind a load balancer: an `eth_getLogs`
   * reaching past that point is answered with what the node has, and no error.
   */
  lagBlocks: number;
  /** A wait before every answer, in milliseconds: a provider's latency. */
  delayMs: number;
  rules: RpcRule[];
};

export type RpcStandIn = {
  url: string;
  behaviour: RpcBehaviour;
  /** Every `eth_getLogs` asked for, by its width in blocks, refused ones included. */
  logRanges: number[];
  /** How many calls of each method arrived. */
  calls: Record<string, number>;
  /** Adds a fault and answers a handle that says how many calls it has answered. */
  fail: (rule: RpcRule) => { answered: () => number; stop: () => void };
  /** Back to a plain proxy, with its records emptied. */
  reset: () => void;
  stop: () => Promise<void>;
};

type Call = { id: unknown; method: string; params?: unknown[] };

const RATE_LIMIT_MESSAGE =
  "Your app has exceeded its compute units per second capacity. If you have retries enabled, you can safely ignore this message. If you see this frequently, you should upgrade your plan.";

/**
 * Starts the stand-in on `port`, in front of the RPC at `upstream`. It is also driven over HTTP, for a stack whose
 * tests run in another process: `POST /stand-in/behaviour` takes a partial `RpcBehaviour`, `GET /stand-in/state`
 * answers the behaviour and the records, and `POST /stand-in/reset` empties both.
 */
export async function startRpcStandIn(upstream: string, port: number): Promise<RpcStandIn> {
  const fresh = (): RpcBehaviour => ({ maxLogRange: null, lagBlocks: 0, delayMs: 0, rules: [] });
  const behaviour = fresh();
  const logRanges: number[] = [];
  const calls: Record<string, number> = {};
  const answeredBy = new Map<RpcRule, number>();
  const reset = () => {
    Object.assign(behaviour, fresh());
    logRanges.length = 0;
    for (const k of Object.keys(calls)) delete calls[k];
    answeredBy.clear();
  };
  const forward = async (body: unknown) => {
    const res = await fetch(upstream, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    return { status: res.status, body: (await res.json()) as unknown };
  };
  const head = async () => BigInt(((await forward({ jsonrpc: "2.0", id: 0, method: "eth_blockNumber", params: [] })).body as { result: string }).result);
  const error = (id: unknown, code: number, message: string, data?: unknown) => ({ jsonrpc: "2.0", id, error: { code, message, ...(data === undefined ? {} : { data }) } });

  /** A call's answer when the stand-in has one of its own: a JSON-RPC body, or an HTTP status for the whole request. */
  async function own(call: Call): Promise<{ body: unknown } | { http: number; body: unknown } | null> {
    calls[call.method] = (calls[call.method] ?? 0) + 1;
    const first = (call.params?.[0] ?? {}) as { fromBlock?: string; toBlock?: string; data?: string; input?: string; to?: string };
    const calldata = (first.data ?? first.input ?? "").toLowerCase();
    for (const rule of behaviour.rules) {
      if (rule.method !== call.method) continue;
      if (rule.data !== undefined && !calldata.startsWith(rule.data.toLowerCase())) continue;
      if (rule.to !== undefined && rule.to.toLowerCase() !== (first.to ?? "").toLowerCase()) continue;
      const answered = answeredBy.get(rule) ?? 0;
      if (rule.times !== undefined && answered >= rule.times) continue;
      answeredBy.set(rule, answered + 1);
      if ("rpc" in rule.fault) return { body: error(call.id, rule.fault.rpc.code, rule.fault.rpc.message, rule.fault.rpc.data) };
      const message = rule.fault.message ?? (rule.fault.http === 429 ? RATE_LIMIT_MESSAGE : "upstream unavailable");
      return { http: rule.fault.http, body: error(call.id, rule.fault.http === 429 ? 429 : -32000, message) };
    }
    if (call.method !== "eth_getLogs" || first.fromBlock === undefined || first.toBlock === undefined) return null;
    const [from, to] = [BigInt(first.fromBlock), BigInt(first.toBlock)];
    const width = Number(to - from) + 1;
    logRanges.push(width);
    if (behaviour.maxLogRange !== null && width > behaviour.maxLogRange) {
      const works = `[${first.fromBlock}, 0x${(from + BigInt(behaviour.maxLogRange) - 1n).toString(16)}]`;
      const message = `Under the Free tier plan, you can make eth_getLogs requests with up to a ${behaviour.maxLogRange} block range. Based on your parameters, this block range should work: ${works}. Upgrade to PAYG for expanded block range.`;
      return { http: 400, body: error(call.id, -32600, message) };
    }
    if (behaviour.lagBlocks > 0) {
      // What this node has: nothing past its own head, and it says so with a shorter answer, never an error.
      const has = (await head()) - BigInt(behaviour.lagBlocks);
      if (from > has) return { body: { jsonrpc: "2.0", id: call.id, result: [] } };
      if (to > has) return { body: (await forward({ ...call, jsonrpc: "2.0", params: [{ ...first, toBlock: `0x${has.toString(16)}` }, ...(call.params ?? []).slice(1)] })).body };
    }
    return null;
  }

  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (d) => (raw += d));
    req.on("end", async () => {
      const json = (status: number, body: unknown) => res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
      try {
        if (req.url === "/stand-in/state") return json(200, { behaviour, logRanges, calls });
        if (req.url === "/stand-in/reset") return json(200, (reset(), { ok: true }));
        if (req.url === "/stand-in/behaviour") return json(200, Object.assign(behaviour, JSON.parse(raw) as Partial<RpcBehaviour>));
        const body = JSON.parse(raw) as Call | Call[];
        if (behaviour.delayMs > 0) await new Promise((r) => setTimeout(r, behaviour.delayMs));
        const answers: unknown[] = [];
        for (const call of [body].flat()) {
          const mine = await own(call);
          // An HTTP status is the whole request's, as a provider throttles a request, not one call of a batch.
          if (mine && "http" in mine) return json(mine.http, mine.body);
          answers.push(mine ? mine.body : (await forward({ ...call, jsonrpc: "2.0" })).body);
        }
        json(200, Array.isArray(body) ? answers : answers[0]);
      } catch (e) {
        json(502, error(null, -32000, `the RPC stand-in could not reach the fork: ${(e as Error).message}`));
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(port, "127.0.0.1", resolve));
  return {
    url: `http://127.0.0.1:${port}`,
    behaviour,
    logRanges,
    calls,
    fail(rule) {
      behaviour.rules.push(rule);
      return {
        answered: () => answeredBy.get(rule) ?? 0,
        stop: () => void behaviour.rules.splice(behaviour.rules.indexOf(rule), behaviour.rules.indexOf(rule) < 0 ? 0 : 1),
      };
    },
    reset,
    stop: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}
