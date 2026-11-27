import { HTTPException } from "hono/http-exception";
import { decodeErrorResult, parseAbi, type Abi, type Address, type Hex } from "viem";
import { stokerHookAbi } from "@launchpad/evm";

/**
 * Why a trade on an EVM chain would fail, in words (#253): the revert data of the V4 Quoter's run or of the estimate of
 * the trade's own transaction, read through the wrappers each layer puts around it down to the error that caused it.
 */

/**
 * Every error a trade's path can end in that a sentence can be written for: our hook's own (from the contracts'
 * build), and by hand the Quoter's, the PoolManager's wrapper, the Universal Router's, Permit2's and a Stock Token's
 * (the knowledge base's `56-stock-token-custody-and-payouts.md`), each as its verified source declares it.
 */
const revertsAbi: Abi = [
  ...stokerHookAbi.filter((item) => item.type === "error"),
  ...parseAbi([
    // V4Quoter: a swap that reverted inside its run, and one the pool could not fill.
    "error UnexpectedRevertBytes(bytes revertData)",
    "error NotEnoughLiquidity(bytes32 poolId)",
    // The PoolManager, around a hook's revert or a currency's failed transfer (v4-core's CustomRevert).
    "error WrappedError(address target, bytes4 selector, bytes reason, bytes details)",
    // The Universal Router: a command that failed, the slippage limit, the deadline.
    "error ExecutionFailed(uint256 commandIndex, bytes message)",
    "error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived)",
    "error TransactionDeadlinePassed()",
    // Permit2.
    "error InvalidSigner()",
    "error InvalidSignature()",
    "error InvalidSignatureLength()",
    "error InvalidContractSignature()",
    "error InvalidNonce()",
    "error SignatureExpired(uint256 signatureDeadline)",
    "error AllowanceExpired(uint256 deadline)",
    "error InsufficientAllowance(uint256 amount)",
    // A Stock Token: its issuer's pause, and its blocklist.
    "error IsPaused()",
    "error Blocked(address account)",
  ]),
];

export type Revert = { name: string; args: readonly unknown[] };

/** The layers that carry another contract's revert inside their own, and where in their arguments it is. */
const WRAPPERS: Record<string, number> = { UnexpectedRevertBytes: 0, WrappedError: 2, ExecutionFailed: 1 };

/** The error at the bottom of `data`, under every wrapper; null for bytes that are none of the errors known here. */
export function revertOf(data: Hex | null | undefined): Revert | null {
  let inner = data;
  for (let depth = 0; inner && depth < 8; depth++) {
    let decoded: { errorName: string; args?: readonly unknown[] };
    try {
      decoded = decodeErrorResult({ abi: revertsAbi, data: inner }) as { errorName: string; args?: readonly unknown[] };
    } catch {
      return null;
    }
    const args = decoded.args ?? [];
    const wrapped = WRAPPERS[decoded.errorName];
    if (wrapped === undefined) return { name: decoded.errorName, args };
    inner = args[wrapped] as Hex;
  }
  return null;
}

const HEX = /^0x([0-9a-fA-F]{2})+$/;

/**
 * What an RPC's error says the call reverted with: the `data` beside the error, wherever viem carries it down its
 * chain of causes (a provider answers it as a string, or as an object holding one). `reverted` is true when the error
 * is a revert at all, with or without data, and false for a failure of the provider or the network.
 */
export function revertFrom(e: unknown): { reverted: boolean; data: Hex | null } {
  let reverted = false;
  for (let x: unknown = e, i = 0; x && i < 10; x = (x as { cause?: unknown }).cause, i++) {
    const { data, message, details, code } = x as { data?: unknown; message?: unknown; details?: unknown; code?: unknown };
    const hex = typeof data === "string" ? data : typeof (data as { data?: unknown } | null)?.data === "string" ? (data as { data: string }).data : null;
    if (hex && HEX.test(hex)) return { reverted: true, data: hex as Hex };
    // JSON-RPC's code for a reverted call is 3; the words are every node's own.
    if (code === 3 || /execution reverted|revert/i.test(`${String(message ?? "")} ${String(details ?? "")}`)) reverted = true;
  }
  return { reverted, data: null };
}

/** What a refusal's sentence may name: the coin's Quote Asset, the asset the trader pays with, and the trader. */
export type TradeNames = { quoteSymbol: string; paySymbol: string; trader: Address | null };

export const tooSmall = () => new HTTPException(400, { message: "amount is too small to trade" });

export const paused = (symbol: string) =>
  new HTTPException(409, { message: `${symbol} is paused by its issuer, so nothing paired with it can trade until the issuer lifts the pause.` });

/** The refusal a revert becomes: a sentence a trader can act on, and never the bytes. */
export function refusalOf(revert: Revert | null, n: TradeNames): HTTPException {
  const say = (status: 400 | 409, message: string) => new HTTPException(status, { message });
  switch (revert?.name) {
    case "SwapTooSmall":
      return tooSmall();
    case "SwapStoppedEarly":
    case "NotEnoughLiquidity":
      return say(400, "The coin's pool can't fill a trade this large. Try a smaller amount.");
    case "ReferrerFeeOverCap":
      return say(400, `The Referrer Fee this trade names is above this coin's cap of ${String(revert.args[1])} basis points.`);
    case "InvalidReferrer":
    case "MalformedHookData":
      return say(400, "That address can't be named as a trade's referrer.");
    case "NotRegistered":
      return say(409, "This coin's pool isn't one this deployment's contracts trade.");
    case "IsPaused":
      return paused(n.quoteSymbol);
    case "Blocked": {
      const who = String(revert.args[0]);
      const mine = n.trader !== null && who.toLowerCase() === n.trader.toLowerCase();
      return say(409, mine ? `The issuer of ${n.quoteSymbol} has blocked this wallet, so it can't trade a coin paired with it.` : `The issuer of ${n.quoteSymbol} has blocked ${who}, so this trade can't go through.`);
    }
    case "V4TooLittleReceived":
      return say(409, "The price moved past this trade's slippage limit while it was being prepared. Ask for a new quote.");
    case "TransactionDeadlinePassed":
      return say(409, "This trade's deadline has passed. Prepare it again.");
    case "SignatureExpired":
    case "AllowanceExpired":
      return say(400, "This permit has expired. Sign a new one.");
    case "InvalidSigner":
    case "InvalidSignature":
    case "InvalidSignatureLength":
    case "InvalidContractSignature":
      return say(400, "The signature doesn't match the permit this trade was prepared with. Sign it again.");
    case "InvalidNonce":
      return say(400, "This permit has been used or replaced. Sign a new one.");
    case "InsufficientAllowance":
      return say(409, `The router isn't allowed to move this much ${n.paySymbol} yet. Prepare the trade again.`);
    case "Error":
      // Permit2 moves an asset through solmate, which answers one string whatever the asset itself said.
      if (revert.args[0] === "TRANSFER_FROM_FAILED")
        return say(409, `${n.paySymbol} couldn't be moved from this wallet. Check its balance and its approval; an issuer can also pause an asset or block a wallet.`);
      break;
  }
  return say(409, "This trade would fail on the chain as it stands, so nothing was prepared. Ask for a new quote.");
}
