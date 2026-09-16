import { publicCreationPresetCatalog } from "@/lib/creation-presets/catalog";

export function GET() {
  return Response.json(publicCreationPresetCatalog(), { headers: { "cache-control": "public, max-age=0, must-revalidate" } });
}
