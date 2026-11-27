"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { EVM_NATIVE, type EvmLaunchOptions, type EvmTradeQuote, type LaunchSummary, type PlatformInfo, type PreparedEvmTrade, type TradeSide } from "@launchpad/contract";
import { ApiRequestError, getEvmQuote, getEvmWalletBalances, prepareEvmTrade, reportEvmTransaction } from "@/lib/api";
import { EvmReverted, isRejection, isShortOfFunds, nativeMoved, erc20Moved, type EvmReceipt } from "@/lib/evmWallet";
import { explorerUrl, formatUnits, parseUnits, quoteTicker, type ExplorerTarget } from "@/lib/format";
import { LIQUIDITY_LAUNCH } from "@/lib/liquidityLaunch";
import { rewardSharesTail } from "@/lib/rewardBurn";
import { Disclaimer, hasAcceptedDisclaimer } from "./Disclaimer";
import { useEvmWallet } from "./EvmWalletProvider";
import { NetworkSwitch, onAnotherNetwork } from "./NetworkSwitch";
import { Price } from "./Price";
import { UnauditedStatement } from "./UnauditedStatement";
import { WalletButton } from "./WalletButton";
import styles from "./TradePanel.module.css";

/** What the wallet is asked for: to let Permit2 move the asset (once per asset), to sign this trade's permit, or the trade itself. */
type Ask = "approve" | "permit" | "trade";
type Step =
  | { kind: "editing" }
  | { kind: "preparing" }
  | { kind: "reviewing"; prepared: PreparedEvmTrade }
  | { kind: "signing"; prepared: PreparedEvmTrade; ask: Ask }
  | { kind: "confirming"; prepared: PreparedEvmTrade; ask: "approve" | "trade" };
/**
 * A sent trade, with what it moved as the chain's own receipt says: `coins` into the wallet or out of it, `paid` or
 * received in the Quote Asset; each null when the receipt could not say. `unconfirmed` when it was sent but its receipt
 * could not be followed, so it may well have landed.
 */
type Done = { side: TradeSide; coins: string | null; quote: string | null; hash: string; unconfirmed?: boolean };

const SLIPPAGE_BPS = [50, 100, 200, 500] as const;
/** The presets are shares of what the wallet holds: of the Quote Asset for a buy, never all of it, and of the coin for a sell. */
const BUY_PRESETS = [10, 25, 50] as const;
const SELL_PRESETS = [25, 50, 100] as const;
const QUOTE_DEBOUNCE_MS = 250;
/** While a Launch's Opening Fee runs it falls every second, so the quote is asked again that often. */
const OPENING_REFRESH_MS = 1_000;
/** After a trade the balances are read until the API answers from the trade's block or a later one: this many times, this far apart. */
const BALANCE_READS = 20;
const BALANCE_RETRY_MS = 500;
/** How many times one trade may be prepared: the review's answer, and one more after an approval and after a permit. */
const PREPARE_ROUNDS = 4;
const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const abs = (n: bigint) => (n < 0n ? -n : n);

/** The wallet is on another network than the coin's: nothing is asked of it until it has switched. */
class WrongNetwork extends Error {}
/** The panel's own sentence for something that stopped the trade, shown as it is. */
class Stopped extends Error {}

/**
 * The trade panel for a coin on an EVM chain (#253), a sibling of `TradePanel` with its structure and its words wherever
 * they are true. A buy pays the Quote Asset and a sell pays coins, typed in whole units of what is paid. The quote is
 * read from the chain by the API (Uniswap's own Quoter runs the coin's hook), so "You get about" is what reaches the
 * wallet after every fee, each named with what it is for and its amount, never a rate (the Fees page has those). The API
 * prepares each step and the wallet signs it: an approval once per asset, a permit for the trade, then the trade; the
 * slippage limit is the chain's to enforce. What the panel says a trade moved is read from its receipt, never a quote.
 */
export function EvmTradePanel({
  launch, options, platform, referrer = null, sideRequest = null, onTraded,
}: {
  launch: LaunchSummary;
  /** The coin's chain as the API reads it: its name, its id, its explorer and where its contracts' source is. */
  options: EvmLaunchOptions;
  platform: PlatformInfo;
  /** From the page's `?ref=` link: the address credited the Referrer Fee on the visitor's trades. */
  referrer?: string | null;
  sideRequest?: { side: TradeSide; seq: number } | null;
  onTraded: () => void;
}) {
  const evm = useEvmWallet();
  const connected = evm?.connected ?? null;
  const wallet = connected?.address ?? null;
  const [side, setSide] = useState<TradeSide>("buy");
  const [amountText, setAmountText] = useState("");
  const [slippageBps, setSlippageBps] = useState<number>(100);
  // The quote with what it answers for, so a figure is never shown beside an amount it was not asked for.
  const [answer, setAnswer] = useState<{ key: string; quote: EvmTradeQuote } | null>(null);
  const [quoteError, setQuoteError] = useState<{ key: string; message: string } | null>(null);
  /** Raw units held: the native asset in wei, the Quote Asset (the same for a native pair) and the coin. Null while not known, which holds the presets. */
  const [balances, setBalances] = useState<{ native: bigint; quote: bigint; coins: bigint } | null>(null);
  const [step, setStep] = useState<Step>({ kind: "editing" });
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<Done | null>(null);
  const [disclaimerOpen, setDisclaimerOpen] = useState(false);

  const chain = options.chain;
  const quoteSymbol = quoteTicker(launch.quote);
  const quoteDecimals = launch.quote.decimals;
  const coinDecimals = options.decimals;
  const nativePair = launch.quote.mint.toLowerCase() === EVM_NATIVE;
  const payDecimals = side === "buy" ? quoteDecimals : coinDecimals;
  const getDecimals = side === "buy" ? coinDecimals : quoteDecimals;
  const paySymbol = side === "buy" ? quoteSymbol : launch.symbol;
  const getSymbol = side === "buy" ? launch.symbol : quoteSymbol;
  const amount = parseUnits(amountText, payDecimals);
  const invalidAmount = amountText.trim() !== "" && amount === null;
  const busy = step.kind !== "editing";
  const held = balances ? (side === "buy" ? balances.quote : balances.coins) : null;
  const overBalance = amount !== null && held !== null && amount > held;
  const wrongNetwork = onAnotherNetwork(connected, options.chainId);
  const explorer: ExplorerTarget = { cluster: platform.cluster, rpcUrl: platform.rpcUrl, explorer: options.explorer };
  // A trader never refers themselves; the referral is dropped for the referrer's own wallet.
  const referral = referrer && referrer.toLowerCase() !== wallet?.toLowerCase() ? referrer : null;

  /** The newest read of the balances: an older one that answers after it is dropped. */
  const balanceRead = useRef(0);

  /**
   * Reads the wallet's balances from the API. After a trade, `minBlock` is the block its receipt names: an answer read
   * at an earlier block shows the wallet as it stood before the trade, so the balances are unknown, which holds the
   * presets, until the answer is from that block or a later one.
   */
  const refreshBalances = useCallback(async (minBlock = 0) => {
    const read = ++balanceRead.current;
    const newest = () => balanceRead.current === read;
    if (!wallet) return setBalances(null);
    if (minBlock > 0) setBalances(null);
    for (let attempt = 1; newest(); attempt++) {
      const last = attempt >= BALANCE_READS;
      try {
        const got = await getEvmWalletBalances(chain, wallet, nativePair ? [launch.mint] : [launch.mint, launch.quote.mint]);
        if (!newest()) return;
        if (got.block >= minBlock || last) {
          const of = (address: string) => BigInt(got.assets.find((a) => a.address.toLowerCase() === address.toLowerCase())?.balance ?? "0");
          const native = BigInt(got.native);
          return setBalances({ native, quote: nativePair ? native : of(launch.quote.mint), coins: of(launch.mint) });
        }
      } catch {
        if (!newest()) return;
        if (minBlock === 0 || last) return setBalances(null);
      }
      await pause(BALANCE_RETRY_MS);
    }
  }, [chain, wallet, launch.mint, launch.quote.mint, nativePair]);

  useEffect(() => void refreshBalances(), [refreshBalances]);

  // A review is one wallet's trade: when the wallet changes or goes away, whatever was under review is dropped.
  useEffect(() => {
    setStep((s) => (s.kind === "reviewing" ? { kind: "editing" } : s));
  }, [wallet]);

  // A live quote while the trader types, so what they get and every fee are visible before anything is signed.
  const key = JSON.stringify([launch.mint, side, amount?.toString() ?? null, slippageBps, referral]);
  useEffect(() => {
    if (amount === null) return;
    const abort = new AbortController();
    const timer = setTimeout(async () => {
      try {
        const quote = await getEvmQuote(launch.mint, { side, amount: amount.toString(), slippageBps, referrer: referral }, abort.signal);
        setAnswer({ key, quote });
      } catch (e) {
        if (!abort.signal.aborted) setQuoteError({ key, message: words(e, "Something went wrong reading the quote. Try again in a moment.") });
      }
    }, QUOTE_DEBOUNCE_MS);
    return () => {
      abort.abort();
      clearTimeout(timer);
    };
    // `key` is every input of the read.
  }, [key]);
  const quote = amount !== null && answer?.key === key ? answer.quote : null;
  const quoteProblem = amount !== null && quoteError?.key === key && !quote ? quoteError.message : null;

  // Inside the Opening Fee's window the fee falls every second, so the quote is read again every second until an answer
  // says the window is over. A read still out when the next second comes is left to finish, and a failed one keeps the
  // last answer: the next second asks again.
  const opening = quote?.opening?.endsAt ?? null;
  useEffect(() => {
    if (!opening || amount === null || step.kind !== "editing") return;
    const abort = new AbortController();
    let reading = false;
    const id = setInterval(async () => {
      if (reading) return;
      reading = true;
      try {
        const next = await getEvmQuote(launch.mint, { side, amount: amount.toString(), slippageBps, referrer: referral }, abort.signal);
        if (!abort.signal.aborted) setAnswer({ key, quote: next });
      } catch {
        // keep showing the last quote
      } finally {
        reading = false;
      }
    }, OPENING_REFRESH_MS);
    return () => {
      abort.abort();
      clearInterval(id);
    };
    // `key` is every input of the read.
  }, [opening, key, step.kind]);

  function edit(next: () => void) {
    setError(null);
    setDone(null);
    next();
  }

  // The phone's bar chooses the side as a press on the panel's own control would.
  useEffect(() => {
    if (!sideRequest) return;
    setError(null);
    setDone(null);
    setSide(sideRequest.side);
    setAmountText("");
  }, [sideRequest]);

  /** The check before every send and every signature: the wallet must be on the coin's own chain at that moment. */
  async function onRightChain() {
    if ((await evm!.readChainId()) !== options.chainId) throw new WrongNetwork();
  }

  const request = (trader: string, raw: bigint) => ({ mint: launch.mint, trader, side, amount: raw.toString(), slippageBps, ...(referral ? { referrer: referral } : {}) });

  async function review() {
    if (!evm || !wallet || amount === null) return;
    setStep({ kind: "preparing" });
    try {
      await onRightChain();
      setStep({ kind: "reviewing", prepared: await prepareEvmTrade(request(wallet, amount)) });
    } catch (e) {
      setError(e instanceof WrongNetwork ? `Your wallet is on another network. Switch it to ${options.name}, then try again.` : words(e, "Something went wrong preparing the trade. Try again in a moment."));
      setStep({ kind: "editing" });
    }
  }

  /** What a landed trade moved, from its own receipt: the coin's and the Quote Asset's transfers, or the native asset's change net of the fee. */
  async function moved(receipt: EvmReceipt, trader: string) {
    const coins = abs(erc20Moved(receipt, launch.mint, trader));
    const paid = nativePair ? await nativeMoved(evm!.provider!, receipt, trader) : erc20Moved(receipt, launch.quote.mint, trader);
    return { coins: coins > 0n ? coins.toString() : null, quote: paid === null || paid === 0n ? null : abs(paid).toString() };
  }

  async function signAndSend(first: PreparedEvmTrade) {
    if (!evm || !wallet) return;
    const trader = wallet;
    const body = request(trader, BigInt(first.quote.amountIn));
    const stop = (message: string) => {
      setError(message);
      void refreshBalances();
      setStep({ kind: "editing" });
    };

    const shortOfFunds = `Your wallet doesn't have enough for this trade and its network fee in ${options.native.symbol}. Lower the amount or add ${options.native.symbol}.`;
    let prepared = first;
    try {
      for (let round = 0; !(prepared.step === "trade" && prepared.transaction); round++) {
        if (round >= PREPARE_ROUNDS) throw new Stopped("The trade could not be prepared. Try again in a moment.");
        await onRightChain();
        if (prepared.step === "approve" && prepared.transaction) {
          setStep({ kind: "signing", prepared, ask: "approve" });
          const hash = await evm.sendTransaction(prepared.transaction);
          setStep({ kind: "confirming", prepared, ask: "approve" });
          await evm.waitForReceipt(hash);
          prepared = await prepareEvmTrade(body);
        } else if (prepared.step === "permit" && prepared.permit && prepared.permitDetails) {
          setStep({ kind: "signing", prepared, ask: "permit" });
          const signature = await evm.signTypedData(prepared.permit);
          prepared = await prepareEvmTrade({ ...body, permit: { ...prepared.permitDetails, signature } });
        } else throw new Stopped("The trade could not be prepared. Try again in a moment.");
      }
      await onRightChain();
    } catch (e) {
      if (e instanceof WrongNetwork) return stop(`Your wallet is on another network. Switch it to ${options.name}, then try again.`);
      if (e instanceof EvmReverted) return stop("The approval failed on the chain, so nothing was traded. Try again.");
      if (e instanceof Stopped || e instanceof ApiRequestError) return stop(e.message);
      if (isRejection(e)) return stop("You declined the request in your wallet. Nothing was traded.");
      return stop(isShortOfFunds(e) ? shortOfFunds : "Something went wrong preparing the trade, so nothing was traded. Try again in a moment.");
    }

    setStep({ kind: "signing", prepared, ask: "trade" });
    let hash: string;
    try {
      hash = await evm.sendTransaction(prepared.transaction!);
    } catch (e) {
      // A wallet estimates before it sends, so a price that moved while the trader read the review can fail here, before any fee.
      if (isRejection(e)) return stop("You declined the transaction in your wallet. Nothing was traded.");
      return stop(isShortOfFunds(e) ? shortOfFunds : "Your wallet could not send the trade, so nothing was traded. Check the new quote and try again.");
    }
    setStep({ kind: "confirming", prepared, ask: "trade" });
    let receipt: EvmReceipt;
    try {
      receipt = await evm.waitForReceipt(hash);
    } catch (e) {
      if (e instanceof EvmReverted) {
        setError("The trade failed on the chain, so nothing was traded and only the network fee was charged. The price may have moved past your slippage: try again, or allow more slippage.");
        void refreshBalances(e.receipt.block);
      } else {
        // Sent, but its receipt could not be followed: it may well have landed, so it is never called untraded.
        setDone({ side: prepared.quote.side, coins: null, quote: null, hash, unconfirmed: true });
        setError("The trade was sent, but we lost track of it before it confirmed. Check the transaction before trading again.");
        onTraded();
        void refreshBalances();
      }
      return setStep({ kind: "editing" });
    }
    void refreshBalances(receipt.block);
    // Reported so the trade shows without waiting for the Indexer's next run; the page reads again once it is written.
    void reportEvmTransaction(chain, hash).then(onTraded);
    // The fill can differ from the quote when others trade first, so the panel says what the chain did.
    setDone({ side: prepared.quote.side, ...(await moved(receipt, trader)), hash });
    setAmountText("");
    onTraded();
    setStep({ kind: "editing" });
  }

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setDone(null);
    if (!hasAcceptedDisclaimer()) return setDisclaimerOpen(true);
    void review();
  }

  const r = step.kind === "reviewing" || step.kind === "signing" || step.kind === "confirming" ? step.prepared : null;
  const shown = r?.quote ?? quote;
  const taxName = shown?.tax === "liquidity" ? LIQUIDITY_LAUNCH.tax : "Reward Tax";
  // The fees, each by name with what it is for and its amount (owner, 2026-10-30: no rate anywhere but the Fees page).
  // A line whose amount is zero is left out. Uniswap's protocol fee is in whichever asset the trader pays with.
  const feeLines: { name: string; what: string; raw: string; decimals: number; symbol: string }[] = shown
    ? [
        { name: "Platform Fee", what: "to the platform and the Creator", raw: shown.fees.platform, decimals: quoteDecimals, symbol: quoteSymbol },
        {
          name: taxName, raw: shown.fees.tax, decimals: quoteDecimals, symbol: quoteSymbol,
          what: shown.tax === "liquidity" ? `into ${launch.symbol}'s own pool` : `to ${launch.symbol}'s holders${rewardSharesTail(launch.rewardTax?.burnBps ?? 0, launch.rewardTax?.liquidityBps ?? 0)}`,
        },
        { name: "Opening Fee", what: `into ${launch.symbol}'s own liquidity`, raw: shown.fees.opening, decimals: quoteDecimals, symbol: quoteSymbol },
        { name: "Referrer Fee", what: "to the address that brought this trade", raw: shown.fees.referrer, decimals: quoteDecimals, symbol: quoteSymbol },
        {
          name: "Uniswap's protocol fee", what: "set and kept by Uniswap", raw: shown.protocolFee.amount,
          decimals: shown.protocolFee.asset === "quote" ? quoteDecimals : coinDecimals, symbol: shown.protocolFee.asset === "quote" ? quoteSymbol : launch.symbol,
        },
      ].filter((line) => BigInt(line.raw) > 0n)
    : [];

  const confirmation = done && (
    <p className={styles.done} role="status" data-coins={done.coins ?? undefined} data-quote={done.quote ?? undefined}>
      {done.unconfirmed ? (
        <>Sent a {done.side} of {launch.symbol}, not yet confirmed. </>
      ) : (
        <>
          {done.side === "buy" ? "Bought" : "Sold"}{" "}
          {done.coins && <><span className="mono">{formatUnits(done.coins, coinDecimals, 0)}</span>{" "}</>}
          {launch.symbol}
          {done.quote && <> for <span className="mono">{formatUnits(done.quote, quoteDecimals, 6)}</span> {quoteSymbol}</>}.{" "}
        </>
      )}
      <a href={explorerUrl("tx", done.hash, explorer)} target="_blank" rel="noreferrer">View transaction</a>
    </p>
  );

  return (
    <section className={`card card-raised ${styles.card}`} aria-labelledby="trade-title">
      <h2 id="trade-title" className="visually-hidden">Trade {launch.symbol}</h2>
      <form className={styles.form} onSubmit={onSubmit} aria-busy={busy}>
        <div className={styles.sides} role="group" aria-label="Buy or sell">
          {(["buy", "sell"] as const).map((s) => (
            <button key={s} type="button" aria-pressed={side === s} className={styles[s]} disabled={busy} onClick={() => edit(() => { setSide(s); setAmountText(""); })}>
              {s === "buy" ? "Buy" : "Sell"}
            </button>
          ))}
        </div>

        <fieldset className={styles.fields} disabled={busy}>
          <div className={styles.amountHead}>
            <label htmlFor="trade-amount">You pay</label>
            {held !== null && (
              <span className={styles.balance}>
                Balance <span className="mono">{formatUnits(held.toString(), payDecimals)}</span> {paySymbol}
              </span>
            )}
          </div>
          <div className={`input ${styles.amount} ${invalidAmount || overBalance ? "invalid" : ""}`}>
            <input
              id="trade-amount"
              className="mono"
              inputMode="decimal"
              autoComplete="off"
              placeholder="0.00"
              value={amountText}
              onChange={(e) => edit(() => setAmountText(e.target.value.replace(",", ".")))}
              aria-invalid={invalidAmount || overBalance}
              aria-describedby="trade-amount-hint"
            />
            <span className={styles.unit}>{paySymbol}</span>
          </div>
          <p id="trade-amount-hint" className={invalidAmount || overBalance ? styles.hintError : styles.hint}>
            {invalidAmount
              ? `Enter an amount above zero with up to ${payDecimals} decimal places.`
              : overBalance
                ? held === 0n
                  ? `Your wallet has no ${paySymbol}.`
                  : `You have ${formatUnits(held!.toString(), payDecimals)} ${paySymbol}. Enter a smaller amount.`
                : side === "buy"
                  ? `Paid in ${quoteSymbol}, fees included.`
                  : "The coins you sell go to the coin's own pool."}
          </p>
          <div className={styles.presets}>
            {(side === "buy" ? BUY_PRESETS : SELL_PRESETS).map((pct) => (
              <button
                key={pct}
                type="button"
                className="chip"
                disabled={!held || held === 0n}
                onClick={() => edit(() => setAmountText(formatUnits(((held! * BigInt(pct)) / 100n).toString(), payDecimals, payDecimals).replace(/,/g, "")))}
              >
                {pct === 100 ? "All" : `${pct}%`}
              </button>
            ))}
          </div>

          <div className={`${styles.option} ${styles.slippage}`}>
            <span id="slippage-label">Slippage</span>
            <div role="group" aria-labelledby="slippage-label">
              {SLIPPAGE_BPS.map((bps) => (
                <button key={bps} type="button" className="chip" aria-pressed={slippageBps === bps} onClick={() => edit(() => setSlippageBps(bps))}>
                  {bps / 100}%
                </button>
              ))}
            </div>
          </div>
        </fieldset>

        <div className={styles.quote} aria-live="polite">
          {quoteProblem ? (
            <p className={styles.quoteError}>{quoteProblem}</p>
          ) : shown ? (
            <dl>
              <div className={styles.receive}>
                <dt>You get about</dt>
                <dd data-amount-out={shown.amountOut}>
                  <span className="mono">{formatUnits(shown.amountOut, getDecimals, side === "buy" ? 0 : 6)}</span> {getSymbol}
                </dd>
              </div>
              <div>
                <dt>At least</dt>
                <dd data-min-amount-out={shown.minAmountOut}>
                  <span className="mono">{formatUnits(shown.minAmountOut, getDecimals, side === "buy" ? 0 : 6)}</span> {getSymbol}
                </dd>
              </div>
              <div>
                <dt>Price</dt>
                <dd>
                  <Price className="mono" value={shown.averagePrice} /> {quoteSymbol}
                </dd>
              </div>
              {feeLines.map((line, i) => (
                <div key={line.name} className={i === 0 ? styles.group : undefined} data-fee={line.name}>
                  <dt>{`${line.name}, ${line.what}`}</dt>
                  <dd>
                    <span className="mono">{formatUnits(line.raw, line.decimals, 6)}</span> {line.symbol}
                  </dd>
                </div>
              ))}
              <div className={styles.fee}>
                <dt>Every fee is already taken out of what you get</dt>
                <dd><Link href="/fees" className={styles.feeLink}>Every fee, explained</Link></dd>
              </div>
            </dl>
          ) : (
            <p className={styles.quoteHint}>Enter an amount to see what you get and every fee you pay.</p>
          )}
          {shown?.opening && BigInt(shown.fees.opening) > 0n && (
            <p className={styles.completes} data-opening-fee="">
              {`The Opening Fee is running. It falls every second until `}
              <time dateTime={shown.opening.endsAt}>{new Date(shown.opening.endsAt).toLocaleTimeString("en-US")}</time>
              {`, all of it goes into ${launch.symbol}'s own liquidity, and a buy that lands later pays less.`}
            </p>
          )}
        </div>

        {error && (
          <p className={styles.error} role="alert">
            {error}
          </p>
        )}
        {confirmation}

        <UnauditedStatement chain={options.name} source={options.contracts.source} />

        {r ? (
          <div className={styles.review} role="region" aria-label="Review your trade">
            <p>
              {r.quote.side === "buy"
                ? `Your wallet pays ${formatUnits(r.quote.amountIn, quoteDecimals, quoteDecimals)} ${quoteSymbol}, and the network fee in ${options.native.symbol}.`
                : `Your wallet pays ${formatUnits(r.quote.amountIn, coinDecimals, coinDecimals)} ${launch.symbol} and the network fee in ${options.native.symbol}, and receives about ${formatUnits(r.quote.amountOut, quoteDecimals, 6)} ${quoteSymbol}.`}{" "}
              {askWords(r.step, paySymbol)}{" "}
              {`If the price moves more than ${r.quote.slippageBps / 100}% first, the chain refuses the trade and nothing is traded.`}
            </p>
            <div className={styles.actions}>
              <button type="button" className="button button-ghost button-lg" onClick={() => setStep({ kind: "editing" })} disabled={step.kind !== "reviewing"}>
                Edit
              </button>
              <button type="button" className={`button button-primary button-lg ${styles.primary}`} onClick={() => void signAndSend(r)} disabled={step.kind !== "reviewing"}>
                {step.kind === "signing"
                  ? step.ask === "approve" ? "Approve in your wallet…" : step.ask === "permit" ? "Sign the permit in your wallet…" : "Confirm in your wallet…"
                  : step.kind === "confirming"
                    ? step.ask === "approve" ? "Approving…" : "Confirming…"
                    : side === "buy" ? "Sign and buy" : "Sign and sell"}
              </button>
            </div>
          </div>
        ) : !connected ? (
          <div className={styles.connect}>
            <p>Connect a wallet to trade.</p>
            <WalletButton variant="inline" family="evm" />
          </div>
        ) : wrongNetwork && step.kind === "editing" ? (
          <NetworkSwitch name={options.name} chain={options.wallet} />
        ) : (
          <button type="submit" className={`button button-primary button-lg ${styles.primary}`} disabled={busy || amount === null || overBalance || !quote}>
            {step.kind === "preparing" ? "Preparing…" : side === "buy" ? "Review buy" : "Review sell"}
          </button>
        )}
      </form>

      <Disclaimer
        action="trade"
        open={disclaimerOpen}
        onCancel={() => setDisclaimerOpen(false)}
        onAccept={() => {
          setDisclaimerOpen(false);
          void review();
        }}
      />
    </section>
  );
}

/** What the review says the wallet will be asked for, by the step the API answered. */
function askWords(step: PreparedEvmTrade["step"], paySymbol: string) {
  if (step === "approve") return `Your wallet is asked three times: an approval of ${paySymbol}, once for this asset and never again, then a permit for this trade, which costs no gas, then the trade.`;
  if (step === "permit") return "Your wallet is asked twice: a permit for this trade, which is a signature and costs no gas, then the trade.";
  return "Your wallet is asked once.";
}

/** An API refusal is its own sentence, shown as it is; anything else is said in the panel's words. */
function words(e: unknown, otherwise: string) {
  return e instanceof ApiRequestError && e.message ? e.message : otherwise;
}
