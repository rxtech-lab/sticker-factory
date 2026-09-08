import { privacyPolicyMarkdown } from "@/lib/legal/documents";

export const dynamic = "force-static";

// Render the headings, paragraphs, lists, and emphasis used by the shared policy.
function inline(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\*(.+?)\*/g, "<em>$1</em>");
}

export function GET() {
  const content = privacyPolicyMarkdown.trim().split(/\n\s*\n/).map((block) => {
    if (block.startsWith("## ")) return `<h2>${inline(block.slice(3))}</h2>`;
    if (block.startsWith("# ")) return `<h1>${inline(block.slice(2))}</h1>`;
    if (block.startsWith("- ")) {
      return `<ul>${block.split("\n").map((line) => `<li>${inline(line.slice(2))}</li>`).join("")}</ul>`;
    }
    return `<p>${inline(block)}</p>`;
  }).join("\n");

  return new Response(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Privacy Policy | Sticker Factory</title>
  <style>
    :root { color-scheme: light dark; font-family: system-ui, sans-serif; line-height: 1.65; }
    body { margin: 0; }
    main { max-width: 48rem; margin: auto; padding: 2rem 1.25rem 4rem; overflow-wrap: break-word; }
    h1, h2 { line-height: 1.25; }
    h1 { font-size: 2.25rem; }
    h2 { margin-top: 2rem; font-size: 1.35rem; }
    li { margin-block: .75rem; }
  </style>
</head>
<body><main>${content}</main></body>
</html>`, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "content-language": "en",
      "cache-control": "public, max-age=3600, stale-while-revalidate=86400",
      "x-content-type-options": "nosniff",
    },
  });
}
