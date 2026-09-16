import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    "app/.well-known/workflow/**",
    // Build and tooling output that is git-ignored but still on disk locally.
    ".next-e2e/**",
    ".next-tutorial/**",
    ".swc/**",
    "coverage/**",
    "playwright-report/**",
    "test-results/**",
  ]),
  {
    // The same structural cap the iOS side enforces with SwiftLint's `file_length`: no source
    // file over 800 lines, counting neither blank lines nor comments.
    rules: {
      "max-lines": ["error", { max: 800, skipBlankLines: true, skipComments: true }],
    },
  },
]);

export default eslintConfig;
