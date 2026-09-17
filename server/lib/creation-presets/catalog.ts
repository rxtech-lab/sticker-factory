import { creationPreview } from "./previews";
import { CreationPresetCatalogSchema, type PresetText } from "@/lib/contracts/creation-presets";

const text = (en: string, simplified: string, traditional: string): PresetText => ({ en, "zh-Hans": simplified, "zh-Hant": traditional });
export const SHARED_PRESET_PROMPT = "Preserve the user's subject and reference identity. Keep the result readable at sticker size with a clean transparent silhouette. Add lettering only when requested. Combine selected themes coherently without crowding the subject. Presets are creative guidance: retain the approved artwork when building or editing it; do not redesign approved parts to reapply a preset.";
const option = (id: string, title: PresetText, prompt: string) => ({ id, title, prompt, cover: `/images/creation/v3/${id}/cover.webp`, preview: creationPreview(id) });

// Bump the version whenever titles, prompts, requirements, or options change. Existing projects
// use their saved snapshot, so editing this catalog only affects future creations.
export const creationPresetCatalog = CreationPresetCatalogSchema.parse({
  version: "2026-09-17.1",
  groups: [{
    id: "style", type: "single_choice", title: text("Style", "风格", "風格"),
    description: text("Choose how your sticker is drawn.", "选择贴纸的绘画风格。", "選擇貼圖的繪畫風格。"),
    minSelections: 1, maxSelections: 1,
    options: [
      option("bold-cartoon", text("Bold Cartoon", "活力卡通", "活力卡通"), "Use expressive cartoon proportions, bold clean outlines, saturated colors, simple shading, and a crisp die-cut sticker edge."),
      option("kawaii", text("Kawaii", "可爱萌系", "可愛萌系"), "Use rounded shapes, cute simplified features, soft pastel colors, gentle expressions, and clean outlines."),
      option("clay", text("3D Clay", "立体黏土", "立體黏土"), "Render soft sculpted clay forms with rounded edges, subtle handmade texture, and gentle studio lighting."),
      option("pixel", text("Pixel Art", "像素艺术", "像素藝術"), "Use a consistent pixel grid, crisp stepped edges, a limited palette, and readable retro sprite shading."),
      option("watercolor", text("Watercolor", "水彩", "水彩"), "Use translucent watercolor washes, delicate pigment texture, soft color variation, and a clearly defined silhouette."),
      option("paper-cut", text("Paper Cut", "剪纸", "剪紙"), "Build the subject from layered colored-paper shapes with tactile edges, restrained depth shadows, and bold silhouettes."),
    ],
  }, {
    id: "theme", type: "multiple_choice", title: text("Theme", "主题", "主題"),
    description: text("Add a setting or mood. You can combine two.", "添加情境或氛围，最多可组合两个。", "加入情境或氣氛，最多可組合兩個。"),
    minSelections: 0, maxSelections: 2,
    options: [
      option("everyday", text("Everyday Reactions", "日常心情", "日常心情"), "Emphasize an immediately readable everyday emotion or reaction through expression and gesture, with minimal props."),
      option("cozy", text("Cozy Days", "惬意时光", "愜意時光"), "Add a warm, relaxed everyday atmosphere using comfortable accessories and small cozy details suited to the subject."),
      option("nature", text("Nature", "自然", "自然"), "Add playful botanical or outdoor details such as leaves, flowers, or woodland accessories around the subject."),
      option("space", text("Space", "太空", "太空"), "Add whimsical cosmic details such as stars, planets, or astronaut accessories while keeping the subject recognizable."),
      option("celebration", text("Celebration", "庆祝", "慶祝"), "Add joyful celebratory gestures and restrained party details such as confetti, ribbons, or a party hat."),
      option("fantasy", text("Fantasy", "奇幻", "奇幻"), "Add storybook magic through imaginative accessories, small sparkles, or enchanted details without changing the subject's identity."),
    ],
  }],
});

export function publicCreationPresetCatalog() {
  return { ...creationPresetCatalog, groups: creationPresetCatalog.groups.map((group) => ({
    ...group, options: group.options.map(({ id, title, cover, preview }) => ({ id, title, cover, preview })),
  })) };
}
