"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState, type FormEvent, type ReactNode } from "react";
import { LAUNCH_IMAGE_MAX_BYTES, LAUNCH_IMAGE_TYPES, type EvmLaunchOptions, type PlatformInfo, type PreparedEvmLaunch } from "@launchpad/contract";
import { ApiRequestError, LaunchRefusedError, getLaunch, prepareEvmLaunch, reportEvmTransaction } from "@/lib/api";
import { lockSentence } from "@/lib/creatorLock";
import { DESTINATION_SUMMARY } from "@/lib/earnings";
import { EvmReverted, isRejection, waitForReceipt } from "@/lib/evmWallet";
import { formatAmount, formatUnits, quoteTicker, type ExplorerTarget } from "@/lib/format";
import { LINK_KINDS, linkProblem, type LinkKind } from "@/lib/links";
import { LIQUIDITY_LAUNCH } from "@/lib/liquidityLaunch";
import { burnShareTitle } from "@/lib/rewardBurn";
import { Address } from "./Address";
import { CoinCard, type CoinCardData } from "./CoinCard";
import { useCopyCheck } from "./CopyCheck";
import { Disclaimer, hasAcceptedDisclaimer } from "./Disclaimer";
import { EvmEarningsChoice, EvmFirstBuy, EvmLaunchType, EvmLockChoice, EvmQuoteChooser, evmSupplyShare, exact, useEvmLaunchOptions, type EvmLaunchOptionsState } from "./EvmLaunchOptions";
import { useEvmWallet } from "./EvmWalletProvider";
import { CoinFields, LinkFields, useElapsed, useStickySide, type FieldRefusals, type LaunchDraft } from "./LaunchFields";
import { Ring } from "./Mark";
import { NetworkSwitch, onAnotherNetwork } from "./NetworkSwitch";
import { Price } from "./Price";
import { UnauditedStatement } from "./UnauditedStatement";
import { WalletButton } from "./WalletButton";
import styles from "./LaunchForm.module.css";

/** What the wallet is asked for: to let the factory take the First Buy, to sign a permit for it, or the launch itself. */
type Ask = "approve" | "permit" | "launch";
/**
 * A launch that was sent and did not visibly land, or that the chain took and reverted. Trying again prepares the same
 * coin (its `salt` fixes its address), so it can never launch twice. While it is `uncertain` whether it landed, the
 * Creator can't start over with a new coin.
 */
type Failed = { kind: "failed"; coin: string; salt: string; hash: string | null; uncertain: boolean };
type Step =
  | { kind: "editing" }
  | { kind: "preparing"; retrying: Failed | null }
  | { kind: "signing"; prepared: PreparedEvmLaunch; ask: Ask; asks: 1 | 2 }
  | { kind: "confirming"; prepared: PreparedEvmLaunch; ask: "approve" | "launch"; hash: string }
  | Failed;

/** The wallet is on another network than the launch's: nothing is asked of it until it has switched. */
class WrongNetwork extends Error {}

/** How many times one launch may be prepared before the form gives up: the first answer, and one more after each of its steps. */
const PREPARE_ROUNDS = 4;

/**
 * The launch form for an EVM chain (#253), a sibling of the Solana form with the same sections and the same summary,
 * each showing only what the chain offers (`options`, read by the API from the chain's contracts): its listed Quote
 * Assets, the launch types and their terms, the Creator Earnings Destinations it has today, the Creator Lock within its
 * limits, the links and a First Buy. The API prepares every step and the wallet signs it: an approval or a permit for a
 * First Buy in an ERC-20, then the launch, which is one transaction and, with the native asset or no First Buy, one
 * signature. The summary is the review: the chain in plain text, the Listing's figures, the launch's cost in the native
 * asset before anything is signed, and the unaudited statement above the action.
 */
export function EvmLaunchForm({
  options, platform, initialName = "", initialSymbol = "", chainSection, draft = null, onDraft,
}: {
  options: EvmLaunchOptions;
  platform: PlatformInfo;
  initialName?: string;
  initialSymbol?: string;
  /** The form's first section where the site shows more than one chain. */
  chainSection?: ReactNode;
  draft?: LaunchDraft | null;
  onDraft?: (draft: LaunchDraft) => void;
}) {
  const router = useRouter();
  const evm = useEvmWallet();
  const creator = evm?.connected?.address ?? null;
  const [name, setName] = useState(draft?.name ?? initialName);
  const [symbol, setSymbol] = useState(draft?.symbol ?? initialSymbol);
  const [description, setDescription] = useState(draft?.description ?? "");
  const [links, setLinks] = useState<Record<LinkKind, string>>(() => draft?.links ?? (Object.fromEntries(LINK_KINDS.map((k) => [k, ""])) as Record<LinkKind, string>));
  const [moreLinks, setMoreLinks] = useState(false);
  const [image, setImage] = useState<File | null>(draft?.image ?? null);
  const [quoteAddress, setQuoteAddress] = useState<string | null>(options.quotes[0]?.mint ?? null);
  const [step, setStep] = useState<Step>({ kind: "editing" });
  const [error, setError] = useState<string | null>(null);
  const [disclaimerOpen, setDisclaimerOpen] = useState(false);
  /** What a prepare refused by the chain's own rules, shown under each field until the Creator edits the form. */
  const [refused, setRefused] = useState<FieldRefusals>({});

  const imageUrl = useMemo(() => (image ? URL.createObjectURL(image) : null), [image]);
  useEffect(() => () => { if (imageUrl) URL.revokeObjectURL(imageUrl); }, [imageUrl]);
  useEffect(() => onDraft?.({ name, symbol, description, links, image }), [onDraft, name, symbol, description, links, image]);

  const quote = options.quotes.find((q) => q.mint === quoteAddress) ?? null;
  const o = useEvmLaunchOptions(options, quote, creator);
  const linkLines = LINK_KINDS.map((k) => links[k].trim()).filter(Boolean).join("\n");
  const copy = useCopyCheck({ name, symbol, image, creator, chain: options.chain, description, links: linkLines });
  const refusals: FieldRefusals = { ...copy.refusals, ...refused };
  const failed = step.kind === "failed" ? step : step.kind === "preparing" ? step.retrying : null;
  const busy = step.kind !== "editing" && step.kind !== "failed";
  const explorer: ExplorerTarget = { cluster: platform.cluster, rpcUrl: platform.rpcUrl, explorer: options.explorer };

  function pickImage(file: File | undefined) {
    setError(null);
    if (!file) return;
    if (!(LAUNCH_IMAGE_TYPES as readonly string[]).includes(file.type)) return setError("That file is not a PNG, JPEG, WebP or GIF. Choose an image for your coin.");
    if (file.size > LAUNCH_IMAGE_MAX_BYTES) return setError("The image is larger than 2 MB. Choose a smaller one.");
    setImage(file);
  }

  /** The form as a prepare takes it. The image travels on the first call alone: after it, the coin's `salt` names the one stored. */
  function fields(salt: string, permit: { deadline: string; signature: string } | null) {
    const form = new FormData();
    form.set("chain", options.chain);
    form.set("creator", creator!);
    form.set("quote", quote!.mint);
    form.set("name", name.trim());
    form.set("symbol", symbol.trim());
    form.set("description", description.trim());
    for (const k of LINK_KINDS) if (links[k].trim()) form.set(k, links[k].trim());
    for (const [k, v] of o.fields()) form.set(k, v);
    if (salt) form.set("salt", salt);
    else form.set("image", image!);
    if (permit) {
      form.set("permitDeadline", permit.deadline);
      form.set("permitSignature", permit.signature);
    }
    return form;
  }

  /** The check before every send and every signature: the wallet must be on the launch's own chain at that moment. */
  async function onRightChain() {
    if ((await evm!.readChainId()) !== options.chainId) throw new WrongNetwork();
  }

  /** A launch the chain has taken: reported until the API has indexed it, then its coin's page. */
  async function landed(hash: string, coin: string) {
    await reportEvmTransaction(options.chain, hash);
    router.push(`/coin/${coin}`);
  }

  /**
   * The one action: prepares the launch, does what the answer says the wallet does next (an approval, then a permit or
   * neither, each followed by another prepare for the same coin), sends the launch, waits for the chain, reports the
   * transaction and opens the coin. With `retrying` it is the same coin again.
   */
  async function launch(retrying: Failed | null) {
    if (!evm?.connected || !quote) return;
    const provider = evm.connected.wallet.provider;
    setError(null);
    setRefused({});
    setStep({ kind: "preparing", retrying });
    const back = (message: string) => {
      setError(message);
      setStep(retrying ?? { kind: "editing" });
    };

    let prepared: PreparedEvmLaunch | null = null;
    let asks: 1 | 2 = 1;
    try {
      // A launch that was sent and lost sight of may have landed since: the chain is asked before anything is prepared.
      if (retrying?.hash) {
        const earlier = await waitForReceipt(provider, retrying.hash, { timeoutMs: 4_000 }).catch(() => null);
        if (earlier) return await landed(retrying.hash, retrying.coin);
      }
      let salt = retrying?.salt ?? "";
      let permit: { deadline: string; signature: string } | null = null;
      for (let round = 0; prepared === null; round++) {
        if (round >= PREPARE_ROUNDS) throw new Error("The launch could not be prepared. Try again in a moment.");
        await onRightChain();
        const answer = await prepareEvmLaunch(fields(salt, permit));
        salt = answer.salt;
        if (answer.step === "launch" && answer.transaction) prepared = answer;
        else if (answer.step === "approve" && answer.transaction) {
          asks = 2;
          setStep({ kind: "signing", prepared: answer, ask: "approve", asks });
          const hash = await evm.sendTransaction(answer.transaction);
          setStep({ kind: "confirming", prepared: answer, ask: "approve", hash });
          await evm.waitForReceipt(hash);
          setStep({ kind: "preparing", retrying });
        } else if (answer.step === "permit" && answer.permit && answer.permitDeadline) {
          asks = 2;
          setStep({ kind: "signing", prepared: answer, ask: "permit", asks });
          permit = { deadline: answer.permitDeadline, signature: await evm.signTypedData(answer.permit) };
          setStep({ kind: "preparing", retrying });
        } else throw new Error("The launch could not be prepared. Try again in a moment.");
      }
      await onRightChain();
    } catch (e) {
      if (e instanceof WrongNetwork) return back(`Your wallet is on another network. Switch it to ${options.name}, then try again.`);
      // A retry of a coin that landed after all goes to it.
      if (retrying && e instanceof ApiRequestError && e.status === 409 && (await getLaunch(retrying.coin).catch(() => null))) return router.push(`/coin/${retrying.coin}`);
      if (e instanceof LaunchRefusedError) setRefused(Object.fromEntries(e.refusals.map((r) => [r.field, r.reason])));
      // What the API says is the API's own sentence, shown as it is; only a wallet's answer is read for a refusal.
      if (e instanceof ApiRequestError) return back(e.message);
      if (isRejection(e)) return back("You declined the request in your wallet. Nothing was launched.");
      if (e instanceof EvmReverted) return back("The approval for your first buy failed on the chain, so nothing was launched. Try again.");
      return back((e as Error).message || "The launch could not be prepared. Try again in a moment.");
    }

    setStep({ kind: "signing", prepared, ask: "launch", asks });
    let hash: string;
    try {
      hash = await evm.sendTransaction(prepared.transaction!);
    } catch (e) {
      return back(isRejection(e) ? "You declined the transaction in your wallet. Nothing was launched." : (e as Error).message || "Your wallet could not send the launch. Nothing was launched.");
    }
    setStep({ kind: "confirming", prepared, ask: "launch", hash });
    try {
      await evm.waitForReceipt(hash);
    } catch (e) {
      const reverted = e instanceof EvmReverted;
      setError(reverted ? "The launch transaction failed on the chain. Nothing was created; try again." : "We couldn't confirm whether your coin launched. Check your connection, then try again.");
      return setStep({ kind: "failed", coin: prepared.coin, salt: prepared.salt, hash: reverted ? null : hash, uncertain: !reverted });
    }
    await landed(hash, prepared.coin);
  }

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setError(null);
    if (failed) return void launch(failed);
    if (!name.trim()) return setError("Give your coin a name.");
    if (!image) return setError("Add an image for your coin.");
    const link = linkProblem(links);
    if (link) return setError(link);
    if (!quote) return setError("Choose a Quote Asset to pair your coin with.");
    // What the chain's own rules refuse stops the launch here, as a taken name stops it at the API.
    const refusal = Object.values(copy.refusals)[0];
    if (refusal) return setError(refusal);
    if (o.problem) return setError(o.problem);
    if (!hasAcceptedDisclaimer()) return setDisclaimerOpen(true);
    void launch(null);
  }

  // A refusal is about the form as it was: once the Creator changes a field, or the wallet, it is no longer said.
  const edited = JSON.stringify([name, symbol, description, links, quoteAddress, o.fields(), creator]);
  useEffect(() => {
    setError(null);
    setRefused({});
  }, [edited]);

  const side = useStickySide();
  const ticker = quote ? quoteTicker(quote) : null;
  const firstBuy = o.firstBuyQuote;
  const preview: CoinCardData = {
    image: imageUrl,
    symbol: symbol || "TICKER",
    name: name.trim() || "Your coin",
    quote: ticker ?? options.native.symbol,
    price: quote?.listing.startPrice ?? null,
    change24h: null,
    progress: 0,
    curve: "live",
    volume: `${firstBuy && quote ? formatUnits(firstBuy.amountIn, quote.decimals, 4) : "0"} ${ticker ?? options.native.symbol}`,
    rewardTaxBps: o.rewardTax,
    rewardBurnBps: o.rewardTax === null ? 0 : o.rewardBurn,
    rewardLiquidityBps: o.rewardTax === null ? 0 : o.rewardLiquidity,
    liquidityTaxBps: o.liquidityTax,
  };
  // While a launch is in flight or uncertain, nothing on the form may change under it.
  const locked = busy || failed !== null;

  return (
    <form className={`shell grid ${styles.page}`} onSubmit={onSubmit} aria-busy={busy}>
      <header className={`col-12 ${styles.head}`}>
        <h1 className={`t-h1 ${styles.title}`}>Stoke a coin</h1>
      </header>

      <fieldset className={`col-8 ${styles.form}`} disabled={locked}>
        {chainSection}

        <CoinFields
          imageUrl={imageUrl}
          onPickImage={pickImage}
          onImageUnreadable={() => {
            setImage(null);
            setError("That file can't be read as an image. Choose another one.");
          }}
          name={name}
          onName={setName}
          symbol={symbol}
          onSymbol={setSymbol}
          description={description}
          onDescription={setDescription}
          copy={copy}
          refusals={refusals}
        />

        <section className={styles.set} aria-labelledby="block-pair">
          <h2 id="block-pair" className={`t-h3 ${styles.legend}`}>Paired with</h2>
          <EvmQuoteChooser options={options} value={quoteAddress} onChange={setQuoteAddress} labelId="block-pair" />
        </section>

        <section className={styles.set} aria-labelledby="block-type">
          <h2 id="block-type" className={`t-h3 ${styles.legend}`}>Launch type</h2>
          <EvmLaunchType options={o} coin={symbol} labelId="block-type" />
        </section>

        <section className={styles.set} aria-labelledby="block-earnings">
          <h2 id="block-earnings" className={`t-h3 ${styles.legend}`}>Creator earnings</h2>
          <EvmEarningsChoice options={o} coin={symbol} labelId="block-earnings" />
        </section>

        {o.lockOffered && (
          <section className={styles.set} aria-labelledby="block-lock">
            <h2 id="block-lock" className={`t-h3 ${styles.legend}`}>Creator Lock</h2>
            <EvmLockChoice options={o} labelId="block-lock" />
          </section>
        )}

        <LinkFields links={links} onLink={(k, v) => setLinks((l) => ({ ...l, [k]: v }))} more={moreLinks} onMore={() => setMoreLinks(true)} refusals={refusals} />

        <section className={styles.set} aria-labelledby="block-first-buy">
          <h2 id="block-first-buy" className={`t-h3 ${styles.legend}`}>First buy</h2>
          <EvmFirstBuy options={o} />
        </section>
      </fieldset>

      {/* The summary is the review: the coin's preview, the terms it launches on, the unaudited statement and the one action. */}
      <aside ref={side} className={`col-4 ${styles.side}`} aria-label="Launch summary">
        <Summary
          options={options}
          o={o}
          ticker={ticker}
          symbol={symbol}
          preview={preview}
          step={step}
          failed={failed}
          error={error}
          explorer={explorer}
          onEdit={() => { setError(null); setStep({ kind: "editing" }); }}
        />
      </aside>

      <Disclaimer
        open={disclaimerOpen}
        onCancel={() => setDisclaimerOpen(false)}
        onAccept={() => {
          setDisclaimerOpen(false);
          void launch(null);
        }}
      />
    </form>
  );
}

type SummaryProps = {
  options: EvmLaunchOptions;
  o: EvmLaunchOptionsState;
  ticker: string | null;
  symbol: string;
  preview: CoinCardData;
  step: Step;
  failed: Failed | null;
  error: string | null;
  explorer: ExplorerTarget;
  onEdit: () => void;
};

/** What the signing panel says the wallet is being asked for, by the step and by how many asks the launch takes. */
function askWords(ask: Ask, asks: 1 | 2, symbol: string, firstBuy: string | null) {
  if (ask === "approve") return `Step 1 of 2: an approval, so the launch can take your first buy${firstBuy ? ` of ${firstBuy}` : ""}. The launch itself follows.`;
  if (ask === "permit") return `Step 1 of 2: a permit for your first buy${firstBuy ? ` of ${firstBuy}` : ""}. It is a signature and costs no gas. The launch itself follows.`;
  return asks === 2 ? `Step 2 of 2: the transaction that launches ${symbol || "your coin"}, with your first buy inside it.` : `One signature launches ${symbol || "your coin"}.`;
}

/**
 * The launch summary on an EVM chain, the form's review step: the coin's preview, the chain in plain text, the Listing's
 * start price, Opening Value and Graduation Target, the launch's terms, the First Buy and what it buys, and the launch's
 * cost in the chain's native asset before the Creator signs; then what is true of every coin launched there, the
 * unaudited statement, and the one action with what follows it.
 */
function Summary({ options, o, ticker, symbol, preview, step, failed, error, explorer, onEdit }: SummaryProps) {
  const evm = useEvmWallet();
  const elapsed = useElapsed(step.kind === "confirming");
  const outcome = useRef<HTMLDivElement>(null);
  // A failure, an error or the signing panel appears at the card's foot: bring it into view.
  const outcomeKey = step.kind === "signing" ? "signing" : failed ? "failed" : error ? "error" : null;
  useEffect(() => {
    if (outcomeKey) outcome.current?.scrollIntoView({ block: "nearest" });
  }, [outcomeKey]);

  const quote = o.quote;
  const native = options.native;
  const listing = quote?.listing ?? null;
  const firstBuy = o.firstBuyQuote;
  const cost = o.launchQuote?.cost ?? null;
  const supply = BigInt(options.supply);
  const connected = evm?.connected ?? null;
  const wrongNetwork = onAnotherNetwork(connected, options.chainId);
  const prepared = step.kind === "signing" || step.kind === "confirming" ? step.prepared : null;
  const preparedFirstBuy = prepared?.firstBuy && quote && ticker ? exact(prepared.firstBuy.amountIn, quote.decimals, ticker) : null;
  const fee = (wei: string) => `${formatUnits(wei, native.decimals, 8)} ${native.symbol}`;

  return (
    <div className={`card card-raised ${styles.summary}`}>
      <section className={styles.preview} aria-label="Preview">
        <p className={styles.previewLabel} aria-hidden>Preview</p>
        <CoinCard card={preview} />
      </section>

      <dl className={styles.facts}>
        <div>
          <dt>Chain</dt>
          <dd>{options.name}</dd>
        </div>
        <div>
          <dt>Supply</dt>
          <dd>{formatUnits(options.supply, options.decimals, 0)}, fixed</dd>
        </div>
        {listing && quote && ticker ? (
          <>
            <div>
              <dt>Start price</dt>
              <dd><Price value={listing.startPrice} /> {ticker}</dd>
            </div>
            <div>
              <dt>Opening Value</dt>
              <dd>{formatAmount(listing.openingValue, quote.decimals)} {ticker}</dd>
            </div>
            <div>
              <dt>Graduates at</dt>
              <dd className={styles.factWords}><Price value={listing.startPrice * listing.graduationMultiple} /> {ticker}, held for one hour</dd>
            </div>
          </>
        ) : (
          <div>
            <dt>Graduates at</dt>
            <dd>Choose a Quote Asset</dd>
          </div>
        )}
        <div>
          <dt>Launch type</dt>
          <dd>
            {o.liquidityTax !== null
              ? `${LIQUIDITY_LAUNCH.name}, ${o.liquidityTax / 100}%`
              : o.rewardTax === null ? "Standard" : `Reward Launch, ${o.rewardTax / 100}%`}
          </dd>
        </div>
        {o.liquidityTax !== null && (
          <div>
            <dt>{LIQUIDITY_LAUNCH.tax}</dt>
            <dd className={styles.factWords}>All of it to its pool, locked; nothing to holders</dd>
          </div>
        )}
        {o.rewardTax !== null && burnShareTitle(o.rewardBurn) && (
          <div>
            <dt>Reward Burn</dt>
            <dd>{burnShareTitle(o.rewardBurn)} of every reward</dd>
          </div>
        )}
        {o.rewardTax !== null && burnShareTitle(o.rewardLiquidity) && (
          <div>
            <dt>Reward Liquidity</dt>
            <dd className={styles.factWords}>{burnShareTitle(o.rewardLiquidity)} of every reward, to its pool</dd>
          </div>
        )}
        {o.lock && (
          <div>
            <dt>Creator Lock</dt>
            <dd className={styles.factWords}>{lockSentence(o.lock)}</dd>
          </div>
        )}
        {firstBuy && quote && ticker && (
          <>
            <div>
              <dt>First buy</dt>
              <dd>{exact(firstBuy.amountIn, quote.decimals, ticker)}</dd>
            </div>
            <div>
              <dt>You get</dt>
              <dd>
                {formatUnits(firstBuy.coinsOut, options.decimals, 0)} {symbol || "coins"} ({evmSupplyShare(BigInt(firstBuy.coinsOut), supply)})
              </dd>
            </div>
          </>
        )}
        <div>
          <dt>You earn</dt>
          <dd className={styles.factWords}>
            <Link href="/fees" className={styles.factLink}>A share of every trade&apos;s Platform Fee</Link>
            {o.earningsDestination !== "wallet" && <>, {DESTINATION_SUMMARY[o.earningsDestination]}</>}
          </dd>
        </div>
        <div>
          <dt>Launch cost</dt>
          {/* One string a case, so one text node: the network's fee is an estimate, and a First Buy in the native asset is sent with the launch. */}
          <dd className={styles.factWords} data-launch-cost="">
            {cost === null
              ? `Network fee in ${native.symbol}`
              : cost.value !== "0"
                ? `About ${fee(cost.fee)} in network fees, and your first buy of ${fee(cost.value)}`
                : `About ${fee(cost.fee)} in network fees`}
          </dd>
        </div>
      </dl>

      <ul className={styles.checks}>
        <li>Sold supply locked in its pool for good</li>
        <li>No owner and no mint on the coin</li>
        <li>Metadata stored on Arweave</li>
      </ul>

      <div ref={outcome} className={styles.action}>
        <UnauditedStatement chain={options.name} source={options.contracts.source} />

        {error && (
          <p className={styles.error} role="alert">
            {error}
          </p>
        )}

        {step.kind === "signing" ? (
          <div className={styles.signing} role="status">
            <Ring size={28} className={styles.signingRing} />
            <p className={styles.signingTitle}>{connected ? `Confirm in ${connected.wallet.name}` : "Confirm in your wallet"}</p>
            <p className={styles.signingText}>{askWords(step.ask, step.asks, symbol, preparedFirstBuy)}</p>
            <p className={styles.signingText}>You sign in your wallet. Stoker never holds your funds.</p>
            <dl className={styles.signingAmounts}>
              <div>
                <dt>Network fee, about</dt>
                <dd className="mono">{fee(step.prepared.cost.fee)}</dd>
              </div>
              {preparedFirstBuy && (
                <div>
                  <dt>First buy</dt>
                  <dd className="mono">{preparedFirstBuy}</dd>
                </div>
              )}
            </dl>
          </div>
        ) : step.kind === "confirming" ? (
          <div className={styles.status} role="status">
            <span className={styles.statusDot} aria-hidden />
            <span className={styles.statusText}>
              {step.ask === "approve" ? "Approving your first buy" : `Launching ${symbol}`}, <span className="mono">{elapsed}s</span>
            </span>
            <Address value={step.hash} kind="tx" platform={explorer} className={styles.statusLink} />
          </div>
        ) : !connected ? (
          <WalletButton variant="block" family="evm" />
        ) : wrongNetwork && step.kind !== "preparing" ? (
          <NetworkSwitch name={options.name} chain={options.wallet} />
        ) : failed ? (
          <div className={styles.failed} role="region" aria-label="Launch not confirmed">
            <p>
              {failed.uncertain
                ? "Trying again checks the chain first: if your coin did launch, you go straight to it. It can never launch twice."
                : "Try again with the same coin, or edit it first."}
            </p>
            <div className={styles.actions}>
              {!failed.uncertain && (
                <button type="button" className="button button-ghost button-lg" onClick={onEdit} disabled={step.kind !== "failed"}>
                  Edit
                </button>
              )}
              <button type="submit" className={`button button-primary button-lg ${styles.primary}`} disabled={step.kind !== "failed"} aria-busy={step.kind === "preparing" || undefined}>
                {step.kind === "preparing" ? "Checking…" : "Try again"}
              </button>
            </div>
          </div>
        ) : (
          <button
            type="submit"
            className={`button button-primary button-lg ${styles.primary}`}
            disabled={step.kind !== "editing" || !quote}
            aria-busy={step.kind === "preparing" || undefined}
          >
            {step.kind === "preparing" ? "Preparing…" : `Stoke ${symbol || "a coin"}`}
          </button>
        )}

        <p className={styles.note}>
          What you earn is approximate and depends on trading that may never happen. A coin can lose all of its value, and nothing
          here is investment advice.
        </p>
      </div>
    </div>
  );
}
