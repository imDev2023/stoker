import { decodeFunctionResult, encodeFunctionData, erc20Abi, parseAbi, type Address, type Hex } from "viem";
import { stokerHookAbi } from "@launchpad/evm";
import type { EvmContext } from "./context";

/**
 * A trade's reads on an EVM chain (#253): everything a quote shows comes from one `eth_call` through Multicall3, so
 * every figure is of one block and one second. Each read may fail on its own (`allowFailure`), so a swap the hook
 * refuses comes back as its revert data beside the terms and the price that explain it.
 */

/** One read of a batch: the contract, the call, and how its answer is read. */
export type Read<T> = { target: Address; callData: Hex; decode: (data: Hex) => T };
/** What one read answered: its value, or the revert data the contract refused it with (empty when it had none). */
export type Answer<T> = { ok: true; value: T } | { ok: false; data: Hex };
type AnswerOf<X> = X extends Read<infer T> ? Answer<T> : null;

/** Multicall3 (mds1/multicall): `aggregate3` is payable on the chain and read here with `eth_call`, so it is declared a view. */
const multicallAbi = parseAbi([
  "struct Call3 { address target; bool allowFailure; bytes callData; }",
  "struct Result { bool success; bytes returnData; }",
  "function aggregate3(Call3[] calls) view returns (Result[] returnData)",
  "function getCurrentBlockTimestamp() view returns (uint256 timestamp)",
  "function getEthBalance(address addr) view returns (uint256 balance)",
  "function getBasefee() view returns (uint256 basefee)",
]);

/**
 * Runs every read named in `reads` in one `eth_call`, at one block, and answers each under its own name; a name given
 * null is left out and answered null. A read that reverted, or answered something its ABI cannot read (an address with
 * no code answers nothing), is `ok: false` with the bytes it returned.
 */
export async function readTogether<R extends Record<string, Read<unknown> | null>>(x: EvmContext, reads: R): Promise<{ [K in keyof R]: AnswerOf<R[K]> }> {
  const named = Object.entries(reads).filter((e): e is [string, Read<unknown>] => e[1] !== null);
  const results = await x.client.readContract({
    address: x.config.profile.multicall3, abi: multicallAbi, functionName: "aggregate3",
    args: [named.map(([, r]) => ({ target: r.target, allowFailure: true, callData: r.callData }))],
  });
  const answers: Record<string, Answer<unknown> | null> = Object.fromEntries(Object.keys(reads).map((name) => [name, null]));
  named.forEach(([name, r], i) => {
    const { success, returnData } = results[i]!;
    if (!success) {
      answers[name] = { ok: false, data: returnData };
      return;
    }
    try {
      answers[name] = { ok: true, value: r.decode(returnData) };
    } catch {
      answers[name] = { ok: false, data: returnData };
    }
  });
  return answers as { [K in keyof R]: AnswerOf<R[K]> };
}

/** Uniswap's periphery on the chain, the three reads a trade needs of it (contracts/test/fork/RouterLib.sol). */
const quoterAbi = parseAbi([
  "function quoteExactInputSingle(((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) returns (uint256 amountOut, uint256 gasEstimate)",
]);
const stateViewAbi = parseAbi(["function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)"]);
const permit2Abi = parseAbi(["function allowance(address user, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)"]);
/** An asset its issuer can pause says so itself (a Stock Token's `paused()` is its own flag or its registry's). */
const pausableAbi = parseAbi(["function paused() view returns (bool)"]);

export type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };

/** The Launch's terms as the hook holds them. */
export const termsRead = (hook: Address, poolId: Hex) => ({
  target: hook,
  callData: encodeFunctionData({ abi: stokerHookAbi, functionName: "termsOf", args: [poolId] }),
  decode: (data: Hex) => decodeFunctionResult({ abi: stokerHookAbi, functionName: "termsOf", data }),
});

/** The pool's price and Uniswap's protocol fee in force on it (both directions, twelve bits each). */
export const slot0Read = (x: EvmContext, poolId: Hex) => ({
  target: x.config.profile.uniswap.stateView,
  callData: encodeFunctionData({ abi: stateViewAbi, functionName: "getSlot0", args: [poolId] }),
  decode: (data: Hex) => {
    const [sqrtPriceX96, , protocolFee] = decodeFunctionResult({ abi: stateViewAbi, functionName: "getSlot0", data });
    return { sqrtPriceX96, protocolFee };
  },
});

/** What an exact-in swap delivers: the V4 Quoter runs the swap, our hook in it, and answers what the trader receives. */
export const swapOutRead = (x: EvmContext, poolKey: PoolKey, zeroForOne: boolean, exactAmount: bigint, hookData: Hex) => ({
  target: x.config.profile.uniswap.v4Quoter,
  callData: encodeFunctionData({ abi: quoterAbi, functionName: "quoteExactInputSingle", args: [{ poolKey, zeroForOne, exactAmount, hookData }] }),
  decode: (data: Hex) => decodeFunctionResult({ abi: quoterAbi, functionName: "quoteExactInputSingle", data })[0],
});

const ofMulticall = <T>(x: EvmContext, callData: Hex, decode: (data: Hex) => T): Read<T> => ({ target: x.config.profile.multicall3, callData, decode });

/** The time of the block the batch ran in: the second every fee in it was taken at. */
export const blockTimeRead = (x: EvmContext) =>
  ofMulticall(x, encodeFunctionData({ abi: multicallAbi, functionName: "getCurrentBlockTimestamp" }), (data) =>
    decodeFunctionResult({ abi: multicallAbi, functionName: "getCurrentBlockTimestamp", data }));

export const baseFeeRead = (x: EvmContext) =>
  ofMulticall(x, encodeFunctionData({ abi: multicallAbi, functionName: "getBasefee" }), (data) => decodeFunctionResult({ abi: multicallAbi, functionName: "getBasefee", data }));

export const nativeBalanceRead = (x: EvmContext, who: Address) =>
  ofMulticall(x, encodeFunctionData({ abi: multicallAbi, functionName: "getEthBalance", args: [who] }), (data) =>
    decodeFunctionResult({ abi: multicallAbi, functionName: "getEthBalance", data }));

export const balanceRead = (asset: Address, who: Address) => ({
  target: asset,
  callData: encodeFunctionData({ abi: erc20Abi, functionName: "balanceOf", args: [who] }),
  decode: (data: Hex) => decodeFunctionResult({ abi: erc20Abi, functionName: "balanceOf", data }),
});

export const allowanceRead = (asset: Address, owner: Address, spender: Address) => ({
  target: asset,
  callData: encodeFunctionData({ abi: erc20Abi, functionName: "allowance", args: [owner, spender] }),
  decode: (data: Hex) => decodeFunctionResult({ abi: erc20Abi, functionName: "allowance", data }),
});

/** What Permit2 lets `spender` move of `owner`'s asset, until when, and the nonce the owner's next permit must carry. */
export const permit2AllowanceRead = (x: EvmContext, owner: Address, asset: Address, spender: Address) => ({
  target: x.config.profile.uniswap.permit2,
  callData: encodeFunctionData({ abi: permit2Abi, functionName: "allowance", args: [owner, asset, spender] }),
  decode: (data: Hex) => {
    const [amount, expiration, nonce] = decodeFunctionResult({ abi: permit2Abi, functionName: "allowance", data });
    return { amount, expiration: BigInt(expiration), nonce: BigInt(nonce) };
  },
});

export const pausedRead = (asset: Address) => ({
  target: asset,
  callData: encodeFunctionData({ abi: pausableAbi, functionName: "paused" }),
  decode: (data: Hex) => decodeFunctionResult({ abi: pausableAbi, functionName: "paused", data }),
});
