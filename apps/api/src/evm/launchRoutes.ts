import { Hono } from "hono";
import type { AppEnv } from "../env";

/**
 * Launching on an EVM chain (#253): what a chain offers a Launch, what a First Buy would buy and the launch would cost,
 * and the report of a sent transaction. The launch's own prepare is `POST /v1/launches/prepare` with `chain`, in
 * `src/index.ts`, which hands an EVM chain's form to `prepareEvmLaunch`.
 */
export const evmLaunchRoutes = new Hono<AppEnv>();
