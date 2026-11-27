import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import type { Chain } from "@launchpad/contract";
import {
  getAirdrop, getCoinEarnings, getCoinLiquidityTax, getCoinRewards, getCreatorLock, getEvmLaunchOptions, getHolders, getLaunch, getPlatform, getQuoteAsset, getRewardRules,
  getTrust, listChains, listTrades,
} from "@/lib/api";
import { CHAIN_NAMES, evmChainsOf, isEvm } from "@/lib/chains";
import { explorerUrl, isSol, quoteTicker } from "@/lib/format";
import { breadcrumbList, clip, pageMeta } from "@/lib/meta";
import { siteOrigin } from "@/lib/origin";
import { visitorChains } from "@/lib/visitorChains";
import { AirdropCard } from "@/components/AirdropCard";
import { CoinMarket, type CoinLink } from "@/components/CoinMarket";
import { EarningsCard } from "@/components/EarningsCard";
import { EvmCoinMarket } from "@/components/EvmCoinMarket";
import { JsonLd } from "@/components/JsonLd";
import { LiquidityTaxCard } from "@/components/LiquidityTaxCard";
import { QuoteLabelList } from "@/components/QuoteLabels";
import { RewardsCard } from "@/components/RewardsCard";
import styles from "./page.module.css";

type Props = { params: Promise<{ mint: string }>; searchParams: Promise<Record<string, string | string[] | undefined>> };

const SOLANA_ADDRESS = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
/** A coin on an EVM chain is named by its contract's address, which no Solana address can be taken for: base58 has no 0. */
const EVM_ADDRESS = /^0x[0-9a-fA-F]{40}$/;

/**
 * A referral link's address (`?ref=`), taken only when it looks like an address of the coin's own chain family: a
 * Solana wallet for a Solana coin, an EVM address for a coin on an EVM chain, where it is credited the Referrer Fee.
 */
function referrerFrom(params: Record<string, string | string[] | undefined>, evm = false) {
  const ref = params.ref;
  return typeof ref === "string" && (evm ? EVM_ADDRESS : SOLANA_ADDRESS).test(ref) ? ref : null;
}

/**
 * The coin at an address, for a visitor who is shown its chain (#253): null for no coin, and for a coin on a chain this
 * visitor is not shown. An EVM address is not even asked for on a site that shows no EVM chain.
 */
async function shownLaunch(mint: string, chains: readonly Chain[]) {
  if (EVM_ADDRESS.test(mint) && evmChainsOf(chains).length === 0) return null;
  const launch = await getLaunch(mint);
  return launch && chains.includes(launch.chain) ? launch : null;
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { mint } = await params;
  const launch = await shownLaunch(mint, await visitorChains());
  if (!launch) return pageMeta({ path: `/coin/${mint}`, title: "Coin not found", index: false });
  const quote = quoteTicker(launch.quote);
  // Its own description when the Creator wrote one; otherwise its pair and what its Creator earns (#83). A coin on an
  // EVM chain says its chain and its pair: what its Creator earns there is the Fees page's to say.
  const description = launch.description?.trim()
    || (isEvm(launch.chain)
      ? `${launch.name} (${launch.symbol}) trades on Stoker on ${CHAIN_NAMES[launch.chain]}, paired with ${quote}.`
      : `${launch.name} (${launch.symbol}) trades on Stoker paired with ${quote}; its creator earns half of what the platform collects on its trades, every payment on the public ledger.`);
  return pageMeta({ path: `/coin/${launch.mint}`, title: `${launch.symbol} / ${quote}`, description: clip(description), card: "own" });
}

/**
 * A coin's page (#134, phase 3 of the rework): a breadcrumb, a one-line title row (the lockup at 40px, the pair, the
 * name with the explorer link, the trust marks (a fourth for a Creator Lock) and the price with the day's change), the market (the chart with
 * the graduation bar and the activity under it, the trade panel docked beside it with the pair's other half and, under
 * those, the About block with the description, the launch's details, the coin's links and the addresses: owner,
 * 2026-10-31, the facts belong under the trade panel as the terminals place them), and below the grid only what some
 * coins have: the Quote Asset's labels, the rewards or, for a Liquidity Launch (#215), its tax and what it has added to
 * the pool, the Creator's earnings under a rule (ADR 0011) and a finished Airdrop.
 */
export default async function CoinPage({ params, searchParams }: Props) {
  const { mint } = await params;
  const chains = await visitorChains();
  // A coin on an EVM chain has a page of its own shape (#253), and none at all on a site that shows no EVM chain: what
  // this page reads below is Solana's, and answers 404 for such a coin.
  if (EVM_ADDRESS.test(mint)) return <EvmCoinPage mint={mint} chains={chains} referrer={referrerFrom(await searchParams, true)} />;
  const referrer = referrerFrom(await searchParams);
  const [launch, platform, trades, holders, trust, airdrop] = await Promise.all([
    getLaunch(mint), getPlatform(), listTrades(mint),
    // A 404 (no such coin) or an unreadable chain leaves the cards to retry, rather than failing the page.
    getHolders(mint).catch(() => null),
    getTrust(mint).catch(() => null),
    getAirdrop(mint),
  ]);
  if (!launch || !chains.includes(launch.chain)) notFound();
  // What only some coins have, read together: a Reward Launch's rewards, or a Liquidity Launch's tax (#215), which has
  // no rewards and takes their card's place; the Creator's earnings where they go to a rule
  // rather than the wallet (ADR 0011); and the Quote Asset, whose card wants its price and liquidity and whose labels
  // are shown for any asset but SOL (#11). A read that fails leaves its card out, never the page.
  // A coin whose Creator's earnings go to its holders also reads the Reward Round rules, which say whether its rounds
  // weigh coins by how long they were kept (ADR 0022); a Reward Launch's rewards carry the rules themselves.
  // A coin with a Creator Lock (ADR 0023) reads where it stands from the chain, for its trust mark and its Creator's claim.
  const [rewards, liquidityTax, earnings, quoteAsset, rules, lock] = await Promise.all([
    launch.rewardTax ? getCoinRewards(mint).catch(() => null) : null,
    launch.liquidityTax ? getCoinLiquidityTax(mint).catch(() => null) : null,
    launch.earningsDestination !== "wallet" ? getCoinEarnings(mint).catch(() => null) : null,
    getQuoteAsset(launch.quote.mint).catch(() => null),
    launch.earningsDestination === "holders" ? getRewardRules().catch(() => null) : null,
    launch.creatorLock ? getCreatorLock(mint).catch(() => null) : null,
  ]);
  const weighted = (rules?.inForce?.holdingWeights.length ?? 0) > 0;
  // An Airdrop still being paid sits under the title row, where its Creator sends it (the market component draws it); a finished one joins the cards below.
  const airdropDone = airdrop?.recipients.every((r) => r.status === "paid") ?? false;
  const quote = quoteTicker(launch.quote);
  const origin = await siteOrigin();
  // The explorer in the title row; the coin's own links (website, X, Telegram) are a fact of the About block, which the
  // market component draws under the trade panel (owner, 2026-10-31).
  const links: CoinLink[] = [{ label: "Explorer", href: explorerUrl("address", launch.mint, platform), external: false }];

  return (
    <article className={`shell ${styles.page}`}>
      <JsonLd data={breadcrumbList(origin, [["Home", "/"], ["Coins", "/coins"], [`${launch.symbol} / ${quote}`, `/coin/${launch.mint}`]])} />
      <nav aria-label="Breadcrumb" className={styles.crumbs}>
        <ol>
          <li><Link href="/coins">Explore</Link></li>
          <li><Link href={`/coins?quote=${launch.quote.mint}`}>Paired with {quote}</Link></li>
          <li aria-current="page">{launch.symbol}</li>
        </ol>
      </nav>

      {/* The title row, the pair card, the About block and the Airdrop card are all drawn by the market component from data:
          a server-rendered tree handed through the client boundary as a prop warns about missing keys when the client
          re-renders with it (2026-10-31: the pair card first, then the Airdrop card the moment a wallet connected). */}
      <CoinMarket
        initial={launch} platform={platform} quoteAsset={quoteAsset} links={links} initialTrades={trades.trades} initialHolders={holders}
        initialTrust={trust} initialLock={lock} renderedAt={Date.now()} referrer={referrer} airdrop={airdropDone ? null : airdrop}
      />

      {(quoteAsset && !isSol(launch.quote)) || rewards || liquidityTax || earnings || airdropDone ? (
        <section className={`grid ${styles.more}`} aria-label="More about this coin">

          {quoteAsset && !isSol(launch.quote) && (
            <section className={`card ${styles.wide} ${styles.quoteLabels}`} aria-labelledby="quote-labels-title">
              {/* The ticker is the way to the asset's page (owner, 2026-10-31: no "Everything about" link). */}
              <h2 id="quote-labels-title" className={`t-h3 ${styles.quoteLabelsTitle}`}>Paired with <Link href={`/assets/${quoteAsset.mint}`}>{quote}</Link></h2>
              <p className={styles.quoteLabelsNote}>
                Every trade of {launch.symbol} is paid in {quote}. What its mint and the token list say about {quote}; each label informs
                and none stops a trade.
              </p>
              <QuoteLabelList quote={quoteAsset} />
            </section>
          )}
          {rewards && <div className={styles.wide}><RewardsCard rewards={rewards} symbol={launch.symbol} platform={platform} /></div>}
          {liquidityTax && (
            <div className={styles.wide}>
              <LiquidityTaxCard tax={liquidityTax} symbol={launch.symbol} quote={launch.quote} graduated={launch.graduation !== null} platform={platform} />
            </div>
          )}
          {earnings && <div className={styles.wide}><EarningsCard earnings={earnings} symbol={launch.symbol} platform={platform} weighted={weighted} /></div>}
          {airdropDone && airdrop && <div className={styles.wide}><AirdropCard initial={airdrop} symbol={launch.symbol} platform={platform} /></div>}
        </section>
      ) : null}
    </article>
  );
}


/**
 * A coin's page for a coin on an EVM chain (#253): the same breadcrumb and title row, then what the API has for such a
 * coin today, the chart, the trades, the trade panel and the About block with the coin's links and its addresses on the
 * chain's own explorer. The cards a Solana coin's page reads from the chain (holders, trust figures, a Creator Lock's
 * stage, rewards, earnings under a rule) come with an EVM chain's own reads (#256), and none of their endpoints is asked.
 */
async function EvmCoinPage({ mint, chains, referrer }: { mint: string; chains: readonly Chain[]; referrer: string | null }) {
  if (evmChainsOf(chains).length === 0) notFound();
  const [launch, platform, trades] = await Promise.all([getLaunch(mint), getPlatform(), listTrades(mint)]);
  if (!launch || !isEvm(launch.chain) || !chains.includes(launch.chain)) notFound();
  // What the chain offers, read by the API from its contracts: the trade panel needs it. When the chain does not answer
  // just now the page still shows the coin, with the chain's name and explorer from the API's own list of chains.
  const options = await getEvmLaunchOptions(launch.chain).catch(() => null);
  const chain = options ?? (await listChains()).chains.find((c) => c.chain === launch.chain);
  if (!chain) throw new Error(`the API does not read ${launch.chain}`);
  const quote = quoteTicker(launch.quote);
  const origin = await siteOrigin();
  const links: CoinLink[] = [{ label: "Explorer", href: explorerUrl("address", launch.mint, { cluster: platform.cluster, rpcUrl: platform.rpcUrl, explorer: chain.explorer }), external: false }];

  return (
    <article className={`shell ${styles.page}`}>
      <JsonLd data={breadcrumbList(origin, [["Home", "/"], ["Coins", "/coins"], [`${launch.symbol} / ${quote}`, `/coin/${launch.mint}`]])} />
      <nav aria-label="Breadcrumb" className={styles.crumbs}>
        <ol>
          <li><Link href="/coins">Explore</Link></li>
          <li><Link href={`/coins?quote=${launch.quote.mint}`}>Paired with {quote}</Link></li>
          <li aria-current="page">{launch.symbol}</li>
        </ol>
      </nav>
      <EvmCoinMarket
        initial={launch} platform={platform} chain={{ name: chain.name, explorer: chain.explorer }} options={options} links={links} initialTrades={trades.trades}
        renderedAt={Date.now()} referrer={referrer}
      />
    </article>
  );
}
