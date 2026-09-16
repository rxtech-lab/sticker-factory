import { notFound, redirect } from "next/navigation";
import { chapters, chapterByID, tutorialLocale } from "@/lib/tutorial/catalog";
import { tutorialContent } from "@/lib/tutorial/content";
import { TutorialReader } from "@/components/tutorial/tutorial-reader";
import "@/components/tutorial/tutorial.css";
export const metadata = { title: "Tutorials · Winky", description: "Learn to create, animate and share your stickers, one step at a time." };
export default async function Page({ params, searchParams }: { params: Promise<{ locale: string; chapter?: string[] }>; searchParams: Promise<{ step?: string }> }) {
  const { locale: requested, chapter: path = [] } = await params;
  const { step } = await searchParams;
  const locale = tutorialLocale(requested);
  if (path.length > 1) notFound();
  const chapter = path[0] ? chapterByID(path[0]) : undefined;
  if (path[0] && !chapter) notFound();
  if (requested !== locale) redirect(`/tutorial/${locale}${chapter ? `/${chapter.id}` : ""}${step ? `?step=${encodeURIComponent(step)}` : ""}`);
  const Content = chapter ? (await tutorialContent[`${locale}/${chapter.id}`]()).default : undefined;
  return <TutorialReader key={`${locale}/${chapter?.id ?? "index"}/${step ?? ""}`} locale={locale} chapter={chapter} chapters={chapters} initialStep={step}>{Content && <Content />}</TutorialReader>;
}
