// Only static route segments may leave the app. IDs, handles, tokens, and slugs are masked.
const segments = new Set("api v1 devices app-clip allowance assets download legal terms privacy jobs events cancel creators public packs items publish unpublish install about library sections uploads complete stickers import exports revisions accept reject chat messages retry plans confirm revert messenger-renditions auth login marketplace new edit share ios".split(" "));
export function analyticsPath(path: string): string {
  return path.split(/[?#]/, 1)[0].split("/").map((part) => !part || segments.has(part) ? part : ":id").join("/").slice(0, 100);
}
export function analyticsMethod(method: string): string {
  return /^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$/.test(method) ? method : "OTHER";
}
export function errorCategory(error: unknown): string {
  return error instanceof Error && ["TypeError", "RangeError", "ReferenceError", "SyntaxError", "URIError"].includes(error.name) ? error.name : "Error";
}
