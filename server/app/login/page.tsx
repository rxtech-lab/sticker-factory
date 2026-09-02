import { redirect } from "next/navigation";
import { signInAction } from "@/app/actions";
import { isWebAuthConfigured } from "@/lib/auth/web";
import { getHealthyWebSession } from "@/lib/auth/session";

export const metadata = { title: "Sign in" };

export default async function LoginPage() {
  if (await getHealthyWebSession()) redirect("/library");
  return (
    <main className="shell centered-page">
      <section className="auth-card card">
        <div className="brand-mark large" aria-hidden="true">✦</div>
        <div className="eyebrow">Sticker Factory</div>
        <h1>Welcome back</h1>
        <p>Continue with the RxLab-hosted sign-in experience. Your password is never handled by Sticker Factory.</p>
        <form action={signInAction}><button className="pill-button full" type="submit" disabled={!isWebAuthConfigured}>Continue with RxLab</button></form>
        {!isWebAuthConfigured && <p className="setup-note">Web OAuth is not configured in this environment. Add the confidential-client variables from <code>.env.example</code>.</p>}
      </section>
    </main>
  );
}
