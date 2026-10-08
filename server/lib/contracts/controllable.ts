import { z } from "zod";

export const ControllableEngineSchema = z.enum(["legacy", "svg"]);
export type ControllableEngineID = z.infer<typeof ControllableEngineSchema>;
const ID = z.string().regex(/^[A-Za-z][A-Za-z0-9_-]{0,63}$/);
const Value = z.union([z.string().max(80), z.boolean()]);
const Point = z.object({ x: z.number().finite().min(0).max(1), y: z.number().finite().min(0).max(1) }).strict();
const Polygon = z.array(Point).min(3).max(32);
const Condition = z.record(ID, z.array(Value).min(1).max(16));
const tags = new Set(["svg", "g", "path", "rect", "circle", "ellipse", "polygon", "polyline", "line", "defs", "linearGradient", "radialGradient", "stop", "clipPath"]);
const attributes = new Set("xmlns viewBox width height x y x1 y1 x2 y2 cx cy r rx ry d points fill stroke stroke-width stroke-linecap stroke-linejoin stroke-dasharray fill-rule clip-rule opacity fill-opacity stroke-opacity transform id clip-path clipPathUnits offset stop-color stop-opacity gradientUnits gradientTransform".split(" "));

/** Deliberately small vector-only XML dialect: no CSS, scripts, entities, links or embedded images. */
export function safeVectorMarkup(markup: string): boolean {
  if (Buffer.byteLength(markup) > 80_000 || /[&]|<!|<\?|[\u0000-\u0008]/.test(markup)) return false;
  const stack: string[] = []; let end = 0; let roots = 0;
  const ids = new Map<string, string>(), references: { id: string; attribute: string }[] = [];
  for (const tag of markup.matchAll(/<([^<>]+)>/g)) {
    if (markup.slice(end, tag.index).trim()) return false;
    end = tag.index! + tag[0].length;
    const close = /^\/([A-Za-z]+)\s*$/.exec(tag[1]);
    if (close) { if (stack.pop() !== close[1]) return false; continue; }
    const open = /^([A-Za-z]+)([\s\S]*?)(\/?)$/.exec(tag[1]);
    if (!open || !tags.has(open[1]) || stack.length > 32 || (open[1] === "svg" && stack.length > 0)) return false;
    if (open[1] === "clipPath" && !/clipPathUnits=["']userSpaceOnUse["']/.test(open[2])) return false;
    if (!stack.length && (++roots !== 1 || open[1] !== "svg")) return false;
    let rest = open[2]; const seen = new Set<string>();
    while (rest.trim()) {
      const attr = /^\s+([A-Za-z][A-Za-z-]*)\s*=\s*(?:"([^"<>]*)"|'([^'<>]*)')/.exec(rest);
      if (!attr || !attributes.has(attr[1]) || seen.has(attr[1])) return false;
      seen.add(attr[1]); const value = attr[2] ?? attr[3];
      if (attr[1] === "id") {
        if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(value) || ids.has(value)) return false;
        ids.set(value, open[1]);
      }
      if (value.includes("url(")) {
        const reference = /^url\(#([A-Za-z][A-Za-z0-9_-]*)\)$/.exec(value);
        if (!reference) return false;
        if (stack.includes("defs") || open[1] === "clipPath") return false;
        if (!["fill", "stroke", "clip-path"].includes(attr[1])) return false;
        references.push({ id: reference[1], attribute: attr[1] });
      }
      if (attr[1] === "xmlns") { if (value !== "http://www.w3.org/2000/svg") return false; }
      else if (/:|\\|@|url\((?!#[A-Za-z][A-Za-z0-9_-]*\))/.test(value)) return false;
      rest = rest.slice(attr[0].length);
    }
    if (!open[3]) stack.push(open[1]);
  }
  return roots === 1 && stack.length === 0 && !markup.slice(end).trim()
    && references.every(({ id, attribute }) => attribute === "clip-path" ? ids.get(id) === "clipPath" : ["linearGradient", "radialGradient"].includes(ids.get(id) ?? ""));
}

export const SVGTrackSchema = z.object({
  property: z.enum(["x", "y", "rotation", "scaleX", "scaleY", "opacity"]),
  duration: z.number().min(0.1).max(60),
  loop: z.boolean(),
  interpolation: z.enum(["linear", "step"]),
  frames: z.array(z.object({ time: z.number().min(0).max(60), value: z.number().finite().min(-4096).max(4096) }).strict()).min(1).max(32),
}).strict().superRefine((track, ctx) => {
  if (track.frames[0].time !== 0 || track.frames.some((frame, i) => frame.time > track.duration || (i > 0 && frame.time <= track.frames[i - 1].time))) ctx.addIssue({ code: "custom", message: "Frames must start at zero and increase within the track duration" });
});
export const SVGGroupSchema = z.object({
  id: ID, markup: z.string().refine(safeVectorMarkup, "Unsupported or unsafe vector markup"),
  pivot: Point,
  when: Condition,
  tracks: z.array(SVGTrackSchema).max(6),
  /** A native tint override, selected by semantic state without rewriting the geometry. */
  colors: z.array(z.object({ when: Condition, color: z.string().regex(/^#[0-9A-Fa-f]{6}$/) }).strict()).max(12),
  depth: z.number().min(0).max(1).nullable(),
}).strict();
export const SVGAnimationRigSchema = z.object({
  version: z.literal(1), width: z.number().int().min(16).max(4096), height: z.number().int().min(16).max(4096),
  defaults: z.record(ID, Value),
  groups: z.array(SVGGroupSchema).min(1).max(96),
  emotions: z.record(ID, z.enum(["sick", "sleepy", "grumpy", "content", "joyful"])),
}).strict().superRefine((rig, ctx) => {
  if (new Set(rig.groups.map(g => g.id)).size !== rig.groups.length) ctx.addIssue({ code: "custom", message: "Duplicate SVG group id" });
  if (Buffer.byteLength(JSON.stringify(rig)) > 400_000) ctx.addIssue({ code: "custom", message: "SVG rig exceeds 400 KB" });
  for (const group of rig.groups) if (new Set(group.tracks.map(t => t.property)).size !== group.tracks.length) ctx.addIssue({ code: "custom", message: "Duplicate group animation channel" });
  for (const group of rig.groups) {
    const viewport = new RegExp(`^<svg\\s[^>]*viewBox=["']0 0 ${rig.width} ${rig.height}["']`);
    if (!viewport.test(group.markup.trim())) ctx.addIssue({ code: "custom", message: "Every group must use the rig's viewBox" });
    for (const when of [group.when, ...group.colors.map(c => c.when)]) {
      if (Object.keys(when).some(key => !(key in rig.defaults))) ctx.addIssue({ code: "custom", message: "Binding has no declared default" });
    }
  }
});
export type SVGAnimationRig = z.infer<typeof SVGAnimationRigSchema>;
export type SVGState = Record<string, string | boolean>;
export const SVGSceneSchema = z.object({
  version: z.literal(1), engine: z.literal("svg"), rig: SVGAnimationRigSchema,
  indoor: z.boolean(), spawn: Point, walkable: Polygon, obstacles: z.array(Polygon).max(24), shelters: z.array(Polygon).max(12),
  fixtures: z.object({ clock: Point.nullable(), weather: Point.nullable(), status: Point.nullable() }).strict(),
  effects: z.object({
    lights: z.array(ID).min(1).max(12), lightPools: z.array(ID).min(1).max(12),
    precipitation: z.array(ID).min(1).max(12), umbrellas: z.array(ID).max(12), puddles: z.array(ID).max(12),
    windows: z.array(z.object({ groupId: ID, bounds: Polygon }).strict()).max(12),
  }).strict(),
}).strict().superRefine((scene, ctx) => {
  const area = (polygon: { x: number; y: number }[]) => Math.abs(polygon.reduce((sum, p, i) => {
    const next = polygon[(i + 1) % polygon.length]; return sum + p.x * next.y - next.x * p.y;
  }, 0)) / 2;
  const polygons = [scene.walkable, ...scene.obstacles, ...scene.shelters, ...scene.effects.windows.map(w => w.bounds)];
  const footprint = [[-.025, -.015], [.025, -.015], [.025, .015], [-.025, .015]].map(([x, y]) => ({ x: scene.spawn.x + x, y: scene.spawn.y + y }));
  const edgesIntersect = (a: typeof footprint, b: typeof footprint) => a.some((p, i) => b.some((q, j) => segmentsIntersect(p, a[(i + 1) % a.length], q, b[(j + 1) % b.length])));
  if (area(scene.walkable) < 0.015 || polygons.some(p => area(p) < 0.0001 || polygonCrossesItself(p))
    || footprint.some(p => !pointInPolygon(p, scene.walkable)) || edgesIntersect(footprint, scene.walkable)
    || scene.obstacles.some(o => pointInPolygon(scene.spawn, o) || o.some(p => pointInPolygon(p, footprint)) || edgesIntersect(footprint, o))) {
    ctx.addIssue({ code: "custom", message: "Scene needs usable walkable ground and an unobstructed spawn" });
  }
  if (!scene.rig.groups.some(g => g.when.night?.includes(true))) ctx.addIssue({ code: "custom", message: "Scene needs nighttime lighting groups" });
  if (!scene.rig.groups.some(g => g.when.weather?.includes("rainy"))) ctx.addIssue({ code: "custom", message: "Scene needs rainy weather groups" });
  if (!scene.fixtures.clock || !scene.fixtures.weather || !scene.fixtures.status) ctx.addIssue({ code: "custom", message: "Scenes must retain the clock, weather and status boards" });
  if (!scene.rig.groups.some(g => g.colors.some(c => c.when.emotion?.length))) ctx.addIssue({ code: "custom", message: "Scene needs emotion-responsive ambient colors" });
  const byID = new Map(scene.rig.groups.map(g => [g.id, g]));
  const ids = [...scene.effects.lights, ...scene.effects.lightPools, ...scene.effects.precipitation, ...scene.effects.umbrellas, ...scene.effects.puddles, ...scene.effects.windows.map(w => w.groupId)];
  if (ids.some(id => !byID.has(id))) ctx.addIssue({ code: "custom", message: "Scene effect references a missing group" });
  if ([...scene.effects.lights, ...scene.effects.lightPools].some(id => !byID.get(id)?.when.night?.includes(true) || byID.get(id)?.when.night?.includes(false))) ctx.addIssue({ code: "custom", message: "Generated lights must switch off in daylight" });
  if (scene.indoor && (!scene.effects.windows.length || scene.effects.precipitation.some(id => !byID.get(id)?.markup.includes("clip-path=")))) ctx.addIssue({ code: "custom", message: "Indoor precipitation must be clipped to declared windows" });
  if (!scene.indoor && (!scene.effects.umbrellas.length || !scene.effects.puddles.length)) ctx.addIssue({ code: "custom", message: "Outdoor rain needs umbrellas and puddles" });
  if ([...scene.effects.umbrellas, ...scene.effects.puddles].some(id => !byID.get(id)?.when.weather?.includes("rainy"))) ctx.addIssue({ code: "custom", message: "Umbrellas and puddles need explicit rain bindings" });
  for (const weather of ["cloudy", "rainy", "snowy", "stormy", "foggy", "windy"]) {
    if (!scene.rig.groups.some(g => [g.when, ...g.colors.map(c => c.when)].some(w => w.weather?.includes(weather)))) ctx.addIssue({ code: "custom", message: `Scene has no ${weather} binding` });
  }
});
export type SVGScene = z.infer<typeof SVGSceneSchema>;

export function pointInPolygon(point: { x: number; y: number }, polygon: { x: number; y: number }[]): boolean {
  let inside = false;
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const a = polygon[i], b = polygon[j];
    if ((a.y > point.y) !== (b.y > point.y) && point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}

function polygonCrossesItself(polygon: { x: number; y: number }[]): boolean {
  for (let i = 0; i < polygon.length; i++) for (let j = i + 2; j < polygon.length; j++) {
    if (i === 0 && j === polygon.length - 1) continue;
    const a = polygon[i], b = polygon[(i + 1) % polygon.length], c = polygon[j], d = polygon[(j + 1) % polygon.length];
    if (segmentsIntersect(a, b, c, d)) return true;
  }
  return false;
}
function segmentsIntersect(a: { x: number; y: number }, b: typeof a, c: typeof a, d: typeof a): boolean {
  if (Math.max(a.x, b.x) < Math.min(c.x, d.x) || Math.max(c.x, d.x) < Math.min(a.x, b.x)
    || Math.max(a.y, b.y) < Math.min(c.y, d.y) || Math.max(c.y, d.y) < Math.min(a.y, b.y)) return false;
  const cross = (p: { x: number; y: number }, q: typeof p, r: typeof p) => (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x);
  return cross(a, b, c) * cross(a, b, d) <= 0 && cross(c, d, a) * cross(c, d, b) <= 0;
}
