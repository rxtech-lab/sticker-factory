import Link from "next/link";
import { signOutAction } from "@/app/actions";
import { getHealthyWebSession } from "@/lib/auth/session";

/** A slim bar pinned to the top: brand on the left, mono nav links and one bright action on the right. */
export async function SiteHeader() {
  const session = await getHealthyWebSession();
  return (
    <header className="site-header">
      <Link className="brand" href="/" aria-label="Sticker Factory home">
        <span className="brand-mark" aria-hidden="true">✦</span><span>Sticker Factory</span>
      </Link>
      <nav aria-label="Primary navigation">
        <Link href="/about">About</Link>
        {session?.user ? (
          <>
            <Link href="/marketplace">Marketplace</Link>
            <Link href="/library">Library</Link>
            <form action={signOutAction}><button className="text-button" type="submit">Sign out</button></form>
            <Link className="menu-button" href="/library">Open library</Link>
          </>
        ) : (
          <Link className="menu-button" href="/login">Sign in</Link>
        )}
      </nav>
    </header>
  );
}
