import { Hono } from "hono";
import { HTTPException } from "hono/http-exception";
import { CopyCheckFields, familyOf, LAUNCH_IMAGE_MAX_BYTES, LAUNCH_IMAGE_TYPES, type CopyCheck } from "@launchpad/contract";
import { canonicalAddress } from "../chains/address";
import { checkCopies } from "../copies/check";
import { imageHash } from "../copies/imageHash";
import type { AppEnv } from "../env";
import { evmContext } from "../evm/context";
import { launchRefusals } from "../evm/names";
import { stockSymbols } from "../evm/options";
import { sniffImageType } from "../images";

/** Copy Protection (#120, ADR 0012): the launch form asks as the Creator types, and gets the verdict a prepare would give. */
export const copyRoutes = new Hono<AppEnv>();

copyRoutes.post("/launches/check", async (c) => {
  const form = await c.req.formData().catch(() => {
    throw new HTTPException(400, { message: "expected multipart/form-data" });
  });
  const fields = CopyCheckFields.safeParse(Object.fromEntries([...form.entries()].filter(([, v]) => typeof v === "string")));
  if (!fields.success) return c.json({ error: "invalid check fields", details: fields.error.issues }, 400);
  const image = form.get("image");
  let hash: string | null | undefined;
  if (image instanceof File && image.size > 0) {
    if (image.size > LAUNCH_IMAGE_MAX_BYTES) return c.json({ error: "image is larger than 2 MB" }, 400);
    const bytes = new Uint8Array(await image.arrayBuffer());
    const contentType = sniffImageType(bytes);
    if (!contentType || !(LAUNCH_IMAGE_TYPES as readonly string[]).includes(contentType)) return c.json({ error: "image must be PNG, JPEG, WebP or GIF" }, 400);
    hash = await imageHash(bytes, contentType);
  }
  const cfg = c.get("cfg");
  const { chain, creator, name, symbol, description, links } = fields.data;
  // The window covers every chain (#253), so the verdicts are the same whichever chain the coin would launch on; a
  // Creator's own coins are theirs under the address the Indexer wrote, whatever case the wallet gave it in.
  const verdicts = await checkCopies(c.get("db"), cfg, { name, symbol, imageHash: hash, creator: creator && canonicalAddress(creator) });
  const body: CopyCheck = { ...verdicts, protectionSeconds: cfg.copyProtectionSeconds };
  // An EVM chain's own rules for the text (ADR 0028), which a prepare there refuses with too; Solana's answer has no such key.
  if (familyOf(chain) === "evm") body.refusals = launchRefusals(chain, { name, symbol, description, links }, await stockSymbols(c.get("db"), evmContext(c, chain)));
  return c.json(body);
});
