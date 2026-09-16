import documents from "@/lib/tutorial/documents.generated.json";
import { tutorialLocale } from "@/lib/tutorial/catalog";

/** Public education content. No auth, account data, cookies or generated app actions. */
export async function GET(_request: Request, { params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const document = documents[tutorialLocale(locale)];
  return Response.json(document, { headers: { "Cache-Control": "public, max-age=300, s-maxage=3600, stale-while-revalidate=86400", "X-Content-Type-Options": "nosniff" } });
}
