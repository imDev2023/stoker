import { eq, type Column } from "drizzle-orm";
import type { Context } from "hono";
import { HTTPException } from "hono/http-exception";
import { Chain } from "@launchpad/contract";

/**
 * The `?chain=` every list endpoint takes (#252): only that chain's items, or every chain's when absent. An unknown
 * chain is a 400 that names the known ones, never an empty list.
 */
export function chainFilter(c: Context): Chain | undefined {
  const value = c.req.query("chain");
  if (value === undefined) return undefined;
  const parsed = Chain.safeParse(value);
  if (!parsed.success) throw new HTTPException(400, { message: `chain must be one of ${Chain.options.join(", ")}` });
  return parsed.data;
}

/** The condition a query adds for a chain filter: none without one. */
export const chainIs = (column: Column, chain: Chain | undefined) => (chain === undefined ? undefined : eq(column, chain));
