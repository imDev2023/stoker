// A dev fork of Robinhood Chain with our contracts deployed (#252), for a dev API to index: `pnpm evm-fork` with
// ROBINHOOD_RPC_URL in the environment (an archive endpoint). It listens on 8796 (docs/agents/run-and-test.md) and
// prints the two variables the API takes; Ctrl-C stops it. The URL carries a key and is never printed.
import { spawn } from "node:child_process";
import { deployStoker, deploymentOf, forkArgs, serverKeyVars } from "./evm";

const PORT = Number(process.env.EVM_FORK_PORT ?? 8796);
const forkUrl = process.env.ROBINHOOD_RPC_URL;
if (!forkUrl) {
  console.error("ROBINHOOD_RPC_URL is not set: run this through `direnv exec` from the project's main checkout (docs/agents/run-and-test.md).");
  process.exit(1);
}
const anvil = spawn("anvil", forkArgs(forkUrl, PORT), { stdio: ["ignore", "ignore", "pipe"] });
anvil.stderr.on("data", (d: Buffer) => process.stderr.write(d.toString().replaceAll(forkUrl, "<redacted RPC URL>")));
anvil.on("exit", (code) => process.exit(code ?? 0));
process.on("SIGINT", () => anvil.kill("SIGTERM"));

const rpcUrl = `http://127.0.0.1:${PORT}`;
for (let i = 0; ; i++) {
  const up = await fetch(rpcUrl, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }) })
    .then((r) => r.ok)
    .catch(() => false);
  if (up) break;
  if (i > 400) throw new Error(`the fork did not answer on ${rpcUrl} within two minutes`);
  await new Promise((r) => setTimeout(r, 300));
}
const evm = await deployStoker(rpcUrl);
console.log(`Robinhood Chain fork on ${rpcUrl}, our contracts deployed (the Admin is anvil's first account, ${evm.admin.address}).`);
console.log("Give the dev API these, as --var NAME:value:");
console.log(`EVM_DEPLOYMENTS=${JSON.stringify(deploymentOf(evm))}`);
console.log(`ROBINHOOD_RPC_URL=${rpcUrl}`);
// Anvil's well-known development keys, appointed on this fork alone: the Keeper and the ladder key (#254).
for (const [name, value] of Object.entries(serverKeyVars(evm))) console.log(`${name}=${value}`);
