import createMDX from "@next/mdx";
import type { NextConfig } from "next";
import { withWorkflow } from "workflow/next";

const nextConfig: NextConfig = {
  poweredByHeader: false,
  pageExtensions: ["js", "jsx", "ts", "tsx", "mdx"],
  distDir: process.env.STICKER_FACTORY_TUTORIAL_PREVIEW === "true" ? ".next-tutorial" : process.env.STICKER_FACTORY_E2E === "true" ? ".next-e2e" : ".next",
  allowedDevOrigins: ["127.0.0.1"],
  /**
   * Both database drivers load their own non-JavaScript payload — PGlite a WebAssembly build of
   * Postgres, `ws` a native addon when one is present — so they are required at runtime rather
   * than bundled. PGlite is only reached when `DATABASE_URL` names a `pglite:` database, which in
   * practice means the Playwright run.
   */
  serverExternalPackages: ["@electric-sql/pglite", "@electric-sql/pglite-pgvector", "ws"],
  outputFileTracingIncludes: { "/*": ["./lib/subscription/certificates/*.cer", "./public/images/creation/**/*.webp"] },
};

export default withWorkflow(createMDX()(nextConfig));
