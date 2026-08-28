import { describe, expect, it } from "vitest";
import { GET } from "@/app/api/v1/about/route";
import { aboutCredit, aboutMarkdown, aboutPurpose } from "@/lib/about";

describe("public about document", () => {
  it("serves fresh Markdown with the creator credit", async () => {
    const response = GET();
    const markdown = await response.text();
    const year = new Date().getUTCFullYear();

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/markdown; charset=utf-8");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(markdown).toBe(aboutMarkdown(year));
    expect(markdown).toContain("# About Sticker Factory");
    expect(markdown).toContain(aboutPurpose);
    expect(markdown).toContain(aboutCredit(year));
  });
});
