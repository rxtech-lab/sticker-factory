import type { Metadata } from "next";
import { APP_STORE_URL } from "@/lib/sharing";

export const metadata: Metadata = {
  title: "A pet came to visit",
  description: "Someone shared their Sticker Factory pet with you.",
  robots: { index: false },
};

/**
 * Where a pet card sent from Messages lands for someone without the extension — a Mac, a browser.
 *
 * Everything shown comes from the card's own query items, the same ones the extension writes in
 * `PetCardPayload`; nothing is looked up, so a card shows what it showed in the bubble. React
 * escapes every value, and numbers are clamped before they reach a width.
 */
export default async function PetCardPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const params = await searchParams;
  const text = (key: string, max: number) => {
    const value = params[key];
    return (Array.isArray(value) ? value[0] : value)?.trim().slice(0, max) || null;
  };
  const number = (key: string, max: number) => Math.max(0, Math.min(max, Number.parseInt(text(key, 8) ?? "", 10) || 0));
  const name = text("name", 80) ?? "A pet";
  const maxHp = Math.max(1, number("maxHp", 200) || 100);
  const stats = [
    { label: "Happiness", value: number("happiness", 100), max: 100 },
    { label: "HP", value: number("hp", maxHp), max: maxHp },
    { label: "Energy", value: number("energy", 100), max: 100 },
  ];
  const kind = [text("class", 32), text("personality", 80)].filter(Boolean).join(" · ");
  const caption = text("caption", 280);
  return <main className="shell"><section className="empty-state glass-panel">
    <div className="eyebrow">Sticker Factory · Pet card</div>
    <h1>{name}</h1>
    {kind && <p>{kind}</p>}
    {caption && <p>“{caption}”</p>}
    <dl style={{ display: "grid", gap: 8, width: "100%", maxWidth: 360 }}>
      {stats.map((stat) => <div key={stat.label}>
        <dt>{stat.label}: {stat.value}{stat.label === "HP" ? ` / ${stat.max}` : ""}</dt>
        <dd style={{ margin: 0, height: 8, borderRadius: 4, background: "rgba(0,0,0,0.1)" }}>
          <div style={{ width: `${(stat.value / stat.max) * 100}%`, height: "100%", borderRadius: 4, background: "currentColor" }} />
        </dd>
      </div>)}
    </dl>
    <a className="pill-button" href={APP_STORE_URL}>Adopt your own pet</a>
  </section></main>;
}
