import { markdownDocumentResponse, termsOfServiceMarkdown } from "@/lib/legal/documents";

export const dynamic = "force-static";

export function GET() {
  return markdownDocumentResponse(termsOfServiceMarkdown);
}
