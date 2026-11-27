import styles from "./UnauditedStatement.module.css";

/**
 * The unaudited statement (ADR 0030, CONTEXT.md): the one sentence the site shows wherever money moves on an EVM chain,
 * in these words exactly, with the chain's name in full and a link to where the contracts' verified source is read. It
 * is plain text beside the action: nothing to tick, and never a dialog. The link is written as its own address, in the
 * mono like every address on the site.
 */
export function UnauditedStatement({ chain, source }: { chain: string; source: string }) {
  return (
    <p className={styles.statement} data-unaudited="">
      {`Stoker's contracts on ${chain} have not been audited by an independent firm. Their source is public and verified: `}
      <a className="mono" href={source} target="_blank" rel="noreferrer">{source.replace(/^https?:\/\//, "")}</a>.
    </p>
  );
}
