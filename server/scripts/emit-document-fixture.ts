/**
 * Emits the canonical sticker-document fixture that both test suites parse.
 *
 * The v1 fixture is the input rather than the source of truth: running it through
 * `StickerDocumentSchema` exercises the real `upcastV1ToV2` path, so the emitted file is exactly
 * what a client receives when it reads a revision stored before v2 existed. Both copies must stay
 * byte-identical — that is the point of a shared fixture.
 *
 *   bun run scripts/emit-document-fixture.ts
 */

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";

const here = dirname(fileURLToPath(import.meta.url));
const legacy = resolve(here, "../fixtures/sticker-document-v1.json");
const upcast = StickerDocumentSchema.parse(JSON.parse(readFileSync(legacy, "utf8")));
const json = `${JSON.stringify(upcast, null, 2)}\n`;

for (const target of [
  resolve(here, "../fixtures/sticker-document-v2.json"),
  resolve(here, "../../StickerGeniOS/StickerGeniOSTests/Fixtures/sticker-document-v2.json"),
]) {
  writeFileSync(target, json);
  console.log(`Wrote ${target}`);
}
