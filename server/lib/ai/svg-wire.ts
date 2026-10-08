import { z } from "zod";
import { SVGAnimationRigSchema, SVGGroupSchema, SVGSceneSchema, type SVGAnimationRig, type SVGScene } from "@/lib/contracts/controllable";

/**
 * What the model writes instead of the rig contract. Anthropic's constrained decoding only allows
 * fixed property names, so every z.record (when, defaults, emotions) comes back as `{}`; these are
 * the same fields as key/value lists, converted back to the contract with `fromWire`.
 */
const ID = z.string().regex(/^[A-Za-z][A-Za-z0-9_-]{0,63}$/);
const Value = z.union([z.string().max(80), z.boolean()]);
const WireCondition = z.array(z.object({ key: ID, values: z.array(Value).min(1).max(16) }).strict()).max(16);

const WireGroupSchema = z.object({
  ...SVGGroupSchema.shape,
  when: WireCondition,
  colors: z.array(z.object({ when: WireCondition, color: z.string().regex(/^#[0-9A-Fa-f]{6}$/) }).strict()).max(12),
}).strict();
export const WireRigSchema = z.object({
  ...SVGAnimationRigSchema.shape,
  defaults: z.array(z.object({ key: ID, value: Value }).strict()).max(16),
  groups: z.array(WireGroupSchema).min(1).max(96),
  emotions: z.array(z.object({ expression: ID, emotion: z.enum(["sick", "sleepy", "grumpy", "content", "joyful"]) }).strict()).max(32),
}).strict();
export const WireSceneSchema = z.object({ ...SVGSceneSchema.shape, rig: WireRigSchema }).strict();
type WireRig = z.infer<typeof WireRigSchema>;
type WireScene = z.infer<typeof WireSceneSchema>;

/** Repeated keys merge their values, so a split condition still means what the model intended. */
function condition(entries: z.infer<typeof WireCondition>): Record<string, (string | boolean)[]> {
  const merged: Record<string, (string | boolean)[]> = {};
  for (const { key, values } of entries) merged[key] = [...new Set([...(merged[key] ?? []), ...values])];
  return merged;
}

function rigFromWire(rig: WireRig): SVGAnimationRig {
  return {
    ...rig,
    defaults: Object.fromEntries(rig.defaults.map(d => [d.key, d.value])),
    groups: rig.groups.map(g => ({ ...g, when: condition(g.when), colors: g.colors.map(c => ({ ...c, when: condition(c.when) })) })),
    emotions: Object.fromEntries(rig.emotions.map(e => [e.expression, e.emotion])),
  };
}

/** Converts model output to the contract and validates it, so contract refinements still apply. */
export function fromWire(output: unknown, scene: boolean): SVGAnimationRig | SVGScene {
  if (scene) {
    const wire = WireSceneSchema.parse(output) as WireScene;
    return SVGSceneSchema.parse({ ...wire, rig: rigFromWire(wire.rig) });
  }
  return SVGAnimationRigSchema.parse(rigFromWire(WireRigSchema.parse(output)));
}
