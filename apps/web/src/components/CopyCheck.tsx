"use client";

import { useEffect, useState } from "react";
import type { Chain, CopyCheck, CopyVerdict, LaunchRefusal } from "@launchpad/contract";
import { checkCopy } from "@/lib/api";

export type CopyField = "name" | "symbol" | "image";
/** What a field's mark shows: nothing until the field has a value, then the check's answer. */
export type CopyStatus = "empty" | "pending" | "free" | "taken" | "unchecked";

const DEBOUNCE_MS = 350;

/**
 * Copy Protection (#120, ADR 0012) as the Creator types: each of the name, the ticker and the image is checked against the
 * coins launched here inside their window, and each field wears the verdict beside it (phase 5, #136: no box of empty
 * rows before anything is typed). The API gives the same answer when the form is sent, so nothing here is a surprise at
 * prepare time.
 * A launch on an EVM chain names its `chain` (#253): the window covers every chain, and the chain's own rules for a name,
 * a ticker, a description and a link are checked with it (`refusals`, ADR 0028), so the description and the links (one a
 * line) travel too. The Solana form names none and sends what it always has.
 */
export function useCopyCheck({ name, symbol, image, creator, chain = null, description = "", links = "" }: {
  name: string;
  symbol: string;
  image: File | null;
  creator: string | null;
  chain?: Chain | null;
  description?: string;
  links?: string;
}) {
  // The answer with what it answers for: a verdict is shown only beside the value it was given for, so a changed field
  // reads "Checking" again and never wears the last value's verdict (#222). `check` is null when the check failed.
  const [answer, setAnswer] = useState<{
    check: CopyCheck | null; name: string; symbol: string; image: File | null; creator: string | null; chain: Chain | null; description: string; links: string;
  } | null>(null);
  const result = answer?.check ?? null;
  const [pending, setPending] = useState(false);
  const trimmedName = name.trim();
  const trimmedSymbol = symbol.trim();
  // A chain's rules read the description and the links; without a chain neither is sent, and neither starts a check.
  const text = chain ? description.trim() : "";
  const linkLines = chain ? links : "";
  const asked = { name: trimmedName.length > 0, symbol: trimmedSymbol.length > 0, image: image !== null };
  const anything = asked.name || asked.symbol || asked.image || text.length > 0 || linkLines.length > 0;

  useEffect(() => {
    if (!anything) return setAnswer(null);
    const controller = new AbortController();
    const asking = { name: trimmedName, symbol: trimmedSymbol, image, creator, chain, description: text, links: linkLines };
    const timer = setTimeout(async () => {
      setPending(true);
      try {
        const form = new FormData();
        if (chain) form.set("chain", chain);
        if (creator) form.set("creator", creator);
        if (trimmedName) form.set("name", trimmedName);
        if (trimmedSymbol) form.set("symbol", trimmedSymbol);
        if (text) form.set("description", text);
        if (linkLines) form.set("links", linkLines);
        if (image) form.set("image", image);
        setAnswer({ ...asking, check: await checkCopy(form, controller.signal) });
      } catch {
        // A failed check never blocks the form: prepare checks again and says what it refuses. The fields then say nothing.
        if (!controller.signal.aborted) setAnswer({ ...asking, check: null });
      } finally {
        if (!controller.signal.aborted) setPending(false);
      }
    }, DEBOUNCE_MS);
    return () => {
      clearTimeout(timer);
      controller.abort();
    };
  }, [anything, trimmedName, trimmedSymbol, image, creator, chain, text, linkLines]);

  const field = (f: CopyField) => {
    const current = f === "name" ? trimmedName : f === "symbol" ? trimmedSymbol : image;
    const answered = answer !== null && answer[f] === current && answer.creator === creator && answer.chain === chain;
    // A check that failed leaves the field without a line, as before anything was typed.
    if (asked[f] && answered && answer.check === null) return { status: "empty" as CopyStatus, text: null };
    const verdict = asked[f] && answered ? (result?.[f] ?? null) : null;
    const status: CopyStatus = !asked[f] ? "empty" : !verdict ? "pending" : verdict.status === "taken" ? "taken" : verdict.status === "unchecked" ? "unchecked" : "free";
    return { status, text: asked[f] ? describe(f, verdict) : null };
  };

  // What the chain's own rules refuse, each beside the text it was given for alone: a changed field drops its refusal
  // until the next answer. A link's refusal answers for the links as they all stood.
  const refusals: Partial<Record<LaunchRefusal["field"], string>> = {};
  if (answer !== null && answer.chain === chain) {
    for (const r of result?.refusals ?? []) {
      const current = r.field === "name" ? answer.name === trimmedName : r.field === "symbol" ? answer.symbol === trimmedSymbol : r.field === "description" ? answer.description === text : answer.links === linkLines;
      if (current) refusals[r.field] ??= r.reason;
    }
  }

  return {
    pending,
    /** The window every launch gets, once the API has said; null before the first answer. */
    protectionSeconds: result?.protectionSeconds ?? null,
    name: field("name"),
    symbol: field("symbol"),
    image: field("image"),
    /** By field, the sentence the chain's rules refuse it with; empty on Solana, which has none. */
    refusals,
  };
}

function describe(field: CopyField, verdict: CopyVerdict | null): string {
  if (!verdict) return "Checking";
  if (verdict.status === "free") return field === "image" ? "Not a protected coin's image" : "Free";
  if (verdict.status === "unchecked") return "Can't be read for a copy (PNG or JPEG can)";
  const of = verdict.of!;
  const until = new Date(of.protectedUntil).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
  if (verdict.kind === "near") return `Too close to ${of.symbol} (${of.name}), protected until ${until}`;
  if (field === "image") return `A copy of ${of.symbol}'s image, protected until ${until}`;
  return `Taken by ${of.name} (${of.symbol}) until ${until}`;
}

/** The window as words in its natural unit: "7 days" deployed, "45 seconds" on a test stack, never "0 days". */
export function windowWords(seconds: number): string {
  const unit = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;
  if (seconds >= 86_400 && seconds % 86_400 === 0) return unit(seconds / 86_400, "day");
  if (seconds >= 3_600 && seconds % 3_600 === 0) return unit(seconds / 3_600, "hour");
  if (seconds >= 60 && seconds % 60 === 0) return unit(seconds / 60, "minute");
  if (seconds >= 86_400) return unit(Math.round(seconds / 8_640) / 10, "day");
  return unit(seconds, "second");
}
