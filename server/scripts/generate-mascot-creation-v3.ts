/**
 * Builds the versioned mascot creation catalog from the editable SVG master.
 *
 * Run from server in two deliberate stages:
 *   bun scripts/generate-mascot-creation-v3.ts references
 *   # inspect public/images/creation/v3/review/references.png
 *   bun scripts/generate-mascot-creation-v3.ts build
 *
 * The second stage refuses to run until all twelve static references exist. It uses the normal
 * sprite compositor and document renderer to export every pose/mood preview.
 */
import { createHash } from "node:crypto";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import sharp, { type OverlayOptions } from "sharp";
import { StickerDocumentSchema, resolveStickerConfiguration, type StickerDocument } from "@/lib/contracts/sticker";
import { publicCreationPresetCatalog } from "@/lib/creation-presets/catalog";
import { frameFragment, IdFactory, type RenderAssets } from "@/lib/render/document-svg";
import { prepareRenditionAssets, animatedRenditionTiming } from "@/lib/render/renditions";

const phase = process.argv[2];
if (!phase || !["references", "build", "package", "app-assets"].includes(phase)) throw new Error("Expected references, build, package, or app-assets");

const root = resolve("public/images/creation/v3");
const bundled = resolve("../StickerGeniOS/StickerGeniOS/Creation/Resources");
const activityAssets = resolve("../StickerGeniOS/StickerGenerationActivity/Assets.xcassets");
const messageIcons = resolve("../StickerGeniOS/StickerMessages/Assets.xcassets/iMessage App Icon.stickersiconset");
const sourceRoot = resolve("../artwork/mascot/source");
const bodyPath = "M790.598 685.078C668.177 792.285 477.345 863.117 346.738 863.117C140.474 863.117 162.024 686.454 162.024 468.854C162.024 368.489 197.649 276.833 256.275 207.203C320.127 153.532 400.987 121.442 488.896 121.442C695.16 121.442 862.62 298.106 862.62 515.706C862.62 576.317 834.963 633.752 790.598 685.078Z";

const poses = [
  { id: "idle", label: "Idle" }, { id: "wave", label: "Greeting Wave" },
  { id: "bounce", label: "Bounce" }, { id: "sway", label: "Sway" },
  { id: "wiggle", label: "Wiggle" }, { id: "hop", label: "Hop" },
  { id: "spin", label: "Partial Turn" }, { id: "dance", label: "Dance" },
] as const;
const moods = [
  { id: "neutral", label: "Neutral" }, { id: "happy", label: "Happy" },
  { id: "surprised", label: "Surprised" },
] as const;
type Pose = typeof poses[number]["id"];
type Mood = typeof moods[number]["id"];

const options = [
  { id: "bold-cartoon", kind: "style", title: "Bold Cartoon" },
  { id: "kawaii", kind: "style", title: "Kawaii" },
  { id: "clay", kind: "style", title: "3D Clay" },
  { id: "pixel", kind: "style", title: "Pixel Art" },
  { id: "watercolor", kind: "style", title: "Watercolor" },
  { id: "paper-cut", kind: "style", title: "Paper Cut" },
  { id: "everyday", kind: "theme", title: "Everyday Reactions" },
  { id: "cozy", kind: "theme", title: "Cozy Days" },
  { id: "nature", kind: "theme", title: "Nature" },
  { id: "space", kind: "theme", title: "Space" },
  { id: "celebration", kind: "theme", title: "Celebration" },
  { id: "fantasy", kind: "theme", title: "Fantasy" },
] as const;
type Option = typeof options[number];

function uuid(label: string): string {
  const hex = createHash("sha256").update(`mascot-v3:${label}`).digest("hex").slice(0, 32).split("");
  hex[12] = "4"; hex[16] = (["8", "9", "a", "b"] as const)[Number.parseInt(hex[16], 16) % 4];
  return `${hex.slice(0, 8).join("")}-${hex.slice(8, 12).join("")}-${hex.slice(12, 16).join("")}-${hex.slice(16, 20).join("")}-${hex.slice(20).join("")}`;
}

const xml = (value: string) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

function optionLook(option: Option): { defs: string; body: string; outline: string; extras: string; pixel: boolean } {
  const common = `<linearGradient id="pink" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#ffd6dc"/><stop offset="1" stop-color="#ffb8c3"/></linearGradient>`;
  if (option.id === "clay") return {
    defs: `${common}<filter id="bodyFx" x="-30%" y="-30%" width="160%" height="170%"><feDropShadow dx="0" dy="22" stdDeviation="18" flood-color="#8d5268" flood-opacity=".28"/><feGaussianBlur in="SourceAlpha" stdDeviation="3" result="b"/><feSpecularLighting in="b" surfaceScale="5" specularConstant=".34" specularExponent="18" lighting-color="#fff"><feDistantLight azimuth="235" elevation="52"/></feSpecularLighting><feComposite in2="SourceAlpha" operator="in"/><feComposite in="SourceGraphic" operator="arithmetic" k1="1" k2="1" k3=".24" k4="0"/></filter>`,
    body: "url(#pink)", outline: "#e99bab", extras: "", pixel: false,
  };
  if (option.id === "watercolor") return {
    defs: `${common}<filter id="bodyFx" x="-15%" y="-15%" width="130%" height="130%"><feTurbulence baseFrequency=".018" numOctaves="3" seed="8" result="n"/><feDisplacementMap in="SourceGraphic" in2="n" scale="9"/><feGaussianBlur stdDeviation=".45"/></filter>`,
    body: "#ffc3ce", outline: "#d9829c", extras: `<g opacity=".22" fill="#fff"><circle cx="330" cy="390" r="82"/><circle cx="600" cy="690" r="115"/></g>`, pixel: false,
  };
  if (option.id === "paper-cut") return {
    defs: `${common}<filter id="bodyFx" x="-25%" y="-25%" width="150%" height="160%"><feDropShadow dx="-10" dy="16" stdDeviation="4" flood-color="#8e5365" flood-opacity=".34"/></filter>`,
    body: "#ffc4ce", outline: "#f18fa7", extras: `<path d="${bodyPath}" fill="none" stroke="#ffe4e8" stroke-width="28" opacity=".8" transform="translate(-18 -15) scale(.98)"/>`, pixel: false,
  };
  if (option.id === "pixel") return {
    defs: common, body: "#ffc2cb", outline: "#bd6b82", extras: `<g fill="#fff" opacity=".5" shape-rendering="crispEdges"><rect x="270" y="245" width="34" height="34"/><rect x="304" y="211" width="34" height="34"/><rect x="760" y="570" width="34" height="34"/></g>`, pixel: true,
  };
  if (option.id === "kawaii") return {
    defs: common, body: "#ffcbd4", outline: "#f09aae", extras: `<g fill="#f58ca8" opacity=".36"><ellipse cx="420" cy="520" rx="46" ry="23"/><ellipse cx="765" cy="455" rx="35" ry="19"/></g>`, pixel: false,
  };
  if (option.id === "cozy") return {
    defs: common, body: "#ffd0c4", outline: "#d98588", extras: "", pixel: false,
  };
  return { defs: common, body: "url(#pink)", outline: "#d96d88", extras: "", pixel: false };
}

function themeExtras(option: Option): string {
  switch (option.id) {
  case "everyday": return `<g fill="#ff7198"><path d="M200 260c-38-44-102 12 0 85 102-73 38-129 0-85Z"/><circle cx="832" cy="690" r="22"/></g>`;
  case "cozy": return `<path d="M210 670Q470 820 780 650" fill="none" stroke="#fff0cf" stroke-width="62" stroke-linecap="round"/><path d="M242 675Q470 790 748 655" fill="none" stroke="#e9b978" stroke-width="13" stroke-dasharray="18 20"/>`;
  case "nature": return `<g fill="#70aa62" stroke="#40763e" stroke-width="8"><ellipse cx="220" cy="265" rx="38" ry="78" transform="rotate(-35 220 265)"/><ellipse cx="820" cy="650" rx="34" ry="72" transform="rotate(42 820 650)"/></g><g fill="#fff3a6"><circle cx="170" cy="560" r="23"/><circle cx="830" cy="240" r="19"/></g>`;
  case "space": return `<g fill="#8b78d9"><ellipse cx="512" cy="560" rx="430" ry="92" fill="none" stroke="#8b78d9" stroke-width="24" transform="rotate(-12 512 560)"/></g><g fill="#fff2a6"><path d="M190 270l12 28 30 3-23 20 7 30-26-16-26 16 7-30-23-20 30-3Z"/><circle cx="840" cy="610" r="21"/></g>`;
  case "celebration": return `<g stroke-width="18" stroke-linecap="round"><path d="M180 300l-40-65M830 280l52-56M165 700l-62 33M845 690l65 30" stroke="#6ec6ff"/><path d="M245 205l-10-65M780 205l12-68" stroke="#ffcf52"/></g><path d="M660 180l110 95-150 18Z" fill="#8d7ae6"/>`;
  case "fantasy": return `<g fill="#ffe978"><path d="M175 330l13 31 33 3-25 22 8 32-29-18-29 18 8-32-25-22 33-3Z"/><path d="M820 600l10 24 26 2-20 17 6 25-22-14-22 14 6-25-20-17 26-2Z"/></g><path d="M570 165l38 55 48-58 34 92-150 4Z" fill="#c7a8ff" stroke="#8060bb" stroke-width="8"/>`;
  default: return "";
  }
}

function motion(pose: Pose, frame: number): { x: number; y: number; sx: number; sy: number; rotate: number; skew: number; gazeX: number; gazeY: number } {
  const wave = [0, 1, .45, -1, -.45, 0][frame];
  const bounce = [0, .55, 1, .55, .15, 0][frame];
  const alternating = [0, 1, -1, 1, -1, 0][frame];
  switch (pose) {
  case "wave": return { x: wave * 13, y: -Math.abs(wave) * 8, sx: 1 - Math.abs(wave) * .03, sy: 1 + Math.abs(wave) * .04, rotate: wave * 7, skew: wave * -5, gazeX: wave * 8, gazeY: -2 };
  case "bounce": return { x: 0, y: -bounce * 82, sx: 1 - bounce * .08, sy: 1 + bounce * .11, rotate: 0, skew: 0, gazeX: 0, gazeY: -bounce * 5 };
  case "sway": return { x: wave * 18, y: Math.abs(wave) * 6, sx: 1, sy: 1, rotate: wave * 8, skew: wave * 2, gazeX: wave * 7, gazeY: 0 };
  case "wiggle": return { x: alternating * 20, y: 0, sx: 1 + Math.abs(alternating) * .04, sy: 1 - Math.abs(alternating) * .035, rotate: alternating * 5, skew: alternating * 8, gazeX: alternating * 5, gazeY: 0 };
  case "hop": return { x: wave * 10, y: -bounce * 112, sx: 1 - bounce * .1, sy: 1 + bounce * .13, rotate: wave * 4, skew: 0, gazeX: wave * 5, gazeY: -bounce * 6 };
  case "spin": return { x: wave * 12, y: 0, sx: [1, .78, .56, .72, .9, 1][frame], sy: 1 + Math.abs(wave) * .03, rotate: wave * 5, skew: wave * 7, gazeX: wave * 15, gazeY: 0 };
  case "dance": return { x: alternating * 25, y: -Math.abs(alternating) * 28, sx: 1 + Math.abs(alternating) * .05, sy: 1 - Math.abs(alternating) * .04, rotate: alternating * 10, skew: alternating * 4, gazeX: alternating * 9, gazeY: -3 };
  default: return { x: 0, y: [0, 2, -3, -6, -2, 0][frame], sx: 1, sy: [1, .995, 1.01, 1.018, 1.008, 1][frame], rotate: 0, skew: 0, gazeX: 0, gazeY: 0 };
  }
}

function mouth(mood: Mood): string {
  if (mood === "happy") return `<path d="M570 540Q620 608 678 530Q625 654 570 540Z" fill="#7f4052"/><path d="M598 590Q626 608 651 583" fill="none" stroke="#ff9fb0" stroke-width="12" stroke-linecap="round"/>`;
  if (mood === "surprised") return `<ellipse cx="622" cy="558" rx="28" ry="38" fill="#7f4052"/>`;
  return `<path d="M594 552L650 552" fill="none" stroke="#743b4c" stroke-width="14" stroke-linecap="round"/>`;
}

function mascotSvg(option: Option, pose: Pose, mood: Mood, frame: number, size = 512, special?: string): string {
  const look = optionLook(option); const m = motion(pose, frame);
  const blink = special === "cancelled" || ((!special || special === "body") && frame === 3);
  const focused = special === "running";
  const concerned = special === "failed";
  const eyeScale = blink ? .09 : focused ? .72 : mood === "happy" ? .82 : 1;
  const leftEye = mood === "surprised" ? [72, 76] : [67, 70];
  const rightEye = mood === "surprised" ? [54, 57] : [49, 52];
  const gx = m.gazeX + (special === "stale" ? 14 : special === "waiting" ? -10 : 0);
  const gy = m.gazeY + (special === "stale" ? -7 : special === "waiting" ? 5 : 0);
  const group = `translate(${m.x} ${m.y}) rotate(${m.rotate} 512 512) skewX(${m.skew}) translate(${512 * (1 - m.sx)} ${790 * (1 - m.sy)}) scale(${m.sx} ${m.sy})`;
  const extraMouth = special === "body" ? "" : concerned ? `<path d="M585 585Q622 545 662 580" fill="none" stroke="#743b4c" stroke-width="14" stroke-linecap="round"/>` : special === "stale" ? `<path d="M590 558Q620 535 650 555" fill="none" stroke="#743b4c" stroke-width="14" stroke-linecap="round"/>` : mouth(mood);
  const pixels = look.pixel ? ` shape-rendering="crispEdges"` : "";
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 1024 1024"${pixels}><defs>${look.defs}<radialGradient id="eye" cx="36%" cy="28%" r="70%"><stop stop-color="#50515a"/><stop offset=".38" stop-color="#17181d"/><stop offset="1" stop-color="#050507"/></radialGradient></defs>${themeExtras(option)}<g transform="${group}"><g id="body" filter="${["clay", "watercolor", "paper-cut"].includes(option.id) ? "url(#bodyFx)" : "none"}">${look.extras}<path d="${bodyPath}" fill="${look.body}" stroke="${look.outline}" stroke-width="${look.pixel ? 20 : 12}" stroke-linejoin="round"/><path d="M260 250Q390 135 545 150" fill="none" stroke="#fff" stroke-width="23" stroke-linecap="round" opacity=".72"/></g><g id="eyes" transform="translate(${gx} ${gy})"><g transform="translate(496 382) scale(1 ${eyeScale}) translate(-496 -382)"><ellipse cx="496" cy="382" rx="${leftEye[0]}" ry="${leftEye[1]}" fill="url(#eye)" stroke="#23242a" stroke-width="7"/><circle cx="468" cy="353" r="24" fill="#fff"/></g><g transform="translate(758 305) scale(1 ${eyeScale}) translate(-758 -305)"><ellipse cx="758" cy="305" rx="${rightEye[0]}" ry="${rightEye[1]}" fill="url(#eye)" stroke="#23242a" stroke-width="6"/><circle cx="738" cy="284" r="18" fill="#fff"/></g></g><g id="mouth">${extraMouth}</g></g></svg>`;
}

async function reference(option: Option): Promise<Buffer> {
  return sharp(Buffer.from(mascotSvg(option, "idle", "happy", 0, 512))).png().toBuffer();
}

async function contactSheet(items: Array<{ title: string; bytes: Buffer }>, columns: number, tile = 240): Promise<Buffer> {
  const label = 34, rows = Math.ceil(items.length / columns);
  const composite: OverlayOptions[] = [];
  for (const [index, item] of items.entries()) {
    const left = (index % columns) * tile, top = Math.floor(index / columns) * (tile + label);
    composite.push({ input: await sharp(item.bytes).resize(tile, tile, { fit: "contain", background: "#f7f3ea" }).png().toBuffer(), left, top });
    composite.push({ input: Buffer.from(`<svg width="${tile}" height="${label}"><rect width="100%" height="100%" fill="#332718"/><text x="${tile / 2}" y="22" text-anchor="middle" font-family="sans-serif" font-size="14" fill="#fff">${xml(item.title)}</text></svg>`), left, top: top + tile });
  }
  return sharp({ create: { width: columns * tile, height: rows * (tile + label), channels: 4, background: "#f7f3ea" } }).composite(composite).png().toBuffer();
}

async function buildReferences() {
  await mkdir(root, { recursive: true }); await mkdir(resolve(root, "review"), { recursive: true });
  const items: Array<{ title: string; bytes: Buffer }> = [];
  for (const option of options) {
    const directory = resolve(root, option.id); await mkdir(directory, { recursive: true });
    const svg = mascotSvg(option, "idle", "neutral", 0, 1024);
    const bytes = await sharp(Buffer.from(svg)).png().toBuffer();
    await writeFile(resolve(directory, "reference.svg"), svg); await writeFile(resolve(directory, "reference.png"), bytes);
    items.push({ title: option.title, bytes });
  }
  await writeFile(resolve(root, "review/references.png"), await contactSheet(items, 4));
  console.log(`Generated ${items.length} static mascot references. Inspect public/images/creation/v3/review/references.png before build.`);
}

async function frameSheet(option: Option, pose: Pose): Promise<Buffer> {
  const frames = await Promise.all(Array.from({ length: 6 }, (_, frame) => sharp(Buffer.from(mascotSvg(option, pose, "neutral", frame, 512, "body"))).png().toBuffer()));
  return sharp({ create: { width: 1536, height: 1024, channels: 4, background: "#00000000" } })
    .composite(frames.map((input, index) => ({ input, left: (index % 3) * 512, top: Math.floor(index / 3) * 512 }))).png().toBuffer();
}

async function expressionSheet(): Promise<Buffer> {
  const tile = (mood: Mood) => `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512"><g transform="translate(-366 -220)">${mouth(mood)}</g></svg>`;
  const images = await Promise.all(moods.map(({ id }) => sharp(Buffer.from(tile(id))).png().toBuffer()));
  return sharp({ create: { width: 1024, height: 1024, channels: 4, background: "#00000000" } }).composite([
    { input: images[0], left: 0, top: 0 }, { input: images[1], left: 512, top: 0 },
    { input: images[2], left: 0, top: 512 },
  ]).png().toBuffer();
}

function documentFromTemplate(template: StickerDocument, option: Option, assetIds: Map<string, string>, posterId: string, expressionId: string): StickerDocument {
  const document = structuredClone(template);
  if (document.kind !== "animated") throw new Error("Expected animated template");
  const layer = document.layers[0];
  if (!layer || layer.type !== "sprite") throw new Error("Expected sprite template");
  layer.id = "mascot"; layer.name = `Pink mascot — ${option.title}`; layer.clipId = "idle";
  layer.posterAssetId = posterId; layer.expressionId = "neutral";
  layer.clips = poses.map(pose => ({
    id: pose.id, assetId: assetIds.get(pose.id)!, columns: 3, rows: 2,
    faceCompositing: "overlay" as const,
    frames: Array.from({ length: 6 }, () => ({ duration: 1 / 3, faceX: .61, faceY: .48, faceSize: .38 })),
  }));
  layer.expressions = { assetId: expressionId, columns: 2, rows: 2, tiles: [
    { id: "neutral", x: 0, y: 0, width: .5, height: .5 },
    { id: "happy", x: .5, y: 0, width: .5, height: .5 },
    { id: "surprised", x: 0, y: .5, width: .5, height: .5 },
  ] };
  document.configuration = {
    controls: [
      { id: "pose", label: "Pose", type: "choice", defaultValue: "idle", options: poses.map(({ id, label }) => ({ id, label })) },
      { id: "mood", label: "Mood", type: "choice", defaultValue: "neutral", options: moods.map(({ id, label }) => ({ id, label })) },
    ],
    variants: [
      ...poses.map(pose => ({ id: `pose_${pose.id}`, selections: { pose: pose.id }, layers: [{ layerId: "mascot", clip: pose.id }] })),
      ...moods.map(mood => ({ id: `mood_${mood.id}`, selections: { mood: mood.id }, layers: [{ layerId: "mascot", expression: mood.id }] })),
    ],
  };
  return StickerDocumentSchema.parse(document);
}

async function renderPreview(document: StickerDocument, assets: RenderAssets, pose: Pose, mood: Mood): Promise<{ bytes: Buffer; distinct: number }> {
  const resolvedDocument = resolveStickerConfiguration(document, { pose, mood });
  if (resolvedDocument.kind !== "animated") throw new Error("Expected an animated configured document");
  const timing = animatedRenditionTiming(resolvedDocument, 12); const size = 512; const preview = 320;
  const prepared = await prepareRenditionAssets(resolvedDocument, assets, size, timing.times);
  const frames: Buffer[] = [];
  for (const time of timing.times) {
    const fragment = frameFragment(resolvedDocument, time, size, prepared, new IdFactory());
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}"><defs>${fragment.defs.join("")}</defs>${fragment.body}</svg>`;
    frames.push(await sharp(Buffer.from(svg)).resize(preview, preview).ensureAlpha().raw().toBuffer());
  }
  const hashes = new Set(frames.map(frame => createHash("sha256").update(frame).digest("hex")));
  if (hashes.size < 2) throw new Error(`${pose}/${mood} is not animated`);
  const bytes = await sharp(Buffer.concat(frames), { raw: { width: preview, height: preview * frames.length, channels: 4, pageHeight: preview } })
    .gif({ loop: 0, delay: timing.delaysMs, colours: 128, dither: .35 }).toBuffer();
  return { bytes, distinct: hashes.size };
}

async function buildOption(template: StickerDocument, option: Option) {
  const directory = resolve(root, option.id), assetsDirectory = resolve(directory, "assets");
  await mkdir(assetsDirectory, { recursive: true });
  const referenceBytes = await readFile(resolve(directory, "reference.png"));
  const posterId = uuid(`${option.id}:poster`), expressionId = uuid(`${option.id}:expressions`);
  const ids = new Map<string, string>(); const renderAssets: RenderAssets = new Map(); const files: Record<string, string> = {};
  const add = async (id: string, bytes: Buffer) => { renderAssets.set(id, { bytes: new Uint8Array(bytes), mimeType: "image/png" }); files[id] = `${id}.png`; await writeFile(resolve(assetsDirectory, files[id]), bytes); };
  await add(posterId, referenceBytes);
  await add(expressionId, await expressionSheet());
  for (const pose of poses) {
    const id = uuid(`${option.id}:${pose.id}`); ids.set(pose.id, id); await add(id, await frameSheet(option, pose.id));
  }
  const document = documentFromTemplate(template, option, ids, posterId, expressionId);
  await writeFile(resolve(directory, "document.json"), JSON.stringify(document, null, 2));
  await writeFile(resolve(directory, "assets.json"), JSON.stringify(files, null, 2));
  const examples: Array<{ pose: Pose; mood: Mood; file: string; frames: number; distinctFrames: number }> = [];
  const review: Array<{ title: string; bytes: Buffer }> = [];
  for (const pose of poses) for (const mood of moods) {
    const rendered = await renderPreview(document, renderAssets, pose.id, mood.id);
    const file = `${pose.id}-${mood.id}.gif`; await writeFile(resolve(directory, file), rendered.bytes);
    examples.push({ pose: pose.id, mood: mood.id, file, frames: 24, distinctFrames: rendered.distinct });
    review.push({ title: `${pose.label} · ${mood.label}`, bytes: await sharp(rendered.bytes).png().toBuffer() });
  }
  const wave = await readFile(resolve(directory, "wave-happy.gif"));
  const animated = sharp(wave, { animated: true }); const metadata = await animated.metadata();
  await animated.resize(512, 512).webp({ loop: 0, delay: metadata.delay, quality: 88 }).toFile(resolve(directory, "cover.webp"));
  await writeFile(resolve(directory, "review-sheet.png"), await contactSheet(review, 6, 180));
  const prompt = `Animate the supplied pink limbless mascot while preserving its exact silhouette, pink palette, unequal glossy eyes, and editable body/eyes/mouth layers. ${option.title} is guidance only and never replaces a user's requested subject. Use Idle, Greeting Wave, Bounce, Sway, Wiggle, Hop, Partial Turn, and Dance with independent Neutral, Happy, and Surprised moods.`;
  const approvedPlan = { version: 3, kind: "animated", title: `${option.title} pink mascot`, summary: "A reference-backed controllable mascot with 8 looping actions and 3 independent moods.", conceptPrompt: prompt, posePreset: "ultra", editableLayers: ["body", "eyes", "mouth"], configuration: document.configuration };
  await writeFile(resolve(directory, "approved-plan.json"), JSON.stringify(approvedPlan, null, 2));
  await writeFile(resolve(directory, "manifest.json"), JSON.stringify({ version: 3, poses, moods, examples, source: { workflow: "stickerGenerationWorkflow", generator: "editable-svg-mascot-v3", inspectedReference: "reference.png", optionId: option.id, prompt } }, null, 2));
  console.log(`Built ${option.id}: 8 poses × 3 moods`);
}

async function packageBundledDemo() {
  const directory = resolve(root, "bold-cartoon");
  await cp(resolve(directory, "document.json"), resolve(bundled, "creation-demo.json"));
  const files: Record<string, string> = JSON.parse(await readFile(resolve(directory, "assets.json"), "utf8")); const bundledFiles: Record<string, string> = {};
  for (const [id, filename] of Object.entries(files)) {
    const name = `creation-demo-v3-${id}`; await cp(resolve(directory, "assets", filename), resolve(bundled, `${name}.png`)); bundledFiles[id] = name;
  }
  await writeFile(resolve(bundled, "creation-demo-assets.json"), JSON.stringify(bundledFiles, null, 2));
  for (const pose of poses) for (const mood of moods) await cp(resolve(directory, `${pose.id}-${mood.id}.gif`), resolve(bundled, `creation-preview-${pose.id}-${mood.id}.gif`));
  await cp(resolve(directory, "wave-happy.gif"), resolve(bundled, "creation-type-animated.gif"));
  await sharp(resolve(directory, "idle-happy.gif")).png().toFile(resolve(bundled, "creation-type-static.png"));
  for (const mood of moods) await sharp(resolve(directory, `idle-${mood.id}.gif`)).png().toFile(resolve(bundled, `creation-mascot-${mood.id}.png`));
  await writeFile(resolve(bundled, "creation-presets-preview.json"), JSON.stringify(publicCreationPresetCatalog(), null, 2) + "\n");
}

async function buildLiveActivityAssets() {
  const base = options[0];
  const states = [
    ["Queued", "idle", "neutral", 0, "queued"], ["Running", "wave", "neutral", 2, "running"],
    ["Waiting", "sway", "neutral", 2, "waiting"], ["Stale", "sway", "neutral", 4, "stale"],
    ["Completed", "bounce", "happy", 2, "completed"], ["Failed", "idle", "neutral", 3, "failed"],
    ["Cancelled", "idle", "neutral", 3, "cancelled"],
  ] as const;
  for (const [name, pose, mood, frame, special] of states) {
    const imageset = resolve(activityAssets, `ActivityMascot${name}.imageset`); await mkdir(imageset, { recursive: true });
    const bytes = await sharp(Buffer.from(mascotSvg(base, pose, mood, frame, 132, special))).resize(132, 132).png().toBuffer();
    await writeFile(resolve(imageset, `activity-mascot-${name.toLowerCase()}.png`), bytes);
    await writeFile(resolve(imageset, "Contents.json"), JSON.stringify({ images: [{ filename: `activity-mascot-${name.toLowerCase()}.png`, idiom: "universal", scale: "3x" }], info: { author: "xcode", version: 1 } }, null, 2));
  }
  await writeFile(resolve(root, "review/live-activity-poses.png"), await contactSheet(await Promise.all(states.map(async ([name, pose, mood, frame, special]) => ({ title: name, bytes: await sharp(Buffer.from(mascotSvg(base, pose, mood, frame, 264, special))).resize(264, 264).png().toBuffer() }))), 4, 220));
}

async function buildMessageIcons() {
  const definitions: Array<[string, number, number]> = [
    ["icon-29@2x.png", 58, 58], ["icon-29@3x.png", 87, 87], ["icon-60x45@2x.png", 120, 90],
    ["icon-60x45@3x.png", 180, 135], ["icon-29@2x~ipad.png", 58, 58], ["icon-67x50@2x.png", 134, 100],
    ["icon-74x55@2x.png", 148, 110], ["icon-27x20@2x.png", 54, 40], ["icon-27x20@3x.png", 81, 60],
    ["icon-32x24@2x.png", 64, 48], ["icon-32x24@3x.png", 96, 72], ["icon-1024x768.png", 1024, 768],
  ];
  const master = await readFile(resolve(sourceRoot, "master.svg"), "utf8");
  const mouthStart = master.indexOf('<g id="mouth"');
  const original = mouthStart >= 0 ? `${master.slice(0, mouthStart)}</svg>` : master;
  for (const [name, width, height] of definitions) {
    const inset = Math.round(Math.min(width, height) * .12);
    const mascot = await sharp(Buffer.from(original)).resize({ width: width - inset * 2, height: height - inset * 2, fit: "contain", background: "#00000000" }).png().toBuffer();
    await sharp({ create: { width, height, channels: 3, background: "#F7F3EA" } }).composite([{ input: mascot, gravity: "centre" }]).flatten({ background: "#F7F3EA" }).removeAlpha().png().toFile(resolve(messageIcons, name));
  }
}

async function build() {
  for (const option of options) {
    const metadata = await sharp(resolve(root, option.id, "reference.png")).metadata();
    if (metadata.width !== 1024 || metadata.height !== 1024) throw new Error(`Inspect and regenerate ${option.id} reference before build`);
  }
  const template = StickerDocumentSchema.parse(JSON.parse(await readFile(resolve("public/images/creation/v2/bold-cartoon/document.json"), "utf8")));
  for (const option of options) await buildOption(template, option);
  await packageBundledDemo(); await buildLiveActivityAssets(); await buildMessageIcons();
  console.log("Built 288 looping previews, bundled demo assets, Live Activity poses, and 12 opaque Messages icons.");
}

if (phase === "references") await buildReferences();
else if (phase === "package") await packageBundledDemo();
else if (phase === "app-assets") { await buildLiveActivityAssets(); await buildMessageIcons(); }
else await build();
