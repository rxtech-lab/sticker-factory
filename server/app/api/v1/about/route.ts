import { aboutMarkdown } from "@/lib/about";
import { markdownDocumentResponse } from "@/lib/legal/documents";

export function GET() {
  return markdownDocumentResponse(aboutMarkdown(), "no-store");
}
