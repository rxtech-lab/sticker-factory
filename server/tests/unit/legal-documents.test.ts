import { describe, expect, it } from "vitest";
import { GET as getPrivacy } from "@/app/api/v1/legal/privacy/route";
import { GET as getTerms } from "@/app/api/v1/legal/terms/route";
import { privacyPolicyMarkdown, termsOfServiceMarkdown } from "@/lib/legal/documents";

describe("public legal documents", () => {
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
