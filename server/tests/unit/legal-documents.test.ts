import { describe, expect, it } from "vitest";
import { GET as getPrivacy } from "@/app/api/v1/legal/privacy/route";
import { GET as getTerms } from "@/app/api/v1/legal/terms/route";
import { GET as getPrivacyPage } from "@/app/privacy/route";
import { privacyPolicyMarkdown, termsOfServiceMarkdown } from "@/lib/legal/documents";

describe("public legal documents", () => {
  it("renders the complete shared privacy policy as browser-readable HTML", async () => {
    const response = getPrivacyPage();
    const html = await response.text();

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(html).toContain("<h1>Privacy Policy</h1>");
    expect(html).toContain("<li><strong>Account information.</strong>");
    const visibleText = html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");
    for (const block of privacyPolicyMarkdown.trim().split(/\n\s*\n/)) {
      const text = block.replace(/^#{1,2} /, "").replace(/^- /gm, "").replace(/\*/g, "").replace(/\s+/g, " ");
      expect(visibleText).toContain(text);
    }
  });

  it.each([
    ["privacy", getPrivacy, privacyPolicyMarkdown, "# Privacy Policy"],
    ["terms", getTerms, termsOfServiceMarkdown, "# Terms of Service"],
  ])("serves %s as cacheable Markdown", async (_name, handler, expected, heading) => {
    const response = handler();

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/markdown; charset=utf-8");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(response.headers.get("cache-control")).toContain("stale-while-revalidate");
    expect(await response.text()).toBe(expected);
    expect(expected).toContain(heading);
  });
});
