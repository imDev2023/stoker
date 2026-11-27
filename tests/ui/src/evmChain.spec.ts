// Launching and trading on an EVM chain from the site, with an EVM wallet (#253), on the stack's fork of Robinhood
// Chain: the launch form that starts with the chain, a launch paired with a Stock Token by a permit and a transaction,
// a buy and a sell whose quotes the chain delivers to the unit, the Opening Fee in a Launch's first seconds, the switch
// a wallet on another network is asked for before anything can be signed, the unaudited statement in both places, the
// chain named in plain text alone, and the names the chain's own rules refuse. The site shows the chain only to a
// browser that carries the preview cookie, so the last flow proves that without it nothing here exists. Every flow is
// skipped on a stack without a fork (no `ROBINHOOD_RPC_URL`).
import type { BrowserContext, Locator, Page } from "@playwright/test";
import { CopyCheck } from "@launchpad/contract";
import { coinImage, expect, expectHydrated, expectNoHorizontalOverflow, expectNoTruncatedText, SCHEME_COOKIE, stackEnv, test } from "./fixtures";
import {
  afterOpeningFee, CHAIN_NAME, COIN_DECIMALS, evmBalance, evmStack, fundedEvmKey, hasEvm, installEvmWallet, launchedAtOf, launchEvmViaApi, launchOf, launchOptions,
  listStock, quoteOf, showPreviewChains, STOCK, UNAUDITED, type EvmKey,
} from "./evm";
import { connectEvmTestWallet, TEST_EVM_WALLET_NAME, type EvmTestWallet } from "./evmWallet";
import { fillForm, firstBuyField, formAlert, signButton, signing, summary } from "./launchPage";
import { accountArea, TEST_WALLET_NAME } from "./wallet";

test.skip(() => !hasEvm(), "the stack has no EVM fork: ROBINHOOD_RPC_URL is not set");

test.beforeAll(async () => {
  if (hasEvm()) await listStock();
});

/** The Stock Token a wallet starts with, and the First Buy and the trades it makes with it: raw units of 18 decimals. */
const STOCK_FUNDS = 10n ** 17n;
const FIRST_BUY = { text: "0.04", raw: 4n * 10n ** 16n };
const BUY = { text: "0.02", raw: 2n * 10n ** 16n };

const chainChoice = (page: Page) => page.getByRole("radiogroup", { name: "Chain" });
const pairChoice = (page: Page) => page.getByRole("radiogroup", { name: "Paired with" });
const tradePanel = (page: Page) => page.getByRole("region", { name: /^Trade( |$)/ });
/** A fact's value by its term, in the launch summary or a coin's About block. */
const fact = (scope: Locator, term: string) => scope.getByText(term, { exact: true }).locator("xpath=following-sibling::dd");
const statement = (scope: Locator) => scope.locator("[data-unaudited]");
/** The switch that stands where the sign button would while the wallet is on another network. */
const network = (scope: Locator) => scope.getByRole("group", { name: "Network" });
const SWITCH = `Switch to ${CHAIN_NAME}`;
const WRONG_NETWORK = `Your wallet is on another network. Switch it to ${CHAIN_NAME} to go on.`;

/** Whole units as the site writes them: thousands separators, then every decimal that is not a trailing zero. */
function units(raw: bigint, decimals: number, maxDecimals = decimals) {
  const whole = raw / 10n ** BigInt(decimals);
  const fraction = (raw % 10n ** BigInt(decimals)).toString().padStart(decimals, "0").slice(0, maxDecimals).replace(/0+$/, "");
  return `${whole.toLocaleString("en-US")}${fraction ? `.${fraction}` : ""}`;
}

/** The launch form with the fork's chain chosen in its first section: every later section is then that chain's own. */
async function openLaunchForm(page: Page) {
  await page.goto("/launch");
  await expectHydrated(page);
  // The form starts with the chain: Solana first and chosen, then the fork's, each in plain text and in full.
  await expect(chainChoice(page).getByRole("radio")).toHaveCount(2);
  await expect(chainChoice(page).getByRole("radio", { name: "Solana", exact: true })).toBeChecked();
  await chainChoice(page).getByRole("radio", { name: CHAIN_NAME, exact: true }).check();
  await expect(fact(summary(page), "Chain")).toHaveText(CHAIN_NAME);
}

/** The looks a baseline is kept in. The flows run at the first; what is new is shot at each. */
const LOOKS = [
  { name: "desktop-light", viewport: { width: 1440, height: 900 }, scheme: "light" },
  { name: "desktop-dark", viewport: { width: 1440, height: 900 }, scheme: "dark" },
  { name: "phone-light", viewport: { width: 390, height: 844 }, scheme: "light" },
  { name: "phone-dark", viewport: { width: 390, height: 844 }, scheme: "dark" },
] as const;

/** The browser at one look, before the page is opened at it: the scheme is the site's cookie, the width the window's. */
async function setLook(page: Page, context: BrowserContext, baseURL: string | undefined, look: (typeof LOOKS)[number]) {
  await context.addCookies([{ name: SCHEME_COOKIE, value: look.scheme, url: baseURL! }]);
  await page.setViewportSize(look.viewport);
}

/**
 * A page settled for a shot: the network quiet (a chart page now and then never reports it, so the wait is bounded, as
 * in visual.spec.ts), every chart drawn, fonts in, the fields React's, the page at its top and the pointer parked. The
 * sticky header, which would sit over the top of an element taller than the window, and the launch summary's sticky
 * column scroll away with the page, as `unstickHeader` has it.
 */
async function settled(page: Page) {
  await page.waitForLoadState("networkidle", { timeout: 20_000 }).catch(() => undefined);
  await expect(page.locator('[data-chart="loading"]')).toHaveCount(0, { timeout: 60_000 });
  await page.evaluate(() => document.fonts.ready);
  await expectHydrated(page);
  await page.addStyleTag({ content: 'body > header, aside[aria-label="Launch summary"] { position: static !important; } html { scroll-padding-top: 0 !important; }' });
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
  await page.mouse.move(0, 0);
  await expectNoHorizontalOverflow(page);
}

/** What differs between runs on any page: times, addresses and the wallet's avatar, whose hues come from its address. */
const moving = (page: Page) => ["time", ".mono:not(input)", "[data-avatar]"].map((s) => page.locator(s).filter({ visible: true }));
/**
 * What differs between runs in the launch summary: the launch's cost, an estimate of gas at the fork's price for a
 * wallet drawn afresh, in the facts and in the signing panel; and the statement's link, an address.
 */
const launchMoving = (page: Page) => [summary(page).locator("[data-launch-cost]"), summary(page).locator("[data-network-fee]"), statement(summary(page)).getByRole("link")];

/** The copy check answers a moment after the fields are filled; a shot waits for its verdicts so it never catches "Checking". */
async function copyCheckSettled(page: Page) {
  const coin = page.getByRole("region", { name: "Your coin" });
  await expect(coin).toHaveAttribute("aria-busy", "false");
  await expect(coin.getByText("Checking")).toHaveCount(0);
}

/** Connects the EVM test wallet from the page's own "Connect wallet": the launch summary's or the trade panel's. */
const connectOnPage = (page: Page) => connectEvmTestWallet(page, page.getByRole("main").getByRole("button", { name: "Connect wallet" }));

const methods = (wallet: EvmTestWallet) => wallet.requests.map((r) => r.method);

test.describe("with the chain shown", () => {
  test.beforeEach(async ({ context, baseURL }) => showPreviewChains(context, baseURL));

  test.describe("a coin paired with a Stock Token, from the form to a buy and a sell", () => {
    test.describe.configure({ mode: "serial", timeout: 240_000 });
    let creator: EvmKey;
    let coin: string;

    test("a Creator launches a standard coin paired with a Stock Token, with a First Buy, by one permit and one transaction, and lands on its page", async ({ page }) => {
      creator = await fundedEvmKey({ stock: STOCK_FUNDS });
      const wallet = await installEvmWallet(page, creator);
      const options = await launchOptions();
      await openLaunchForm(page);
      await connectOnPage(page);
      await expect(signButton(page)).toBeVisible();
      await fillForm(page, { name: "Anvil Spark", symbol: "ANVL", description: "A standard coin on the fork, paired with a Stock Token." });

      // Only what the chain offers: its listed Quote Assets, the native asset first and chosen, the Stock Token under the chain's own name for one.
      await expect(pairChoice(page).getByRole("radio", { name: /^ETH\b/ })).toBeChecked();
      const stock = pairChoice(page).getByRole("radio", { name: new RegExp(`^${STOCK.symbol}\\b`) });
      await expect(stock).toHaveAccessibleName(`${STOCK.symbol} Stock Tokens`);
      await stock.check();
      await expect(page.getByRole("button", { name: /Choose another Quote Asset/ })).toHaveCount(0);
      await expect(page.getByRole("radiogroup", { name: "Launch type" }).getByRole("radio", { name: "Standard" })).toBeChecked();

      // The summary is the review: the First Buy and what it gets, and the launch's cost in the native asset before anything is signed.
      await firstBuyField(page).fill(FIRST_BUY.text);
      const review = summary(page);
      await expect(fact(review, "First buy")).toHaveText(`${FIRST_BUY.text} ${STOCK.symbol}`);
      const gets = fact(review, "You get");
      await expect(gets).toHaveAttribute("data-coins-out", /^[1-9]\d*$/);
      const coinsOut = BigInt((await gets.getAttribute("data-coins-out"))!);
      await expect(gets).toContainText(`${units(coinsOut, COIN_DECIMALS, 0)} ANVL`);
      await expect(fact(review, "Launch cost")).toHaveText(/^About 0\.\d+\sETH in network fees$/);
      await expect(page.getByText(`Paying in ${STOCK.symbol} takes a permit and a transaction, so your wallet asks twice.`, { exact: false })).toBeVisible();
      expect(wallet.requests).toHaveLength(0);

      await signButton(page).click();
      await page.waitForURL(/\/coin\/0x[0-9a-fA-F]{40}$/, { timeout: 120_000 });
      coin = new URL(page.url()).pathname.split("/").pop()!;

      // One signature of typed data, the asset's own permit for exactly the First Buy to the factory, then one transaction.
      expect(methods(wallet)).toEqual(["eth_signTypedData_v4", "eth_sendTransaction"]);
      const permit = wallet.requests[0] as Extract<EvmTestWallet["requests"][number], { method: "eth_signTypedData_v4" }>;
      expect(permit.typedData).toMatchObject({ primaryType: "Permit", message: { owner: creator.address, spender: options.contracts.factory, value: FIRST_BUY.raw.toString() } });
      expect(wallet.sent).toHaveLength(1);

      // The coin's page names the coin, its pair and its chain.
      await expect(page.getByRole("heading", { level: 1 })).toContainText("ANVL");
      await expect(page.getByRole("heading", { level: 1 })).toContainText(STOCK.symbol);
      await expect(page.getByText("Anvil Spark", { exact: true })).toBeVisible();
      await expect(fact(page.getByRole("main"), "Chain")).toHaveText(CHAIN_NAME);
      const launch = await launchOf(coin);
      expect(launch).toMatchObject({ chain: "robinhood", name: "Anvil Spark", symbol: "ANVL", creator: creator.address, createdSignature: wallet.sent[0] });
      expect(launch.quote.mint.toLowerCase()).toBe(STOCK.address.toLowerCase());

      // The wallet holds exactly the coins the summary said the First Buy gets, and paid exactly the First Buy.
      expect(await evmBalance(coin, creator.address)).toBe(coinsOut);
      expect(await evmBalance(STOCK.address, creator.address)).toBe(STOCK_FUNDS - FIRST_BUY.raw);
      await expectNoHorizontalOverflow(page);
    });

    test("a buy with the Stock Token and a sell of that coin each deliver what the panel quoted, to the unit", async ({ page }) => {
      const wallet = await installEvmWallet(page, creator);
      // After the Opening Fee's window, so a quote does not fall while the wallet signs.
      await afterOpeningFee(await launchedAtOf(coin));
      await page.goto(`/coin/${coin}`);
      const panel = tradePanel(page);
      await connectEvmTestWallet(page, panel.getByRole("button", { name: "Connect wallet" }));
      await expect(panel.getByRole("button", { name: "Review buy" })).toBeVisible();
      await expect(panel.getByText(/^Balance/)).toHaveText(`Balance ${units(STOCK_FUNDS - FIRST_BUY.raw, STOCK.decimals, 4)} ${STOCK.symbol}`);

      /**
       * Walks the wallet through a trade's three asks (an approval of the asset, once; the trade's permit; the trade),
       * holding each so the panel's words for it can be read, and answers what the panel quoted once the trade itself
       * is before the wallet: the figure of the very transaction it then sends.
       */
      async function signHeld(action: "buy" | "sell") {
        const asked = wallet.requests.length;
        const approval = wallet.holdNext();
        await panel.getByRole("button", { name: `Sign and ${action}` }).click();
        await expect(panel.getByRole("button", { name: "Approve in your wallet…" })).toBeVisible({ timeout: 60_000 });
        const permit = wallet.holdNext();
        approval.release();
        await expect(panel.getByRole("button", { name: "Sign the permit in your wallet…" })).toBeVisible({ timeout: 60_000 });
        const trade = wallet.holdNext();
        permit.release();
        await expect(panel.getByRole("button", { name: "Confirm in your wallet…" })).toBeVisible({ timeout: 60_000 });
        expect(methods(wallet).slice(asked)).toEqual(["eth_sendTransaction", "eth_signTypedData_v4", "eth_sendTransaction"]);
        const quoted = BigInt((await panel.locator("[data-amount-out]").getAttribute("data-amount-out"))!);
        return { quoted, send: () => trade.release() };
      }

      // A buy: the quote is what reaches the wallet after every fee, and outside the window there is no Opening Fee.
      await panel.getByLabel("You pay").fill(BUY.text);
      await expect(panel.getByText("You get about")).toBeVisible();
      await expect(panel.locator('[data-fee="Platform Fee"]')).toBeVisible();
      await expect(panel.locator('[data-fee="Opening Fee"]')).toHaveCount(0);
      await expect(panel.locator("[data-opening-fee]")).toHaveCount(0);
      await panel.getByRole("button", { name: "Review buy" }).click();
      await expect(panel.getByRole("region", { name: "Review your trade" })).toContainText(`Your wallet pays ${BUY.text} ${STOCK.symbol}, and the network fee in ETH. Your wallet is asked three times`);
      const buy = await signHeld("buy");
      const coinsBefore = await evmBalance(coin, creator.address);
      const stockBefore = await evmBalance(STOCK.address, creator.address);
      buy.send();
      const bought = panel.getByRole("status").filter({ hasText: "Bought" });
      await expect(bought).toBeVisible({ timeout: 60_000 });
      expect((await evmBalance(coin, creator.address)) - coinsBefore).toBe(buy.quoted);
      expect(stockBefore - (await evmBalance(STOCK.address, creator.address))).toBe(BUY.raw);
      // What the panel then says the trade moved is the chain's own figure, the same one.
      await expect(bought).toHaveAttribute("data-coins", buy.quoted.toString());
      await expect(bought).toHaveAttribute("data-quote", BUY.raw.toString());

      // A sell of half the holding: the quote is the Stock Token that reaches the wallet.
      await panel.getByRole("group", { name: "Buy or sell" }).getByRole("button", { name: "Sell" }).click();
      const held = await evmBalance(coin, creator.address);
      await expect(panel.getByText(/^Balance/)).toHaveText(`Balance ${units(held, COIN_DECIMALS, 4)} ANVL`, { timeout: 30_000 });
      await panel.getByRole("button", { name: "50%", exact: true }).click();
      await expect(panel.getByText("You get about")).toBeVisible();
      await panel.getByRole("button", { name: "Review sell" }).click();
      await expect(panel.getByRole("region", { name: "Review your trade" })).toContainText("Your wallet is asked three times: an approval of ANVL");
      const sell = await signHeld("sell");
      const stockHeld = await evmBalance(STOCK.address, creator.address);
      sell.send();
      const sold = panel.getByRole("status").filter({ hasText: "Sold" });
      await expect(sold).toBeVisible({ timeout: 60_000 });
      expect((await evmBalance(STOCK.address, creator.address)) - stockHeld).toBe(sell.quoted);
      expect(held - (await evmBalance(coin, creator.address))).toBe(held / 2n);
      await expect(sold).toHaveAttribute("data-quote", sell.quoted.toString());
      await expect(sold).toHaveAttribute("data-coins", (held / 2n).toString());

      // Both trades are on the coin's page, read from the chain by the Indexer.
      await expect(page.getByRole("region", { name: "Trades", exact: true }).getByRole("row")).toHaveCount(4, { timeout: 30_000 });
      await expectNoHorizontalOverflow(page);
    });
  });

  test("a launch paired with the native asset, with a First Buy, is one wallet request", async ({ page }) => {
    test.setTimeout(180_000);
    const creator = await fundedEvmKey();
    const wallet = await installEvmWallet(page, creator);
    await openLaunchForm(page);
    await connectOnPage(page);
    await fillForm(page, { name: "Kindling Stack", symbol: "KNDL" });
    await expect(pairChoice(page).getByRole("radio", { name: /^ETH\b/ })).toBeChecked();
    await firstBuyField(page).fill("0.03");
    const gets = fact(summary(page), "You get");
    await expect(gets).toHaveAttribute("data-coins-out", /^[1-9]\d*$/);
    const coinsOut = BigInt((await gets.getAttribute("data-coins-out"))!);
    // The cost says the First Buy too: with the native asset it is sent with the launch itself.
    await expect(fact(summary(page), "Launch cost")).toHaveText(/^About 0\.\d+\sETH in network fees, and your first buy of 0\.03\sETH$/);
    await expect(page.getByText("Your own buy inside the launch transaction: one signature in your wallet.", { exact: false })).toBeVisible();

    await signButton(page).click();
    await page.waitForURL(/\/coin\/0x[0-9a-fA-F]{40}$/, { timeout: 120_000 });
    const coin = new URL(page.url()).pathname.split("/").pop()!;
    expect(methods(wallet)).toEqual(["eth_sendTransaction"]);
    const sent = wallet.requests[0] as Extract<EvmTestWallet["requests"][number], { method: "eth_sendTransaction" }>;
    expect(BigInt(sent.transaction.value!)).toBe(3n * 10n ** 16n);
    await expect(page.getByRole("heading", { level: 1 })).toContainText("KNDL");
    expect(await evmBalance(coin, creator.address)).toBe(coinsOut);
  });

  test("inside a Launch's first seconds the panel names the Opening Fee with its sentence, and both are gone once the window has passed", async ({ page }) => {
    test.setTimeout(180_000);
    const launched = await launchEvmViaApi(await fundedEvmKey(), { name: "Bellows Breath", symbol: "BLWS" });
    await page.goto(`/coin/${launched.coin}`);
    await expectHydrated(page);
    const panel = tradePanel(page);
    await panel.getByLabel("You pay").fill("0.01");
    // The fork's clock stands at the launch's last block until something is sent, so the window is still open however long the page took.
    const fee = panel.locator('[data-fee="Opening Fee"]');
    await expect(fee.locator("dt")).toHaveText("Opening Fee, into BLWS's own liquidity");
    const sentence = panel.locator("[data-opening-fee]");
    await expect(sentence).toHaveText(/^The Opening Fee is running\. It falls every second until \d{1,2}:\d{2}:\d{2} (AM|PM), all of it goes into BLWS's own liquidity, and a buy that lands later pays less\.$/);
    // The figures are the API's own read of the chain at that second: what reaches the wallet, and the fee by its amount.
    const inside = await quoteOf(launched.coin, "buy", 10n ** 16n);
    expect(inside.opening).not.toBeNull();
    expect(BigInt(inside.fees.opening)).toBeGreaterThan(0n);
    await expect(panel.locator("[data-amount-out]")).toHaveAttribute("data-amount-out", inside.amountOut);
    await expect(fee.locator("dd")).toHaveText(`${units(BigInt(inside.fees.opening), 18, 6)} ETH`);
    await expect(panel.locator('[data-fee="Platform Fee"] dd')).toHaveText(`${units(BigInt(inside.fees.platform), 18, 6)} ETH`);

    // Once the window has passed the panel asks again by itself: no Opening Fee line, no sentence, and more coins for the same buy.
    await afterOpeningFee(launched.launchedAt);
    await expect(fee).toHaveCount(0, { timeout: 30_000 });
    await expect(sentence).toHaveCount(0);
    const after = await quoteOf(launched.coin, "buy", 10n ** 16n);
    expect(after.opening).toBeNull();
    expect(after.fees.opening).toBe("0");
    await expect(panel.locator("[data-amount-out]")).toHaveAttribute("data-amount-out", after.amountOut);
    expect(BigInt(after.amountOut)).toBeGreaterThan(BigInt(inside.amountOut));
    await expect(panel.locator('[data-fee="Platform Fee"]')).toBeVisible();
    await expectNoHorizontalOverflow(page);
  });

  test("a wallet on another network is asked to switch on the launch form, and can sign nothing before it has", async ({ page }) => {
    // The wallet starts on Ethereum and has never met the fork's chain, so the site adds the chain before it switches.
    const wallet = await installEvmWallet(page, await fundedEvmKey(), { startChainId: 1, unknownChain: true });
    await openLaunchForm(page);
    await connectOnPage(page);
    const prompt = network(summary(page));
    await expect(prompt).toContainText(WRONG_NETWORK);
    await expect(prompt.getByRole("button", { name: SWITCH })).toBeVisible();
    // Where the sign button would be: there is none, and a form sent from the keyboard asks the wallet for nothing.
    await expect(signButton(page)).toHaveCount(0);
    await fillForm(page, { name: "Wrong Lane", symbol: "WLANE" });
    await page.getByLabel("Name").press("Enter");
    await expect(prompt.getByRole("button", { name: SWITCH })).toBeVisible();
    expect(wallet.requests).toHaveLength(0);
    expect(wallet.chainId()).toBe(1);

    await prompt.getByRole("button", { name: SWITCH }).click();
    await expect(signButton(page)).toBeVisible();
    await expect(signButton(page)).toHaveText("Stoke WLANE");
    await expect(prompt).toHaveCount(0);
    expect(wallet.chainId()).toBe(evmStack().chainId);
    expect(wallet.requests).toHaveLength(0);
  });

  test("a wallet on another network is asked to switch in the trade panel, and can sign nothing before it has", async ({ page }) => {
    test.setTimeout(180_000);
    const launched = await launchEvmViaApi(await fundedEvmKey(), { name: "Crucible Cup", symbol: "CRUC" });
    const wallet = await installEvmWallet(page, await fundedEvmKey(), { startChainId: 1 });
    await page.goto(`/coin/${launched.coin}`);
    const panel = tradePanel(page);
    await connectEvmTestWallet(page, panel.getByRole("button", { name: "Connect wallet" }));
    const prompt = network(panel);
    await expect(prompt).toContainText(WRONG_NETWORK);
    // An amount and its quote change nothing: the switch stands where "Review buy" would, and nothing is asked.
    await panel.getByLabel("You pay").fill("0.01");
    await expect(panel.getByText("You get about")).toBeVisible();
    await expect(panel.getByRole("button", { name: /^Review (buy|sell)$/ })).toHaveCount(0);
    await panel.getByLabel("You pay").press("Enter");
    await expect(prompt.getByRole("button", { name: SWITCH })).toBeVisible();
    expect(wallet.requests).toHaveLength(0);

    await prompt.getByRole("button", { name: SWITCH }).click();
    await expect(panel.getByRole("button", { name: "Review buy" })).toBeEnabled();
    await expect(prompt).toHaveCount(0);
    expect(wallet.chainId()).toBe(evmStack().chainId);
    expect(wallet.requests).toHaveLength(0);
  });

  test("the unaudited statement is in the launch summary and in the trade panel, word for word, as plain text with the link to the verified source", async ({ page }) => {
    test.setTimeout(180_000);
    const { contracts } = await launchOptions();
    expect(contracts.source).toMatch(/^https:\/\/.+\/address\/0x[0-9a-fA-F]{40}\?tab=contract$/);
    /** In these words, linking to the source, standing in the page itself: no dialog holds it, and nothing near it is ticked. */
    async function expectStatement(scope: Locator) {
      const s = statement(scope);
      await expect(s).toHaveCount(1);
      await expect(s).toHaveText(`${UNAUDITED}${contracts.source.replace(/^https?:\/\//, "")}.`);
      await expect(s.getByRole("link")).toHaveAttribute("href", contracts.source);
      expect(await s.evaluate((el) => ({ tag: el.tagName, inDialog: el.closest("dialog, [role=dialog], [role=alertdialog]") !== null }))).toEqual({ tag: "P", inDialog: false });
      await expect(scope.getByRole("checkbox")).toHaveCount(0);
      await expect(page.getByRole("dialog")).toHaveCount(0);
    }
    // On the form it is there from the first look, before a wallet is connected, above the action.
    await openLaunchForm(page);
    await expectStatement(summary(page));
    const launched = await launchEvmViaApi(await fundedEvmKey(), { name: "Slate Ledger", symbol: "SLTE" });
    await page.goto(`/coin/${launched.coin}`);
    await expectHydrated(page);
    await expectStatement(tradePanel(page));
  });

  test("the chain is named in plain text and in full alone: no image, icon or badge of it on the launch form, a coin's page, the board or the account menu", async ({ page }) => {
    test.setTimeout(180_000);
    const { contracts } = await launchOptions();
    const launched = await launchEvmViaApi(await fundedEvmKey(), { name: "Chalk Mark", symbol: "CHLK" });
    await installEvmWallet(page, await fundedEvmKey());

    /**
     * Nothing drawn names the chain (an image, an svg, an icon or a tag by its alt, title, label, address or text, or a
     * background), and wherever its name is written it is "Robinhood Chain" whole. The explorer's own host, in the
     * statement's link, is an address and not a name, so that link's text is left out of the reading.
     */
    async function expectPlainTextAlone(named: boolean) {
      const found = await page.evaluate((linkText) => {
        const mentions = (s: string | null | undefined) => /robin\s*hood|\bhood\b|\brh\b/i.test(s ?? "");
        const drawn = [...document.querySelectorAll("img, svg, image, use, picture, source, canvas, [role=img], .tag")]
          // A picture carried inline (a wallet's own icon, a coin's preview) is bytes, not an address: only where one is fetched from is read.
          .filter((el) => ["alt", "title", "aria-label", "src", "srcset", "href", "xlink:href"].some((a) => mentions((el.getAttribute(a) ?? "").replace(/^(data|blob):.*$/s, ""))) || mentions(el.querySelector("title, desc")?.textContent) || (el.matches(".tag, [role=img]") && mentions(el.textContent)))
          .map((el) => el.outerHTML.slice(0, 160));
        const backgrounds = [...document.querySelectorAll("body *")].filter((el) => mentions(getComputedStyle(el).backgroundImage)).map((el) => el.outerHTML.slice(0, 160));
        const text = document.body.innerText.replaceAll(linkText, "");
        return { drawn, backgrounds, names: text.match(/robin\s*hood(\s+chain)?|\bhood chain\b|\brh chain\b|\brhc\b/gi) ?? [] };
      }, contracts.source.replace(/^https?:\/\//, ""));
      expect({ drawn: found.drawn, backgrounds: found.backgrounds }).toEqual({ drawn: [], backgrounds: [] });
      expect(found.names.filter((n) => n !== CHAIN_NAME)).toEqual([]);
      if (named) expect(found.names.length).toBeGreaterThan(0);
    }

    await openLaunchForm(page);
    await connectOnPage(page);
    await expect(signButton(page)).toBeVisible();
    await expectPlainTextAlone(true);

    await page.goto(`/coin/${launched.coin}`);
    await expect(fact(page.getByRole("main"), "Chain")).toHaveText(CHAIN_NAME);
    await expect(statement(tradePanel(page))).toBeVisible();
    await expectPlainTextAlone(true);

    // The board lists the coin beside Solana's, as a table and as cards.
    for (const view of ["table", "cards"]) {
      await page.goto(`/coins?view=${view}&q=Chalk+Mark`);
      await expect(page.locator(`a[href="/coin/${launched.coin}"]`).first()).toBeVisible();
      await expectPlainTextAlone(false);
    }

    // The account menu: each chain family under its own name, the EVM wallet connected under the chain's.
    await page.getByRole("banner").getByRole("button", { name: /0x/i }).click();
    const menu = page.getByRole("menu", { name: "Wallets" });
    await expect(menu.getByRole("group", { name: CHAIN_NAME })).toContainText(CHAIN_NAME);
    await expect(menu.getByRole("group", { name: "Solana" })).toBeVisible();
    await expectPlainTextAlone(true);
  });

  test("the form refuses the chain's name in a coin's name, the ticker HOOD and a Stock Token's ticker, each with the API's reason under the field, and sends none", async ({ page }) => {
    const creator = await fundedEvmKey();
    const wallet = await installEvmWallet(page, creator);
    let prepares = 0;
    page.on("request", (r) => {
      if (r.method() === "POST" && new URL(r.url()).pathname === "/v1/launches/prepare") prepares++;
    });
    /** What the API's own check says of the text, as any client may ask it. */
    async function reasonOf(field: "name" | "symbol", fields: { name: string; symbol: string }) {
      const body = new FormData();
      for (const [k, v] of Object.entries({ chain: "robinhood", ...fields })) body.set(k, v);
      const check = CopyCheck.parse(await (await fetch(`${stackEnv().apiUrl}/v1/launches/check`, { method: "POST", body })).json());
      const reason = check.refusals?.find((r) => r.field === field)?.reason;
      if (!reason) throw new Error(`the API refuses no ${field} in ${JSON.stringify(fields)}`);
      return reason;
    }

    await openLaunchForm(page);
    await connectOnPage(page);
    await page.locator('input[type="file"]').setInputFiles({ name: "coin.png", mimeType: "image/png", buffer: coinImage("RFSD") });
    const cases = [
      { field: "name", name: "Robinhood Rocket", symbol: "RFSD", says: /can't use the name Robinhood/ },
      { field: "symbol", name: "Refused Ticker", symbol: "HOOD", says: /^The ticker HOOD can't be used on Robinhood Chain/ },
      { field: "symbol", name: "Refused Stock", symbol: STOCK.symbol, says: new RegExp(`^${STOCK.symbol} is the ticker of a Stock Token on Robinhood Chain`) },
    ] as const;
    for (const c of cases) {
      await page.getByLabel("Name").fill(c.name);
      await page.getByLabel("Ticker").fill(c.symbol);
      const reason = await reasonOf(c.field, c);
      expect(reason).toMatch(c.says);
      // Under the field it is about, read as a taken name is, and the other field stays free.
      const line = page.locator(`#coin-${c.field}-check`);
      await expect(line).toHaveText(reason);
      await expect(line).toHaveAttribute("data-status", "taken");
      await expect(page.locator(`#coin-${c.field === "name" ? "symbol" : "name"}-check`)).toHaveText("Free");
      // Sending the form says the same sentence beside the action, and nothing is prepared or asked of the wallet.
      await signButton(page).click();
      await expect(formAlert(page)).toHaveText(reason);
    }
    expect(prepares).toBe(0);
    expect(wallet.requests).toHaveLength(0);
    await expectNoHorizontalOverflow(page);
  });

  // ------------------------------------------------------------------------------------------------ the new screens
  // Each at the four looks a baseline is kept in. The flows run at the first; what is new is shot at each, as
  // `liquidityLaunch.spec.ts` shoots its own. Nothing here launches or trades through the page, so no shot depends on
  // another, and every figure shown follows from a Listing or from a pool nobody else trades in.

  test("the launch form on the chain at every look: filled, its summary as the review, and the signing panel for the permit", async ({ page, context, baseURL }) => {
    test.setTimeout(420_000);
    const wallet = await installEvmWallet(page, await fundedEvmKey({ stock: STOCK_FUNDS }));
    for (const [i, look] of LOOKS.entries()) {
      await setLook(page, context, baseURL, look);
      await openLaunchForm(page);
      // Connected once: on every later load the site returns to the wallet it remembers, without asking.
      if (i === 0) await connectOnPage(page);
      await expect(signButton(page)).toBeVisible();
      await fillForm(page, { name: "Quench Tank", symbol: "QNCH", description: "A coin for the shots: filled in and never launched.", website: "https://example.com/quench" });
      await pairChoice(page).getByRole("radio", { name: new RegExp(`^${STOCK.symbol}\\b`) }).check();
      await firstBuyField(page).fill(FIRST_BUY.text);
      const review = summary(page);
      await expect(fact(review, "You get")).toHaveAttribute("data-coins-out", /^[1-9]\d*$/);
      await expect(fact(review, "Launch cost")).toHaveText(/^About /);
      await copyCheckSettled(page);
      await expect(page.getByRole("region", { name: "Preview" }).locator(".price")).toBeVisible();
      await settled(page);
      await expectNoTruncatedText(page);
      await expect(page).toHaveScreenshot(`evm-launch-filled-${look.name}.png`, { fullPage: true, mask: [...moving(page), ...launchMoving(page)] });
      await expect(review).toHaveScreenshot(`evm-launch-summary-${look.name}.png`, { mask: launchMoving(page) });

      // The first of the two asks: the permit, held at the wallet so the panel stands, then declined so nothing launches.
      const held = wallet.holdNext();
      await signButton(page).click();
      await expect(signing(page)).toContainText(`Confirm in ${TEST_EVM_WALLET_NAME}`);
      await expect(signing(page)).toContainText(`Step 1 of 2: a permit for your first buy of ${FIRST_BUY.text} ${STOCK.symbol}. It is a signature and costs no gas. The launch itself follows.`);
      await page.mouse.move(0, 0);
      await expect(review).toHaveScreenshot(`evm-launch-signing-permit-${look.name}.png`, { mask: launchMoving(page) });
      wallet.declineNext();
      held.release();
      await expect(formAlert(page)).toHaveText("You declined the request in your wallet. Nothing was launched.");
    }
    expect(methods(wallet)).toEqual(LOOKS.map(() => "eth_signTypedData_v4"));
    expect(wallet.sent).toHaveLength(0);
    await page.setViewportSize(LOOKS[0].viewport);
  });

  test("the trade panel of a coin on the chain at every look: a quote after the Opening Fee's window, and its review", async ({ page, context, baseURL }) => {
    test.setTimeout(420_000);
    const trader = await fundedEvmKey({ stock: STOCK_FUNDS });
    const launched = await launchEvmViaApi(trader, { name: "Tinder Box", symbol: "TNDR", quote: STOCK.address });
    await afterOpeningFee(launched.launchedAt);
    const wallet = await installEvmWallet(page, trader);
    for (const [i, look] of LOOKS.entries()) {
      await setLook(page, context, baseURL, look);
      await page.goto(`/coin/${launched.coin}`);
      const panel = tradePanel(page);
      if (i === 0) await connectEvmTestWallet(page, panel.getByRole("button", { name: "Connect wallet" }));
      await expect(panel.getByRole("button", { name: "Review buy" })).toBeVisible();
      await expect(panel.getByText(/^Balance/)).toHaveText(`Balance ${units(STOCK_FUNDS, STOCK.decimals, 4)} ${STOCK.symbol}`);
      await panel.getByLabel("You pay").fill("0.01");
      await expect(panel.getByText("You get about")).toBeVisible();
      await expect(panel.locator('[data-fee="Opening Fee"]')).toHaveCount(0);
      await settled(page);
      await expect(panel).toHaveScreenshot(`evm-trade-quote-${look.name}.png`, { mask: [statement(panel).getByRole("link")] });

      await panel.getByRole("button", { name: "Review buy" }).click();
      await expect(panel.getByRole("region", { name: "Review your trade" })).toContainText("Your wallet is asked three times");
      await page.mouse.move(0, 0);
      await expect(panel).toHaveScreenshot(`evm-trade-review-${look.name}.png`, { mask: [statement(panel).getByRole("link")] });
      await panel.getByRole("button", { name: "Edit" }).click();
    }
    expect(wallet.requests).toHaveLength(0);
    await page.setViewportSize(LOOKS[0].viewport);
  });

  test("the trade panel inside the Opening Fee's window at every look, with one answer of the chain held for them all", async ({ page, context, baseURL }) => {
    test.setTimeout(420_000);
    // The fork is left exactly ten seconds into the window's twenty, where it stands until something is sent, so the
    // quote read there is the same on every run; its first answer is then kept for every look.
    const SECOND = 10;
    const launched = await launchEvmViaApi(await fundedEvmKey(), { name: "Furnace Door", symbol: "FDOR", atSecond: SECOND });
    let kept: { at: string; feeBps: { opening: number; platform: number } } | null = null;
    await page.route(new RegExp(`/v1/launches/${launched.coin}/quote\\?`, "i"), async (route) => {
      const response = await route.fetch();
      if (!response.ok()) return route.fulfill({ response });
      kept ??= (await response.json()) as typeof kept;
      await route.fulfill({ response, json: kept });
    });
    for (const look of LOOKS) {
      await setLook(page, context, baseURL, look);
      await page.goto(`/coin/${launched.coin}`);
      await expectHydrated(page);
      const panel = tradePanel(page);
      await panel.getByLabel("You pay").fill("0.01");
      await expect(panel.locator('[data-fee="Opening Fee"] dt')).toHaveText("Opening Fee, into FDOR's own liquidity");
      await expect(panel.locator("[data-opening-fee]")).toContainText("The Opening Fee is running.");
      await settled(page);
      await expect(panel).toHaveScreenshot(`evm-trade-opening-${look.name}.png`, { mask: [statement(panel).getByRole("link"), panel.locator("[data-opening-fee] time")] });
    }
    // The answer shown was the chain's own at that second: half of the window gone, so half of the Opening Fee left.
    expect(Date.parse(kept!.at) / 1000 - Number(launched.launchedAt)).toBe(SECOND);
    expect(kept!.feeBps).toMatchObject({ platform: 100, opening: 4900 });
    await page.setViewportSize(LOOKS[0].viewport);
  });

  test("the switch a wallet on another network is shown at every look, in the launch summary and in the trade panel", async ({ page, context, baseURL }) => {
    test.setTimeout(420_000);
    const launched = await launchEvmViaApi(await fundedEvmKey(), { name: "Cold Flue", symbol: "CFLU" });
    const wallet = await installEvmWallet(page, await fundedEvmKey(), { startChainId: 1 });
    for (const [i, look] of LOOKS.entries()) {
      await setLook(page, context, baseURL, look);
      await openLaunchForm(page);
      if (i === 0) await connectOnPage(page);
      await expect(network(summary(page)).getByRole("button", { name: SWITCH })).toBeVisible();
      await fillForm(page, { name: "Side Draft", symbol: "SDFT" });
      await expect(fact(summary(page), "Launch cost")).toHaveText(/^About /);
      await copyCheckSettled(page);
      await expect(page.getByRole("region", { name: "Preview" }).locator(".price")).toBeVisible();
      await settled(page);
      await expect(summary(page)).toHaveScreenshot(`evm-launch-wrong-network-${look.name}.png`, { mask: launchMoving(page) });

      await page.goto(`/coin/${launched.coin}`);
      const panel = tradePanel(page);
      await expect(network(panel).getByRole("button", { name: SWITCH })).toBeVisible();
      await settled(page);
      await expect(panel).toHaveScreenshot(`evm-trade-wrong-network-${look.name}.png`, { mask: [statement(panel).getByRole("link")] });
    }
    expect(wallet.requests).toHaveLength(0);
    expect(wallet.chainId()).toBe(1);
    await page.setViewportSize(LOOKS[0].viewport);
  });

  test("the account menu with a Solana wallet and an EVM wallet connected, at every look", async ({ page, context, baseURL, wallet }) => {
    test.setTimeout(300_000);
    const evm = await installEvmWallet(page, await fundedEvmKey());
    for (const [i, look] of LOOKS.entries()) {
      await setLook(page, context, baseURL, look);
      // A page of words alone, so nothing behind the menu moves.
      await page.goto("/terms");
      await expectHydrated(page);
      const area = await accountArea(page);
      const menu = area.getByRole("menu", { name: "Wallets" });
      // A press that lands before the page has hydrated does nothing, so the menu is asked for until it is open.
      const open = (button: Locator) =>
        expect(async () => {
          if (!(await menu.isVisible())) await button.click();
          await expect(menu).toBeVisible({ timeout: 1_000 });
        }).toPass({ timeout: 30_000 });
      if (i === 0) {
        // One control, one menu: each chain family under its own name, with the wallets to connect there.
        await open(area.getByRole("button", { name: "Connect wallet" }));
        await expect(menu.getByRole("group", { name: "Solana" }).getByRole("menuitem", { name: TEST_WALLET_NAME })).toBeVisible();
        await menu.getByRole("group", { name: CHAIN_NAME }).getByRole("menuitem", { name: TEST_EVM_WALLET_NAME }).click();
        await open(area.getByRole("button", { name: /^0x/i }));
        await menu.getByRole("group", { name: "Solana" }).getByRole("menuitem", { name: TEST_WALLET_NAME }).click();
      }
      const account = area.getByRole("button", { name: "2 wallets" });
      await open(account);
      await expect(menu.getByRole("group", { name: "Solana" }).getByRole("menuitem", { name: "Disconnect the Solana wallet" })).toBeVisible();
      await expect(menu.getByRole("group", { name: CHAIN_NAME }).getByRole("menuitem", { name: `Disconnect the ${CHAIN_NAME} wallet` })).toBeVisible();
      await settled(page);
      await expectNoHorizontalOverflow(page);
      // On a phone the menu opens in the account sheet's own flow, so the sheet is the shot: the wallets, then its
      // links. On a desktop it floats under the header's button, and is shot alone.
      await expect(look.viewport.width < 768 ? area : menu).toHaveScreenshot(`evm-account-menu-${look.name}.png`, { mask: moving(page) });
      await page.keyboard.press("Escape");
    }
    expect(evm.requests).toHaveLength(0);
    expect(wallet.requests).toHaveLength(0);
    await page.setViewportSize(LOOKS[0].viewport);
  });
});

test("without the preview cookie the site is Solana's alone: no Chain section, no EVM coin on the board, and no page for one", async ({ page, context, baseURL }) => {
  test.setTimeout(180_000);
  const launched = await launchEvmViaApi(await fundedEvmKey(), { name: "Hidden Ember", symbol: "HDNE" });
  expect((await launchOf(launched.coin)).chain).toBe("robinhood");

  await page.goto("/launch");
  await expect(page.getByRole("heading", { name: "Stoke a coin" })).toBeVisible();
  await expect(page.getByRole("region", { name: "Your coin" })).toBeVisible();
  await expect(chainChoice(page)).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Chain", exact: true })).toHaveCount(0);
  await expect(page.getByRole("main")).not.toContainText(CHAIN_NAME);

  // The board: a search for the coin's own name finds nothing, and newest first, where it would lead, it is not listed.
  await page.goto("/coins?q=Hidden+Ember");
  await expect(page.getByRole("heading", { name: "Coins", exact: true })).toBeVisible();
  await expect(page.getByRole("main")).toContainText('No coins match "Hidden Ember".');
  await expect(page.locator(`a[href="/coin/${launched.coin}"]`)).toHaveCount(0);
  await page.goto("/coins?sort=new");
  await expect(page.getByRole("searchbox", { name: "Search coins" })).toBeVisible();
  await page.waitForLoadState("networkidle", { timeout: 20_000 }).catch(() => undefined);
  await expect(page.locator(`a[href="/coin/${launched.coin}"]`)).toHaveCount(0);
  await expect(page.getByRole("main")).not.toContainText("Hidden Ember");
  const res = await page.goto(`/coin/${launched.coin}`);
  expect(res?.status()).toBe(404);

  // The same browser with the cookie is shown all three.
  await showPreviewChains(context, baseURL);
  await page.goto("/launch");
  await expect(chainChoice(page).getByRole("radio", { name: CHAIN_NAME, exact: true })).toBeVisible();
  await page.goto("/coins?q=Hidden+Ember");
  await expect(page.locator(`a[href="/coin/${launched.coin}"]`).first()).toBeVisible();
  expect((await page.goto(`/coin/${launched.coin}`))?.status()).toBe(200);
  await expect(page.getByRole("heading", { level: 1 })).toContainText("HDNE");
});
