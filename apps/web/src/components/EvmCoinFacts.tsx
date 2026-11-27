"use client";

import Link from "next/link";
import type { LaunchSummary } from "@launchpad/contract";
import { lockSentence } from "@/lib/creatorLock";
import { DESTINATION_TAGS } from "@/lib/earnings";
import { formatDuration, formatUtc, quoteTicker, type ExplorerTarget } from "@/lib/format";
import { LINK_KINDS, type LinkKind } from "@/lib/links";
import { LIQUIDITY_LAUNCH, liquidityLine } from "@/lib/liquidityLaunch";
import { burnShareWords } from "@/lib/rewardBurn";
import { Address } from "./Address";
import { CopyButton } from "./CopyButton";
import { LinkIcon, LinkName } from "./LinkIcon";
import styles from "./CoinFacts.module.css";

/**
 * The About block and the addresses of a coin on an EVM chain (#253), a sibling of `CoinFacts` with what is true there:
 * the chain in plain text, the launch's type and its tax as the chain takes it (in the Quote Asset, from every trade in
 * the coin's own pool), the Creator Lock, what the Creator earns in words (the Fees page has the figures), the liquidity
 * and Graduation as an EVM chain has them, the dates, the Copy Protection, and the coin's own links. No link leaves for a
 * Solana explorer or aggregator: every address goes to the chain's own explorer, and a pool's id, which is no address,
 * is written out to copy. What the page reads from the chain for a Solana coin (holders, trust figures, the lock's
 * stage, rewards) is left out until an EVM chain has those reads.
 */
export function EvmCoinFacts({ launch, chainName, explorer, renderedAt }: {
  launch: LaunchSummary;
  /** The chain's name as the API gives it, in full. */
  chainName: string;
  /** Where addresses link: the chain's own explorer. */
  explorer: ExplorerTarget;
  /** The server's clock at render, so whether the window is over reads the same on the server and at hydration. */
  renderedAt: number;
}) {
  const quote = quoteTicker(launch.quote);
  const rule = launch.earningsDestination === "wallet" ? null : launch.earningsDestination;
  const protectionOpen = new Date(launch.protection.until).getTime() <= renderedAt;
  const protectionLength = formatDuration(new Date(launch.protection.until).getTime() - new Date(launch.createdAt).getTime());
  const links = LINK_KINDS.map((k) => [k, launch.links[k]] as const).filter((l): l is readonly [LinkKind, string] => Boolean(l[1]));
  const addresses: (readonly [label: string, value: string, kind: "address" | "tx" | "pool"])[] = [
    ["Creator", launch.creator, "address"],
    ["Coin", launch.mint, "address"],
    ["Pool", launch.pool, "pool"],
    ["Launch transaction", launch.createdSignature, "tx"],
    ...(launch.graduation ? ([["Graduation transaction", launch.graduation.signature, "tx"]] as const) : []),
  ];

  return (
    <>
      <div className={`card ${styles.aboutCard}`}>
        <h2 className={`t-h3 ${styles.aboutTitle}`}>About {launch.symbol}</h2>
        {launch.description && <p className={styles.description}>{launch.description}</p>}
        <dl className={styles.facts}>
          <div>
            <dt>Chain</dt>
            <dd>{chainName}</dd>
          </div>
          <div>
            <dt>Launch type</dt>
            <dd>{launch.liquidityTax ? LIQUIDITY_LAUNCH.name : launch.rewardTax ? "Reward Launch" : "Standard coin"}</dd>
          </div>
          {launch.liquidityTax && (
            <div data-liquidity-tax="">
              <dt>{LIQUIDITY_LAUNCH.tax}</dt>
              <dd>
                {launch.liquidityTax.bps / 100}% of every trade in its own pool, taken in {quote}
                <span>{`${liquidityLine(launch.symbol)} It is added from the first trade, as Support Liquidity just under the price.`}</span>
              </dd>
            </div>
          )}
          {launch.rewardTax && (
            <div>
              <dt>Reward tax</dt>
              <dd>
                {launch.rewardTax.bps / 100}% of every trade in its own pool, taken in {quote} and paid out to holders in {launch.rewardTax.payout === "coin" ? launch.symbol : quote}
                {burnShareWords(launch.rewardTax.burnBps) && <>, {burnShareWords(launch.rewardTax.burnBps)} of it burned first</>}
                {burnShareWords(launch.rewardTax.liquidityBps) && <>, {burnShareWords(launch.rewardTax.liquidityBps)} of it added to its pool, locked</>}
              </dd>
            </div>
          )}
          {launch.creatorLock && (
            <div>
              <dt>Creator Lock</dt>
              <dd>{lockSentence(launch.creatorLock)}</dd>
            </div>
          )}
          <div>
            <dt>Creator earns</dt>
            <dd data-earnings={launch.earningsDestination}>
              A share of the Platform Fee on every trade of this coin
              {/* The sentence and the space before the link are one string, so one text node. */}
              <span>
                {`${rule ? `${DESTINATION_TAGS[rule]}, as its Creator fixed at launch.` : "Recorded as the Creator's in the trade's own block, and paid to their wallet with nothing to claim."} `}
                <Link href="/fees">Every fee, explained</Link>
              </span>
            </dd>
          </div>
          <div>
            <dt>Liquidity</dt>
            <dd>Locked in the coin&apos;s own pool from launch, for good; its price is not.</dd>
          </div>
          <div>
            <dt>Graduation</dt>
            <dd>
              {launch.graduation ? (
                <>Graduated <time dateTime={launch.graduation.graduatedAt}>{formatUtc(launch.graduation.graduatedAt)}</time></>
              ) : (
                "Once its price has held its Graduation Target for one hour"
              )}
            </dd>
          </div>
          <div>
            <dt>Launched</dt>
            <dd>
              <time dateTime={launch.createdAt}>{formatUtc(launch.createdAt)}</time>
            </dd>
          </div>
          <div>
            <dt>Copy protection</dt>
            {/* `data-until`: the suite sizes the time inside this sentence to the date's width for its mask. */}
            <dd data-until>
              {protectionLength} from launch
              <span>
                {protectionOpen ? "Ended " : "Until "}
                <time dateTime={launch.protection.until}>{formatUtc(launch.protection.until)}</time>
                {protectionOpen
                  ? ". Anyone may use this coin's name, ticker and image again."
                  : ": nobody else can launch a coin here with this name, ticker or image."}
                {launch.copyOf && (
                  <>
                    {" "}
                    {copyKind(launch.copyOf.kind)}{" "}
                    <Link href={`/coin/${launch.copyOf.mint}`}>{launch.copyOf.name} ({launch.copyOf.symbol})</Link>, launched{" "}
                    <time dateTime={launch.copyOf.launchedAt}>{formatUtc(launch.copyOf.launchedAt)}</time>
                  </>
                )}
              </span>
            </dd>
          </div>
          <div>
            <dt>Links</dt>
            <dd className={styles.elsewhere}>
              {links.length === 0 && <span>None given by the Creator.</span>}
              {links.map(([kind, href]) => (
                <a key={kind} href={href} className={`chip ${styles.social}`} target="_blank" rel="noreferrer nofollow">
                  <LinkIcon kind={kind} size={14} />
                  <LinkName kind={kind} />
                </a>
              ))}
            </dd>
          </div>
        </dl>
      </div>

      <dl className={`card ${styles.addresses}`} aria-label="Addresses">
        {addresses.map(([label, value, kind]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd>
              {/* A pool's id is no address, so the explorer has no page for it: it is written to copy. */}
              {kind === "pool" ? <Address value={value} /> : <Address value={value} kind={kind} platform={explorer} />}
              <CopyButton value={value} label={`Copy ${label.toLowerCase()}`} />
            </dd>
          </div>
        ))}
      </dl>
    </>
  );
}

/** How a coin took an earlier coin's identity, as the label's opening words. */
function copyKind(kind: "ticker" | "name" | "image" | "near") {
  return { ticker: "Its ticker is", name: "Its name is", image: "Its image is", near: "Its name or ticker is a near copy of" }[kind] + (kind === "near" ? "" : " that of");
}
