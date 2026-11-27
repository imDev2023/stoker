"use client";

import { useEffect, useState } from "react";
import type { CreatorEarningsDestination, EvmLaunchOptions, EvmLaunchQuote, EvmQuoteOption, RewardPayoutAsset } from "@launchpad/contract";
import { getEvmLaunchQuote } from "@/lib/api";
import { LOCK_TIME_STEPS, lockSchedule, lockSentence, lockShare, lockSizes, lockTime, lockTimes, type LockUnlock } from "@/lib/creatorLock";
import { DESTINATION_NAMES, destinationChoiceLine } from "@/lib/earnings";
import { formatUnits, parseUnits, quoteTicker } from "@/lib/format";
import { LIQUIDITY_LAUNCH, liquidityLine } from "@/lib/liquidityLaunch";
import { burnShareTitle, burnShareWords } from "@/lib/rewardBurn";
import { OptionRow } from "./OptionRow";
import { QuoteLogo } from "./QuoteLogo";
import chooser from "./QuoteChooser.module.css";
import styles from "./LaunchOptions.module.css";

const QUOTE_DEBOUNCE_MS = 250;

/** What a row's tag calls a Quote Asset on an EVM chain: the chain's own name for its tokenized stocks, and nothing else for them (ADR 0028). */
function kindOf(quote: EvmQuoteOption, options: EvmLaunchOptions) {
  if (quote.native) return "Native asset";
  if (quote.category === "tokenized_stock") return options.stockName ?? "Stock";
  if (quote.category === "stablecoin") return "Stablecoin";
  return null;
}

/** A share of a coin's supply as the summary writes one: whole hundredths of a percent, cut, and "<0.01%" for a trace. */
export function evmSupplyShare(raw: bigint, supply: bigint) {
  const basisPoints = supply > 0n ? Number((raw * 10_000n) / supply) : 0;
  if (raw > 0n && basisPoints === 0) return "<0.01%";
  return `${(basisPoints / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })}%`;
}

/** The lock times a chain allows, from the form's steps: the whole time at least the chain's least, each part at most its most. */
function evmLockTimes(unlock: LockUnlock, limits: EvmLaunchOptions["creatorLock"]) {
  return lockTimes(unlock).filter((seconds) => {
    const { cliffSeconds, unlockSeconds } = lockSchedule(seconds, unlock);
    return seconds >= limits.minSeconds && cliffSeconds <= limits.maxPartSeconds && unlockSeconds <= limits.maxPartSeconds;
  });
}

/**
 * The launch modes on an EVM chain's launch form (#253): the launch type, where the Creator's earnings go, the Creator
 * Lock and a First Buy in the Quote Asset, each within what the chain's contracts offer (`EvmLaunchOptions`), with the
 * live launch quote: what a First Buy buys and what the launch costs in the chain's native asset. The Solana form's
 * hook is `useLaunchOptions`; the two share their words where the words are true on both, and nothing else.
 */
export function useEvmLaunchOptions(options: EvmLaunchOptions, quote: EvmQuoteOption | null, creator: string | null) {
  const [rewardTax, setRewardTaxState] = useState<number | null>(null);
  // A Stoke Launch's tax, all of it the coin's own liquidity: null unless that type is chosen, and then the Reward Tax is null.
  const [liquidityTax, setLiquidityTaxState] = useState<number | null>(null);
  const [rewardPayout, setRewardPayout] = useState<RewardPayoutAsset>(options.payoutAssets[0] ?? "coin");
  const [rewardBurn, setRewardBurn] = useState(0);
  const [rewardLiquidity, setRewardLiquidity] = useState(0);
  const [earningsDestination, setEarningsDestination] = useState<CreatorEarningsDestination>(options.destinations[0] ?? "wallet");
  const [lockOn, setLockOn] = useState(false);
  const [lockBpsChosen, setLockBps] = useState(0);
  const [lockSeconds, setLockSeconds] = useState<number>(LOCK_TIME_STEPS[2]);
  const [lockUnlock, setLockUnlockState] = useState<LockUnlock>("once");
  const [firstBuyText, setFirstBuyText] = useState("");
  // The launch quote with what it answers for, so a figure is never shown beside choices it was not asked for.
  const [answer, setAnswer] = useState<{ key: string; quote: EvmLaunchQuote } | null>(null);
  const [quoteError, setQuoteError] = useState<{ key: string; message: string } | null>(null);

  const symbol = quote ? quoteTicker(quote) : null;
  const firstBuy = quote ? parseUnits(firstBuyText, quote.decimals) : null;
  const firstBuyInvalid = quote !== null && firstBuyText.trim() !== "" && firstBuy === null;

  const sizes = lockSizes(options.creatorLock.maxBps);
  const lockOffered = sizes.length > 0;
  const lockActive = lockOffered && lockOn;
  const times = evmLockTimes(lockUnlock, options.creatorLock);
  const lockProblem = lockActive && lockBpsChosen <= 0
    ? "Choose how much of the supply to lock, or turn the lock off."
    : lockActive && !times.includes(lockSeconds)
      ? "Choose how long the lock lasts."
      : null;
  const lockBps = lockActive && lockBpsChosen > 0 && !lockProblem ? lockBpsChosen : null;
  // Holders keep the rest of every reward: the two shares together are at most what the chain allows.
  const sharesProblem = rewardTax !== null && rewardBurn + rewardLiquidity > options.sharesMaxBps
    ? `Burned and to liquidity can be ${burnShareWords(options.sharesMaxBps) ?? `${options.sharesMaxBps / 100}%`} of every reward together, at most. Choose smaller shares.`
    : null;
  const taxBps = liquidityTax ?? rewardTax ?? 0;

  // The launch quote, asked again as the choices change: the Listing's figures, what a First Buy buys after the Platform
  // Fee and the coin's tax, and the launch's cost, estimated from the Creator's wallet once one is connected.
  const quoteAddress = quote?.mint ?? null;
  const key = JSON.stringify([options.chain, quoteAddress, creator, firstBuy?.toString() ?? null, taxBps, lockBps]);
  useEffect(() => {
    if (quoteAddress === null) return;
    const abort = new AbortController();
    const timer = setTimeout(async () => {
      try {
        const got = await getEvmLaunchQuote(options.chain, { quote: quoteAddress, creator, firstBuy: firstBuy?.toString() ?? null, taxBps, lockBps: lockBps ?? 0 }, abort.signal);
        setAnswer({ key, quote: got });
      } catch (e) {
        if (!abort.signal.aborted) setQuoteError({ key, message: (e as Error).message });
      }
    }, QUOTE_DEBOUNCE_MS);
    return () => {
      abort.abort();
      clearTimeout(timer);
    };
    // `key` is every input of the read.
  }, [key]);
  const launchQuote = answer?.key === key ? answer.quote : null;
  const firstBuyQuote = firstBuy !== null ? (launchQuote?.firstBuy ?? null) : null;
  const firstBuyProblem = firstBuyInvalid
    ? `Enter a first buy above zero with up to ${quote!.decimals} decimal places.`
    : firstBuy !== null && quoteError?.key === key ? quoteError.message : null;

  return {
    options, quote, symbol,
    rewardTax, rewardPayout, setRewardPayout, rewardBurn, setRewardBurn, rewardLiquidity, setRewardLiquidity, sharesProblem,
    /** A Reward Launch at this rate, or with null a standard coin: either way the coin is no Stoke Launch. */
    setRewardTax: (bps: number | null) => {
      setRewardTaxState(bps);
      setLiquidityTaxState(null);
    },
    liquidityTax,
    /** A Stoke Launch at this rate, so no Reward Launch; it pays its holders nothing, so its earnings can't go to them either. */
    setLiquidityTax: (bps: number) => {
      setLiquidityTaxState(bps);
      setRewardTaxState(null);
      if (earningsDestination === "holders") setEarningsDestination(options.destinations.find((d) => d !== "holders") ?? "wallet");
    },
    earningsDestination, setEarningsDestination,
    lockOffered, lockSizes: sizes, lockTimes: times, lockOn: lockActive, setLockOn: (on: boolean) => {
      setLockOn(on);
      if (on && !sizes.includes(lockBpsChosen)) setLockBps(sizes[0] ?? 0);
      if (on && !times.includes(lockSeconds)) setLockSeconds(times[0] ?? lockSeconds);
    },
    lockBpsChosen, setLockBps, lockSeconds, setLockSeconds, lockProblem,
    lockUnlock, setLockUnlock: (unlock: LockUnlock) => {
      setLockUnlockState(unlock);
      const next = evmLockTimes(unlock, options.creatorLock);
      if (!next.includes(lockSeconds)) setLockSeconds(next[0] ?? lockSeconds);
    },
    /** The lock the launch will carry, or null: its size, its time and how it unlocks, from Graduation. */
    lock: lockBps === null ? null : { bps: lockBps, ...lockSchedule(lockSeconds, lockUnlock) },
    firstBuyText, setFirstBuyText, firstBuy, firstBuyQuote, firstBuyProblem,
    /** The Listing's figures and the launch's cost as the choices stand; null until the API has answered for them. */
    launchQuote,
    /** What stops the launch from being prepared, if anything. */
    problem: sharesProblem ?? lockProblem ?? firstBuyProblem,
    /** The form fields these options add to the prepare request, by the names the Solana form's carry. */
    fields(): [string, string][] {
      const out: [string, string][] = [];
      if (liquidityTax !== null) out.push(["liquidityTax", String(liquidityTax)]);
      else if (rewardTax !== null) out.push(
          ["rewardTax", String(rewardTax)], ["rewardPayout", rewardPayout], ["rewardBurn", String(rewardBurn)], ["rewardLiquidity", String(rewardLiquidity)],
        );
      if (earningsDestination !== "wallet") out.push(["earningsDestination", earningsDestination]);
      if (lockBps !== null) {
        const { cliffSeconds, unlockSeconds } = lockSchedule(lockSeconds, lockUnlock);
        out.push(["lockBps", String(lockBps)], ["lockCliffSeconds", String(cliffSeconds)]);
        if (unlockSeconds > 0) out.push(["lockUnlockSeconds", String(unlockSeconds)]);
      }
      if (firstBuy !== null) out.push(["firstBuy", firstBuy.toString()]);
      return out;
    },
  };
}

export type EvmLaunchOptionsState = ReturnType<typeof useEvmLaunchOptions>;

/**
 * The Quote Assets an EVM chain's Quote Registry lists, as rows: the native asset first, each with its kind at its end,
 * in the chain's own words ("Stock Tokens" on Robinhood Chain). The list is the chain's, read by the API from its
 * contracts; nothing here offers an asset the chain does not list.
 */
export function EvmQuoteChooser({ options, value, onChange, labelId }: { options: EvmLaunchOptions; value: string | null; onChange: (address: string) => void; labelId: string }) {
  if (options.quotes.length === 0) return <p className={styles.hint}>{`${options.name} lists no Quote Asset yet, so nothing can launch there for now.`}</p>;
  return (
    <div className={chooser.chooser}>
      <div className={chooser.rows} role="radiogroup" aria-labelledby={labelId}>
        {options.quotes.map((q) => {
          const kind = kindOf(q, options);
          return (
            <OptionRow key={q.mint} name="evm-quote" value={q.mint} checked={q.mint === value} onChange={() => onChange(q.mint)} end={kind ? <span className="tag">{kind}</span> : undefined}>
              <QuoteLogo quote={q} size={32} />
              <span className={chooser.rowTicker}>{quoteTicker(q)}</span>
            </OptionRow>
          );
        })}
      </div>
    </div>
  );
}

/**
 * The launch type on an EVM chain: a standard coin, a Reward Launch in each Payout Asset the chain offers, and a Stoke
 * Launch, then the type's own terms at the chain's rates and steps. On an EVM chain the tax is taken in the Quote Asset
 * from every trade in the coin's own pool, and what goes to liquidity is Support Liquidity from the first trade, so the
 * lines under the rates say that and not Solana's.
 */
export function EvmLaunchType({ options: o, coin, labelId }: { options: EvmLaunchOptionsState; coin: string; labelId: string }) {
  const coinLabel = coin || "the coin";
  const quoteLabel = o.symbol ?? "its pair";
  const reward = o.rewardTax !== null;
  const liquidity = o.liquidityTax !== null;
  const rates = o.options.taxRatesBps;
  // A rate picked under one type stays picked under the other: the Creator changed what the tax is for, not its size.
  const rate = o.rewardTax ?? o.liquidityTax ?? rates[0];
  const payouts = o.options.payoutAssets;

  return (
    <div className={styles.type}>
      <div className={styles.types} role="radiogroup" aria-labelledby={labelId}>
        <OptionRow name="launch-type" value="standard" checked={!reward && !liquidity} onChange={() => o.setRewardTax(null)}>
          <span><b>Standard</b></span>
        </OptionRow>
        {rate !== undefined && payouts.map((payout) => (
          <OptionRow key={payout} name="launch-type" value={payout} checked={reward && o.rewardPayout === payout} onChange={() => { o.setRewardTax(rate); o.setRewardPayout(payout); }}>
            <span><b>Reward Launch</b>, paid in {payout === "coin" ? "the coin" : quoteLabel}</span>
          </OptionRow>
        ))}
        {rate !== undefined && (
          <OptionRow name="launch-type" value="liquidity" checked={liquidity} onChange={() => o.setLiquidityTax(rate)}>
            <span><b>{LIQUIDITY_LAUNCH.name}</b>, {LIQUIDITY_LAUNCH.short}</span>
          </OptionRow>
        )}
      </div>
      {liquidity && (
        <div className={styles.rates} role="group" aria-label={LIQUIDITY_LAUNCH.tax}>
          <span className={styles.ratesLabel} aria-hidden>{LIQUIDITY_LAUNCH.tax}</span>
          <div className={`segmented ${styles.segmented}`}>
            {rates.map((bps) => (
              <button key={bps} type="button" aria-pressed={o.liquidityTax === bps} onClick={() => o.setLiquidityTax(bps)}>
                {bps / 100}%
              </button>
            ))}
          </div>
          <p className={styles.hint}>
            {`${coin ? liquidityLine(coin) : LIQUIDITY_LAUNCH.line} It is taken in ${quoteLabel} from every trade in the coin's own pool and added from the first trade, as Support Liquidity just under the price. Fixed at launch, like the rate.`}
          </p>
        </div>
      )}
      {reward && (
        <div className={styles.rates} role="group" aria-label="Reward Tax">
          <span className={styles.ratesLabel} aria-hidden>Reward Tax</span>
          <div className={`segmented ${styles.segmented}`}>
            {rates.map((bps) => (
              <button key={bps} type="button" aria-pressed={o.rewardTax === bps} onClick={() => o.setRewardTax(bps)}>
                {bps / 100}%
              </button>
            ))}
          </div>
          <p className={styles.hint}>
            {o.rewardPayout === "coin"
              ? `The tax is taken in ${quoteLabel} from every trade in the coin's own pool and buys ${coinLabel}, which holders are paid. Fixed at launch, like the rate.`
              : `The tax is taken in ${quoteLabel} from every trade in the coin's own pool, and holders are paid in ${quoteLabel} as it was collected. Fixed at launch, like the rate.`}
          </p>
        </div>
      )}
      {reward && (
        <div className={styles.rates} role="group" aria-label="Reward Burn">
          <span className={styles.ratesLabel} aria-hidden>Burned</span>
          <div className={`segmented ${styles.segmented}`}>
            {o.options.shareStepsBps.map((bps) => (
              <button key={bps} type="button" aria-pressed={o.rewardBurn === bps} onClick={() => o.setRewardBurn(bps)}>
                {bps === 0 ? "None" : `${bps / 100}%`}
              </button>
            ))}
          </div>
          <p className={styles.hint}>
            {o.rewardBurn === 0
              ? `Burn a share of every reward instead of paying it out, to take ${coinLabel} out of circulation. Fixed at launch.`
              : `${burnShareTitle(o.rewardBurn) ?? `${o.rewardBurn / 100}%`} of every reward buys ${coinLabel} and burns it, and holders are paid the rest. Fixed at launch.`}
          </p>
        </div>
      )}
      {reward && (
        <div className={styles.rates} role="group" aria-label="Reward Liquidity">
          <span className={styles.ratesLabel} aria-hidden>To liquidity</span>
          <div className={`segmented ${styles.segmented}`}>
            {o.options.shareStepsBps.map((bps) => (
              <button key={bps} type="button" aria-pressed={o.rewardLiquidity === bps} onClick={() => o.setRewardLiquidity(bps)}>
                {bps === 0 ? "None" : `${bps / 100}%`}
              </button>
            ))}
          </div>
          {o.sharesProblem ? (
            <p className={styles.hintError} role="alert">{o.sharesProblem}</p>
          ) : (
            <p className={styles.hint}>
              {o.rewardLiquidity === 0
                ? `Add a share of every reward to ${coinLabel}'s pool as locked liquidity, to deepen its market. Fixed at launch.`
                : `${burnShareTitle(o.rewardLiquidity) ?? `${o.rewardLiquidity / 100}%`} of every reward is added to ${coinLabel}'s pool from the first trade, as Support Liquidity locked for good. Fixed at launch.`}
            </p>
          )}
        </div>
      )}
    </div>
  );
}

/**
 * Where the Creator's earnings on the coin go, from the destinations the chain's contracts offer today, in the form's
 * order: only those, so the others take their rows the day the chain offers them. A Stoke Launch is not offered its
 * holders, since it pays them nothing.
 */
export function EvmEarningsChoice({ options: o, coin, labelId }: { options: EvmLaunchOptionsState; coin: string; labelId: string }) {
  const coinLabel = coin || "the coin";
  const quoteLabel = o.symbol ?? "its pair";
  return (
    <div className={styles.type}>
      <div className={styles.types} role="radiogroup" aria-labelledby={labelId}>
        {o.options.destinations.filter((destination) => destination !== "holders" || o.liquidityTax === null).map((destination) => (
          <OptionRow key={destination} name="earnings-destination" value={destination} checked={o.earningsDestination === destination} onChange={() => o.setEarningsDestination(destination)}>
            <span className={styles.choice}>
              <b>{DESTINATION_NAMES[destination]}</b>{" "}
              <span className={styles.choiceLine}>{destinationChoiceLine(destination, coinLabel, quoteLabel)}</span>
            </span>
          </OptionRow>
        ))}
      </div>
      <p className={styles.hint}>Fixed at launch: where a coin&apos;s earnings go can never be changed.</p>
    </div>
  );
}

/**
 * The Creator Lock on an EVM chain: off by default; on, the share of the supply held out of the coin's pool for the
 * Creator and how long it stays locked after Graduation, within the chain's limits. On an EVM chain Graduation is the
 * coin's price holding its Graduation Target for one hour, which is when the lock's clock starts.
 */
export function EvmLockChoice({ options: o, labelId }: { options: EvmLaunchOptionsState; labelId: string }) {
  return (
    <div className={styles.type}>
      <div className={styles.types} role="radiogroup" aria-labelledby={labelId}>
        <OptionRow name="creator-lock" value="none" checked={!o.lockOn} onChange={() => o.setLockOn(false)}>
          <span className={styles.choice}>
            <b>No lock</b> <span className={styles.choiceLine}>The whole supply goes into the coin&apos;s pool.</span>
          </span>
        </OptionRow>
        <OptionRow name="creator-lock" value="lock" checked={o.lockOn} onChange={() => o.setLockOn(true)}>
          <span className={styles.choice}>
            <b>Lock coins for yourself</b>{" "}
            <span className={styles.choiceLine}>A contract holds them out of the pool, and they are yours once they unlock.</span>
          </span>
        </OptionRow>
      </div>
      {o.lockOn && (
        <div className={styles.rates} role="group" aria-label="Lock size">
          <span className={styles.ratesLabel} aria-hidden>Lock</span>
          <div className={`segmented ${styles.segmented}`}>
            {o.lockSizes.map((bps) => (
              <button key={bps} type="button" aria-pressed={o.lockBpsChosen === bps} onClick={() => o.setLockBps(bps)}>
                {lockShare(bps)}
              </button>
            ))}
          </div>
        </div>
      )}
      {o.lockOn && (
        <div className={styles.rates} role="group" aria-label="Locked for">
          <span className={styles.ratesLabel} aria-hidden>Locked for</span>
          <div className={`segmented ${styles.segmented} ${styles.times}`}>
            {o.lockTimes.map((seconds) => (
              <button key={seconds} type="button" aria-pressed={o.lockSeconds === seconds} onClick={() => o.setLockSeconds(seconds)}>
                {lockTime(seconds)}
              </button>
            ))}
          </div>
        </div>
      )}
      {o.lockOn && (
        <div className={styles.rates} role="group" aria-label="Unlocks">
          <span className={styles.ratesLabel} aria-hidden>Unlocks</span>
          <div className={`segmented ${styles.segmented}`}>
            <button type="button" aria-pressed={o.lockUnlock === "once"} onClick={() => o.setLockUnlock("once")}>All at once</button>
            <button type="button" aria-pressed={o.lockUnlock === "gradual"} onClick={() => o.setLockUnlock("gradual")}>Gradually after 7 days</button>
          </div>
        </div>
      )}
      {o.lockOn && o.lockProblem ? (
        <p className={styles.hintError} role="alert">{o.lockProblem}</p>
      ) : o.lock ? (
        <p className={styles.hint}>
          {`${lockSentence(o.lock)} The clock starts at Graduation, once the price has held the Graduation Target for one hour, so a coin that never graduates never unlocks.`}
        </p>
      ) : (
        <p className={styles.hint}>Fixed at launch: a lock can never be shortened or taken back.</p>
      )}
    </div>
  );
}

/** The First Buy on an EVM chain: one large amount in the Quote Asset, whose live quote the summary shows. No airdrop here. */
export function EvmFirstBuy({ options: o }: { options: EvmLaunchOptionsState }) {
  return (
    <div className={styles.options}>
      <label className={`${styles.amount} ${o.firstBuyProblem ? styles.invalid : ""}`}>
        <input
          id="first-buy"
          className="mono"
          inputMode="decimal"
          autoComplete="off"
          placeholder="0"
          aria-label="First buy"
          value={o.firstBuyText}
          onChange={(e) => o.setFirstBuyText(e.target.value.replace(",", "."))}
          aria-invalid={Boolean(o.firstBuyProblem)}
          aria-describedby={o.firstBuyProblem ? "first-buy-error" : "first-buy-hint"}
        />
        <span className={styles.unit}>{o.symbol}</span>
      </label>
      {o.firstBuyProblem ? (
        <p id="first-buy-error" className={styles.hintError}>
          {o.firstBuyProblem}
        </p>
      ) : (
        <p id="first-buy-hint" className={styles.hint}>
          {o.quote?.native
            ? "Your own buy inside the launch transaction: one signature in your wallet. It pays the Platform Fee, and never the Opening Fee."
            : `Your own buy inside the launch transaction. Paying in ${o.symbol ?? "the Quote Asset"} takes a permit and a transaction, so your wallet asks twice. It pays the Platform Fee, and never the Opening Fee.`}
        </p>
      )}
    </div>
  );
}

/**
 * A raw amount of an asset in whole units with its symbol, every decimal it has kept: what a summary row says exactly.
 * The two are joined by a no-break space, so a sentence that holds one never breaks between the figure and its ticker.
 */
export const exact = (raw: string, decimals: number, symbol: string) => `${formatUnits(raw, decimals, decimals)}\u00a0${symbol}`;
