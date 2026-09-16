"use client";
import { createContext, useContext, useEffect, useMemo, useState, useSyncExternalStore, type ReactNode } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { chapterURL, cleanProgress, tutorialLocales, type TutorialChapter, type TutorialLocale, type TutorialProgress } from "@/lib/tutorial/catalog";
import { strings } from "@/lib/tutorial/strings";

declare global { interface Window {
  __winkyTutorialProgress?: TutorialProgress;
} }
const subscribeHydration = () => () => {};
const storageKey = "winky.tutorial.progress.v1";
const TutorialContext = createContext({ locale: "en" as TutorialLocale, step: "", index: 0 });
function savedProgress(): TutorialProgress {
  try { return cleanProgress(window.__winkyTutorialProgress ?? JSON.parse(localStorage.getItem(storageKey) ?? "{}")); } catch { return cleanProgress(null); }
}
export function TutorialReader({ locale, chapter, chapters, initialStep, children }: {
  locale: TutorialLocale; chapter?: TutorialChapter; chapters: TutorialChapter[]; initialStep?: string; children?: ReactNode;
}) {
  const t = strings[locale];
  const router = useRouter();
  const ready = useSyncExternalStore(subscribeHydration, () => true, () => false);
  const [revision, setRevision] = useState(0);
  const [chosenStep, setChosenStep] = useState<string>();
  const progress = useMemo(() => {
    void revision;
    return ready ? savedProgress() : cleanProgress(null);
  }, [ready, revision]);
  const step = chosenStep ?? (chapter?.steps.includes(initialStep ?? "") ? initialStep! : progress.steps[chapter?.id ?? ""] ?? chapter?.steps[0] ?? "");
  useEffect(() => { document.documentElement.lang = locale; }, [locale]);
  useEffect(() => {
    if (!ready || !chapter) return;
    const saved = savedProgress();
    const updated = { ...saved, lastChapter: chapter.id, lastStep: step, steps: { ...saved.steps, [chapter.id]: step } };
    persist(updated);
  }, [ready, chapter, step]);
  function persist(value: TutorialProgress) {
    window.__winkyTutorialProgress = value;
    try { localStorage.setItem(storageKey, JSON.stringify(value)); } catch { /* Reading works with storage disabled. */ }
  }
  const index = chapter?.steps.indexOf(step) ?? 0;
  const isLast = !!chapter && index === chapter.steps.length - 1;
  const nextChapter = chapter ? chapters[chapters.findIndex(item => item.id === chapter.id) + 1] : undefined;
  function go(next: string) {
    setChosenStep(next);
    history.replaceState(null, "", chapterURL(locale, chapter!.id, next));
    requestAnimationFrame(() => document.querySelector<HTMLElement>(`[data-step="${next}"] h2`)?.focus());
    window.scrollTo({ top: 0, behavior: "instant" });
  }
  function finish() {
    if (!chapter) return;
    const saved = savedProgress();
    const updated = { ...saved, completed: [...new Set([...saved.completed, chapter.id])] };
    persist(updated); setRevision(value => value + 1);
  }
  const finished = !!chapter && progress.completed.includes(chapter.id);
  return <TutorialContext.Provider value={{ locale, step, index }}><main className="tutorial-shell" lang={locale}>
    <header className="tutorial-header"><Link href={`/tutorial/${locale}`} className="tutorial-brand">✦ Winky</Link>
      <label className="tutorial-language"><span className="tutorial-sr-only">{t.language}</span><select value={locale} onChange={e => { router.push(`/tutorial/${e.target.value}${chapter ? `/${chapter.id}?step=${step}` : ""}`); }}>
        {tutorialLocales.map(value => <option key={value} value={value}>{{ en: "English", "zh-CN": "简体中文", "zh-HK": "繁體中文" }[value]}</option>)}
      </select></label></header>
    {chapter ? <>
      <Link className="tutorial-back" href={`/tutorial/${locale}`}>← {t.index}</Link>
      <p className="tutorial-eyebrow">{t[chapter.section]} · {t.step} {index + 1} {t.of} {chapter.steps.length}</p>
      <h1>{chapter.titles[locale]}</h1>
      <progress aria-label={chapter.titles[locale]} value={index + 1} max={chapter.steps.length} />
      <div className="tutorial-steps">{children}</div>
      <TutorialActionLink action={chapter.stepActions?.[step] ?? chapter.action} />
      <nav className="tutorial-step-nav" aria-label={t.title}>
        <button disabled={index <= 0} onClick={() => go(chapter.steps[index - 1])}>← {t.back}</button>
        {isLast ? <button className="tutorial-primary" onClick={finish}>{finished ? `✓ ${t.completed}` : t.done}</button> : <button className="tutorial-primary" onClick={() => go(chapter.steps[index + 1])}>{t.next} →</button>}
      </nav>
      {finished && <div className="tutorial-finished" role="status"><p>✦ {t.completed}</p>{nextChapter ? <Link href={chapterURL(locale, nextChapter.id)}>{t.nextChapter}: {nextChapter.titles[locale]} →</Link> : <Link href={`/tutorial/${locale}`}>{t.index} →</Link>}</div>}
    </> : <>
      <p className="tutorial-eyebrow">WINKY STICKER FACTORY</p><h1>{t.title}</h1><p className="tutorial-intro">{t.intro}</p>
      {progress.lastChapter && <Link className="tutorial-continue" href={chapterURL(locale, progress.lastChapter, progress.lastStep)}>{t.resume} →</Link>}
      {(["create", "finish", "packs"] as const).map(section => <section className="tutorial-section" key={section}><h2>{t[section]}</h2><div className="tutorial-chapters">{chapters.filter(item => item.section === section).map(item => <Link className="tutorial-chapter" href={chapterURL(locale, item.id, progress.steps[item.id])} key={item.id}>
        <span className="tutorial-chapter-icon" aria-hidden="true">{item.section === "create" ? "✦" : item.section === "finish" ? "✓" : "▦"}</span><span><strong>{item.titles[locale]}</strong><small>{progress.completed.includes(item.id) ? `✓ ${t.completed}` : t.read}</small></span><span aria-hidden="true">→</span>
      </Link>)}</div></section>)}
    </>}
  </main></TutorialContext.Provider>;
}
export function TutorialStep({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  const { step } = useContext(TutorialContext);
  return <section hidden={id !== step} data-step={id} className="tutorial-step"><h2 tabIndex={-1}>{title}</h2>{children}</section>;
}
const animatedMedia = new Set(["create-animated", "controls", "new-pack", "whatsapp", "telegram"]);
export function TutorialMedia({ id, caption }: { id: string; caption: string }) {
  const { locale, index } = useContext(TutorialContext);
  const t = strings[locale];
  const [playing, setPlaying] = useState(false);
  const [failed, setFailed] = useState(false);
  const [retry, setRetry] = useState(0);
  const [reduceMotion, setReduceMotion] = useState(false);
  useEffect(() => {
    const media = matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => { setReduceMotion(media.matches); if (media.matches) setPlaying(false); };
    update(); media.addEventListener("change", update); return () => media.removeEventListener("change", update);
  }, []);
  const base = `/tutorial/media/${locale}/${id}`;
  return <figure className="tutorial-media"><span className="tutorial-number" aria-hidden="true">{index + 1}</span><span className="tutorial-spark" aria-hidden="true">✦</span>
    {failed ? <div className="tutorial-media-error"><p>{t.mediaError}</p><button onClick={() => { setFailed(false); setRetry(retry + 1); }}>{t.retry}</button></div> :
      /* Real simulator pixels remain unmodified; the frame and markers are separate layers. */
      // eslint-disable-next-line @next/next/no-img-element
      <img key={`${playing}-${retry}`} src={`${base}${playing && !reduceMotion ? ".animated" : ""}.webp?v=1&r=${retry}`} alt={caption} loading="lazy" width={402} height={874} onError={() => setFailed(true)} />}
    <figcaption><span aria-hidden="true">↖ </span>{caption}</figcaption>
    {animatedMedia.has(id) && !failed && !reduceMotion && <button className="tutorial-play" aria-pressed={playing} onClick={() => setPlaying(!playing)}>{playing ? `Ⅱ ${t.pause}` : `▶ ${t.play}`}</button>}
  </figure>;
}
export function TutorialCallout({ children }: { children: ReactNode }) {
  const { locale } = useContext(TutorialContext);
  return <aside className="tutorial-callout"><strong>✦ {strings[locale].tip}</strong>{children}</aside>;
}
export function TutorialActionLink({ action }: { action: string }) {
  const { locale } = useContext(TutorialContext); const t = strings[locale];
  return <aside className="tutorial-action"><a href={`stickerfactory://open/${action}`}>{t.tryIt} ↗</a><small>{t.appHint}</small></aside>;
}
