import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { compileTutorialDocument } from "../lib/tutorial/compile";
import { tutorialLocales } from "../lib/tutorial/catalog";
const documents = Object.fromEntries(tutorialLocales.map(locale => [locale, compileTutorialDocument(locale, chapter => readFileSync(join(process.cwd(), "content/tutorial", locale, `${chapter}.mdx`), "utf8"))]));
writeFileSync(join(process.cwd(), "lib/tutorial/documents.generated.json"), JSON.stringify(documents, null, 2) + "\n");
console.log("Compiled native tutorials in 3 languages.");
