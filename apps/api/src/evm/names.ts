import { LINK_HOSTS, LINK_KINDS, linkHostAllowed, type Chain, type HostedLinkKind, type LaunchRefusal, type LinkKind } from "@launchpad/contract";
import { EVM_CHAINS, isEvmChain } from "@launchpad/evm";
import { looseKey, strictKey } from "../copies/keys";

/**
 * A chain's own rules for a launch's text (#253). Robinhood Chain's terms keep its marks out of a coin's name, ticker,
 * description and links, its brand rules allow no reference to HOOD, and a coin must never pass for a Stock Token
 * (ADR 0028, `docs/evm/research/robinhood-chain.md` section 3). A chain with no rules refuses nothing; Solana has none.
 *
 * A coin's image cannot be checked by a rule: it is handled by a report and a label, as Copy Protection's is.
 */

/** The text a launch form holds; its links by kind, or as the form sends them to a check, one a line. */
export type LaunchText = {
  name?: string | null | undefined;
  symbol?: string | null | undefined;
  description?: string | null | undefined;
  links?: Partial<Record<LinkKind, string | null | undefined>> | string | null | undefined;
};

type Field = LaunchRefusal["field"];

/** What a sentence calls each field. */
const LABELS: Record<Field, string> = {
  name: "A coin's name", symbol: "A ticker", description: "A coin's description", telegram: "A Telegram link", x: "An X link", website: "A website link",
  discord: "A Discord link", tiktok: "A TikTok link", instagram: "An Instagram link", youtube: "A YouTube link",
};

/**
 * Text folded as Copy Protection folds a name (`looseKey`: any case, letters of other scripts that look Latin, digits
 * read as the letters they stand for, nothing but letters and digits left), with where each word began, so a rule can
 * ask for a word's start. Accents and invisible characters end no word.
 */
function fold(text: string): { key: string; starts: Set<number> } {
  let key = "";
  const starts = new Set<number>();
  let atStart = true;
  for (const ch of text) {
    if (/[\p{M}\p{Cf}]/u.test(ch)) continue;
    const folded = looseKey(ch);
    if (!folded) {
      atStart = true;
      continue;
    }
    if (atStart) starts.add(key.length);
    key += folded;
    atStart = false;
  }
  return { key, starts };
}

/** Whether `word` stands in the folded text at the start of a word of the text as written. */
function atWordStart({ key, starts }: ReturnType<typeof fold>, word: string) {
  for (let i = key.indexOf(word); i !== -1; i = key.indexOf(word, i + 1)) if (starts.has(i)) return true;
  return false;
}

/** The links a form holds, each with the kind its host makes it (a link on no kind's host is the website's). */
function linkFields(links: LaunchText["links"]): [LinkKind, string][] {
  if (!links) return [];
  if (typeof links !== "string") return LINK_KINDS.flatMap((kind) => (links[kind] ? [[kind, links[kind]] as [LinkKind, string]] : []));
  const hosted = Object.keys(LINK_HOSTS) as HostedLinkKind[];
  return links
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => [hosted.find((kind) => linkHostAllowed(kind, line)) ?? "website", line]);
}

/**
 * Robinhood Chain's rules. "Robinhood", "Robin Hood" and "Robinhood Chain" all fold to one word, refused wherever it
 * stands, inside a longer word too. "Hood Chain" is refused only where "hood" begins a word, so "Neighborhood Chain"
 * passes; HOOD alone is refused as a ticker and as a whole name, so "HOODIE" and "Childhood" pass.
 */
function robinhoodRules(chainName: string, text: LaunchText, stocks: readonly string[]): LaunchRefusal[] {
  const out: LaunchRefusal[] = [];
  const marks = (field: Field, value: string): string | null => {
    const folded = fold(value);
    if (folded.key.includes("ROBINHOOD"))
      return `${LABELS[field]} can't use the name Robinhood or a spelling that looks like it: ${chainName}'s terms keep its name out of every coin launched there.`;
    if (atWordStart(folded, "HOODCHAIN"))
      return `${LABELS[field]} can't use "Hood Chain": ${chainName}'s terms allow no short form of its name on a coin launched there.`;
    return null;
  };
  const refuse = (field: Field, reason: string | null) => {
    if (reason && !out.some((r) => r.field === field)) out.push({ field, reason });
  };

  const name = text.name?.trim();
  if (name) {
    if (fold(name).key.includes("ROBINHOODTOKEN"))
      refuse("name", `A coin's name can't contain "Robinhood Token": every Stock Token on ${chainName} is named that way, and a coin must never pass for one.`);
    if (looseKey(name) === "HOOD") refuse("name", `A coin on ${chainName} can't be named HOOD alone: the chain's brand rules allow no reference to HOOD.`);
    refuse("name", marks("name", name));
  }
  const symbol = text.symbol?.trim();
  if (symbol) {
    const ticker = strictKey(symbol);
    if (looseKey(symbol) === "HOOD") refuse("symbol", `The ticker HOOD can't be used on ${chainName}: the chain's brand rules allow no reference to HOOD.`);
    if (ticker && stocks.some((s) => strictKey(s) === ticker))
      refuse("symbol", `${ticker} is the ticker of a Stock Token on ${chainName}, which a coin launched there can't take.`);
    refuse("symbol", marks("symbol", symbol));
  }
  if (text.description?.trim()) refuse("description", marks("description", text.description));
  for (const [kind, link] of linkFields(text.links)) refuse(kind, marks(kind, link));
  return out;
}

const RULES: Partial<Record<Chain, (chainName: string, text: LaunchText, stocks: readonly string[]) => LaunchRefusal[]>> = { robinhood: robinhoodRules };

/**
 * What `chain`'s own rules refuse in a launch's text: one refusal a field at most, the most particular rule first, each
 * a sentence for the Creator. `stockSymbols` are the tickers of the Stock Tokens the API knows on the chain. Empty for
 * a chain with no rules.
 */
export function launchRefusals(chain: Chain, text: LaunchText, stockSymbols: readonly string[]): LaunchRefusal[] {
  const rules = RULES[chain];
  if (!rules) return [];
  return rules(isEvmChain(chain) ? EVM_CHAINS[chain].name : chain, text, stockSymbols);
}
