"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { FIRST_LINKS, LINK_INFO, LINK_MAX_LENGTH, MORE_LINKS, withScheme, type LinkKind } from "@/lib/links";
import type { CopyStatus } from "./CopyCheck";
import styles from "./LaunchForm.module.css";

/*
 * The parts of the launch form that are the same on every chain (#253): the coin's own fields and its links, the verdict
 * line under a field, and the summary's two small hooks. The Solana form and an EVM chain's form each keep their own
 * state and their own flow, and draw these.
 */

export const DESCRIPTION_MAX = 1000;

/** What the form holds about the coin itself, whatever chain it launches on: carried over when the Creator changes chain. */
export type LaunchDraft = { name: string; symbol: string; description: string; links: Record<LinkKind, string>; image: File | null };

/** A field's verdict from the copy check: what its mark shows, and the line under it. */
type Verdict = { status: CopyStatus; text: string | null };

/** What a chain's own rules refuse in the form's text (#253, ADR 0028), by field: the sentence shown under it. None on Solana. */
export type FieldRefusals = Partial<Record<"name" | "symbol" | "description" | LinkKind, string>>;

/** A refusal takes the field's line over the copy check's verdict, and reads as a taken name does. */
const withRefusal = (verdict: Verdict, refusal: string | undefined): Verdict => (refusal ? { status: "taken", text: refusal } : verdict);

/** The coin: the image, then the name and the ticker, each checked for a copy as it is typed, and the description. */
export function CoinFields({
  imageUrl, onPickImage, onImageUnreadable, name, onName, symbol, onSymbol, description, onDescription, copy, refusals = {},
}: {
  imageUrl: string | null;
  onPickImage: (file: File | undefined) => void;
  /** A file named as an image that holds none: the form takes it back out, with the reason. */
  onImageUnreadable: () => void;
  name: string;
  onName: (name: string) => void;
  symbol: string;
  onSymbol: (symbol: string) => void;
  description: string;
  onDescription: (description: string) => void;
  copy: { pending: boolean; image: Verdict; name: Verdict; symbol: Verdict };
  refusals?: FieldRefusals;
}) {
  const nameCheck = withRefusal(copy.name, refusals.name);
  const symbolCheck = withRefusal(copy.symbol, refusals.symbol);
  return (
    <section className={styles.set} aria-labelledby="block-coin" aria-busy={copy.pending}>
      <h2 id="block-coin" className={`t-h3 ${styles.legend}`}>Your coin</h2>
      <div className={styles.field}>
        <label className={styles.drop} data-filled={imageUrl ? true : undefined}>
          {imageUrl ? (
            <>
              <img className={styles.dropImage} src={imageUrl} alt="Coin image preview" onError={onImageUnreadable} />
              <span>Change image</span>
            </>
          ) : (
            <span>Add image</span>
          )}
          <input type="file" accept="image/png,image/jpeg,image/webp,image/gif" className="visually-hidden" onChange={(e) => onPickImage(e.target.files?.[0])} />
        </label>
        <CheckLine status={copy.image.status} text={copy.image.text} field="image" />
      </div>
      <div className={styles.two}>
        <CheckedField id="coin-name" label="Name" status={nameCheck.status} text={nameCheck.text} field="name">
          <input id="coin-name" value={name} onChange={(e) => onName(e.target.value)} maxLength={32} required placeholder="Tracer Bullet" autoComplete="off" aria-describedby="coin-name-check" />
        </CheckedField>
        <CheckedField id="coin-symbol" label="Ticker" status={symbolCheck.status} text={symbolCheck.text} field="symbol">
          <input
            id="coin-symbol"
            value={symbol}
            onChange={(e) => onSymbol(e.target.value.toUpperCase().replace(/[^A-Z0-9$]/g, ""))}
            maxLength={10}
            required
            placeholder="TRCR"
            autoComplete="off"
            spellCheck={false}
            aria-describedby="coin-symbol-check"
          />
        </CheckedField>
      </div>
      <div className={styles.field}>
        <label htmlFor="coin-description">Description</label>
        <span className={`input ${styles.area}`}>
          <textarea
            id="coin-description"
            value={description}
            onChange={(e) => onDescription(e.target.value)}
            maxLength={DESCRIPTION_MAX}
            rows={3}
            aria-describedby={refusals.description ? "coin-description-check" : undefined}
          />
        </span>
        {refusals.description && <CheckLine status="taken" text={refusals.description} field="description" id="coin-description-check" />}
      </div>
    </section>
  );
}

/** The coin's links: Telegram and X side by side, the website across both, the rest two by two behind one button. */
export function LinkFields({ links, onLink, more, onMore, refusals = {} }: {
  links: Record<LinkKind, string>;
  onLink: (kind: LinkKind, value: string) => void;
  /** Whether "More links" was pressed; the rest also show once one of them holds an address. */
  more: boolean;
  onMore: () => void;
  refusals?: FieldRefusals;
}) {
  return (
    <section className={styles.set} aria-labelledby="block-links">
      <h2 id="block-links" className={`t-h3 ${styles.legend}`}>Links</h2>
      <div className={styles.two}>
        {FIRST_LINKS.map((k) => (
          <LinkField key={k} kind={k} value={links[k]} onChange={(v) => onLink(k, v)} wide={k === "website"} refusal={refusals[k]} />
        ))}
      </div>
      {more || MORE_LINKS.some((k) => links[k].trim() !== "") ? (
        <div className={styles.two}>
          {MORE_LINKS.map((k) => (
            <LinkField key={k} kind={k} value={links[k]} onChange={(v) => onLink(k, v)} refusal={refusals[k]} />
          ))}
        </div>
      ) : (
        <button type="button" className={`button button-ghost ${styles.more}`} onClick={onMore}>
          More links
        </button>
      )}
    </section>
  );
}

/** One link's field: its name over the address. `wide` spans the grid's row. */
function LinkField({ kind, value, onChange, wide = false, refusal }: { kind: LinkKind; value: string; onChange: (value: string) => void; wide?: boolean; refusal?: string }) {
  const info = LINK_INFO[kind];
  return (
    <div className={`${styles.field} ${wide ? styles.wide : ""}`}>
      <label htmlFor={`coin-${kind}`}>{info.label}</label>
      <span className={`input ${styles.well}`}>
        <input
          id={`coin-${kind}`}
          type="url"
          inputMode="url"
          autoComplete="off"
          spellCheck={false}
          maxLength={LINK_MAX_LENGTH}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          // An address pasted without its scheme ("t.me/name") gets it, where the browser would only say "Please enter a URL."
          onBlur={() => { if (withScheme(value) !== value) onChange(withScheme(value)); }}
          placeholder={info.placeholder}
          aria-describedby={refusal ? `coin-${kind}-check` : undefined}
        />
      </span>
      {refusal && <CheckLine status="taken" text={refusal} field={kind} id={`coin-${kind}-check`} />}
    </div>
  );
}

/** A field with Copy Protection's verdict under it once the field has a value. */
export function CheckedField({ id, label, status, text, field, children }: { id: string; label: string; status: CopyStatus; text: string | null; field: string; children: ReactNode }) {
  return (
    <div className={styles.field} data-check={status}>
      <label htmlFor={id}>{label}</label>
      <span className={`input ${styles.well}`}>{children}</span>
      <CheckLine status={status} text={text} field={field} id={`${id}-check`} />
    </div>
  );
}

/** The verdict's line: "Free", or who holds the name and until when. Nothing until the field has a value. */
export function CheckLine({ status, text, field, id }: { status: CopyStatus; text: string | null; field: string; id?: string }) {
  if (status === "empty" || !text) return null;
  return (
    <p id={id} className={styles.check} data-status={status} data-field={field}>
      {text}
    </p>
  );
}

/**
 * The summary's height as `--side-h` on its column, so the column's sticky offset can keep its foot (the action and the
 * note) in the window when the summary is taller than the window: it then sticks with its foot 24px above the window's
 * bottom instead of its top under the header (LaunchForm.module.css, `.side`).
 */
export function useStickySide() {
  const ref = useRef<HTMLElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => el.style.setProperty("--side-h", `${Math.ceil(el.getBoundingClientRect().height)}px`);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);
  return ref;
}

/** The seconds since something started, for the status line while a launch confirms. */
export function useElapsed(running: boolean) {
  const [seconds, setSeconds] = useState(0);
  useEffect(() => {
    if (!running) {
      setSeconds(0);
      return;
    }
    const started = Date.now();
    const timer = setInterval(() => setSeconds(Math.floor((Date.now() - started) / 1000)), 1000);
    return () => clearInterval(timer);
  }, [running]);
  return seconds;
}
