import Link from "next/link";
import { signOutAction } from "@/app/actions";
import { getHealthyWebSession } from "@/lib/auth/session";

export async function SiteHeader() {
  const session = await getHealthyWebSession();
  return (
    <header className="site-header glass-panel">
      <Link className="brand" href="/" aria-label="Sticker Factory home">
        <span className="brand-mark" aria-hidden="true">✦</span><span>Sticker Factory</span>
      </Link>
      <nav aria-label="Primary navigation">
        {session?.user ? <><Link href="/marketplace">Marketplace</Link><Link href="/library">Library</Link><form action={signOutAction}><button className="text-button" type="submit">Sign out</button></form></> : <Link className="pill-button small" href="/login">Sign in</Link>}
      </nav>
    </header>
  );
}
