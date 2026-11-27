"use client";

import { useRouter } from "next/navigation";
import { createContext, useContext, useEffect, useMemo, type ReactNode } from "react";
import type { Chain } from "@launchpad/contract";
import { CHAINS_COOKIE, CHAINS_LIVE, CHAINS_PARAM, CHAINS_PREVIEW, PUBLIC_CHAINS } from "@/lib/chains";

const ChainsContext = createContext<readonly Chain[]>(PUBLIC_CHAINS);

/** The chains this visitor is shown, as the root layout read them from the preview cookie (src/lib/chains.ts). */
export function ChainsProvider({ chains, children }: { chains: readonly Chain[]; children: ReactNode }) {
  // One list for as long as it names the same chains: the layout hands over a new array on every server read, and an
  // effect that follows the list (the board's refresh) must not start again for that. The key is the list's whole content.
  const key = chains.join(",");
  const shown = useMemo(() => key.split(",").filter(Boolean) as Chain[], [key]);
  return <ChainsContext.Provider value={shown}>{children}</ChainsContext.Provider>;
}

/** The chains this visitor is shown: what every list a client component asks for names. */
export function useChains() {
  return useContext(ChainsContext);
}

/**
 * `?chains=preview` on any page sets the preview cookie and `?chains=live` clears it (unlisted, as `?theme=` is;
 * src/lib/chains.ts). The cookie is written after hydration, as the scheme's is, and the page is then read again from
 * the server, which draws it with the chains the cookie now names. The layout mounts this only where a preview chain
 * is configured.
 */
export function ChainsOverride() {
  const router = useRouter();
  useEffect(() => {
    const asked = new URLSearchParams(window.location.search).get(CHAINS_PARAM);
    if (asked !== CHAINS_PREVIEW && asked !== CHAINS_LIVE) return;
    const previewing = document.cookie.split("; ").includes(`${CHAINS_COOKIE}=${CHAINS_PREVIEW}`);
    if ((asked === CHAINS_PREVIEW) === previewing) return;
    document.cookie = asked === CHAINS_PREVIEW
      ? `${CHAINS_COOKIE}=${CHAINS_PREVIEW}; path=/; max-age=31536000; samesite=lax`
      : `${CHAINS_COOKIE}=; path=/; max-age=0; samesite=lax`;
    router.refresh();
  }, [router]);
  return null;
}
