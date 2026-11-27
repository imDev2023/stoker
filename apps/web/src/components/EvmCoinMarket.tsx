"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { EvmLaunchOptions, LaunchSummary, PlatformInfo, Trade, TradeSide } from "@launchpad/contract";
import { getLaunch, listTrades } from "@/lib/api";
import { quoteTicker, type ExplorerTarget } from "@/lib/format";
import { Change } from "./Change";
import { CoinChart, idle } from "./CoinChart";
import { Title, type CoinLink } from "./CoinMarket";
import { EmptyState } from "./EmptyState";
import { EvmCoinFacts } from "./EvmCoinFacts";
import { EvmTradePanel } from "./EvmTradePanel";
import { Price } from "./Price";
import { TradeHistory } from "./TradeHistory";
import styles from "./CoinMarket.module.css";

const REFRESH_MS = 4_000;

/**
 * The live part of a coin's page for a coin on an EVM chain (#253), a sibling of `CoinMarket` on the same grid: the
 * title row with the price and the day's change, the chart, the trades, and beside them the trade panel with the coin's
 * facts under it, all kept up to date from the indexed trades. It shows what the API has for such a coin today and asks
 * for nothing else: the holders, the trust figures, a Creator Lock's stage, the chart's marks and the graduation bar are
 * read from Solana alone and join this page with an EVM chain's own reads (#256).
 */
export function EvmCoinMarket({
  initial, platform, chain, options, links, initialTrades, renderedAt, referrer = null,
}: {
  initial: LaunchSummary;
  platform: PlatformInfo;
  /** The coin's chain: its name in full, and its block explorer, where every address and transaction links. */
  chain: { name: string; explorer: string };
  /** What the chain offers, read by the API from its contracts; null when it could not be read just now, and the page then shows the coin without a way to trade it. */
  options: EvmLaunchOptions | null;
  links: CoinLink[];
  initialTrades: Trade[];
  /** The server's clock at render, so relative trade times hydrate to the same text. */
  renderedAt: number;
  /** From the page's `?ref=` link: the address credited the Referrer Fee on the visitor's trades. */
  referrer?: string | null;
}) {
  const [launch, setLaunch] = useState(initial);
  const [trades, setTrades] = useState(initialTrades);
  const [now, setNow] = useState(renderedAt);
  const [sideRequest, setSideRequest] = useState<{ side: TradeSide; seq: number } | null>(null);
  const chartPoll = useRef<() => Promise<void>>(idle);
  const tradeBox = useRef<HTMLDivElement>(null);
  const quote = quoteTicker(launch.quote);
  const price = launch.market.price;
  const explorer: ExplorerTarget = { cluster: platform.cluster, rpcUrl: platform.rpcUrl, explorer: chain.explorer };
  // Every coin of an EVM chain's Launch Shape has 18 decimals; the chain's own figure is used whenever it was read.
  const coinDecimals = options?.decimals ?? 18;

  const refresh = useCallback(async () => {
    try {
      const [l, t] = await Promise.all([getLaunch(launch.mint), listTrades(launch.mint), chartPoll.current()]);
      if (l) setLaunch(l);
      setTrades(t.trades);
    } catch {
      // keep showing the last good data; the next tick retries
    }
    setNow(Date.now());
  }, [launch.mint]);

  useEffect(() => {
    const id = setInterval(refresh, REFRESH_MS);
    return () => clearInterval(id);
  }, [refresh]);

  /** The phone's bar: the panel takes the side and scrolls into view under the header. */
  function goTrade(side: TradeSide) {
    setSideRequest({ side, seq: Date.now() });
    tradeBox.current?.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  return (
    <>
      <header className={styles.head}>
        <Title launch={launch} quote={quote} links={links} />
        <p className={styles.price}>
          {price === null ? (
            <span className={styles.noPrice}>No price yet</span>
          ) : (
            <>
              <Price value={price} /> <span className={styles.unit}>{quote}</span>
            </>
          )}
          <Change value={launch.market.change24h} className={styles.change} />
        </p>
      </header>

      <div className={`grid ${styles.market}`}>
        <div className={`col-8 ${styles.main}`}>
          <div className={styles.chart}>
            <CoinChart launch={launch} quote={quote} poll={chartPoll} hasTrades={trades.length > 0} coinDecimals={coinDecimals} marks={false} />
          </div>
          {/* The tab is the panel's title, as on every coin's page: the panel keeps its heading for its region's name, unseen. */}
          <div className={`card ${styles.tabs}`}>
            <div className={styles.tabBar} role="tablist" aria-label="Activity">
              <button type="button" role="tab" aria-selected>Trades</button>
            </div>
            <div className={styles.tabPanel} role="tabpanel">
              <TradeHistory
                trades={trades} symbol={launch.symbol} quote={launch.quote} platform={explorer} now={now} graduation={null} headingHidden
                coinDecimals={coinDecimals}
              />
            </div>
          </div>
        </div>
        <div className={`col-4 ${styles.side}`}>
          <div className={styles.trade} ref={tradeBox}>
            {options ? (
              <EvmTradePanel launch={launch} options={options} platform={platform} referrer={referrer} sideRequest={sideRequest} onTraded={() => void refresh()} />
            ) : (
              <EmptyState title="Trading can't be read just now">This coin&apos;s chain did not answer, so the trade panel is away for the moment. Reload the page to try again.</EmptyState>
            )}
          </div>
          <div className={styles.facts}>
            <EvmCoinFacts launch={launch} chainName={chain.name} explorer={explorer} renderedAt={renderedAt} />
          </div>
        </div>
      </div>

      {/* The phone's Buy / Sell bar, above the site's tab bar: each button brings the trade panel up on its side. */}
      {options && (
        <div className={styles.tradeBar} data-trade-bar>
          <button type="button" className={`button button-primary ${styles.barBuy}`} onClick={() => goTrade("buy")}>Buy</button>
          <button type="button" className="button button-ghost" onClick={() => goTrade("sell")}>Sell</button>
        </div>
      )}
    </>
  );
}
