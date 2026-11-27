import { cookies } from "next/headers";
import { CHAINS_COOKIE, chainsShown } from "./chains";

/**
 * The chains this visitor is shown, read from their preview cookie on the server (#253): the public list, plus the
 * preview chains for a browser that opened a page with `?chains=preview`. Server components and route handlers only;
 * a client component reads the same list from `useChains()`.
 */
export async function visitorChains() {
  return chainsShown((await cookies()).get(CHAINS_COOKIE)?.value);
}
