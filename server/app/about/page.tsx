import type { Metadata } from "next";
import { aboutCredit, aboutPurpose } from "@/lib/about";

export const metadata: Metadata = {
  title: "About",
  description: "Learn about Sticker Factory, the private AI sticker studio from RxLab.",
};

export default function AboutPage() {
  return (
    <main className="shell about-page">
      <section className="about-hero glass-panel">
        <div className="about-mark" aria-hidden="true">✦</div>
        <div>
          <div className="eyebrow">About Sticker Factory</div>
          <h1>Why we built it.</h1>
          <p>{aboutPurpose}</p>
          <p className="about-credit">{aboutCredit()}</p>
        </div>
      </section>
    </main>
  );
}
