import { Hono } from "hono";
import type { AppEnv } from "../env";

/**
 * Trading on an EVM chain (#253): a wallet's balances. A coin's quote and a trade's prepare are the existing paths
 * (`GET /v1/launches/:coin/quote`, `POST /v1/trades/prepare`) in `src/routes/trades.ts`, which hand an EVM coin to this
 * folder's `quoteEvmTrade` and `prepareEvmTrade`.
 */
export const evmTradeRoutes = new Hono<AppEnv>();
