import type { StickerEasingV1 } from "@/lib/contracts/animation";

/**
 * The easing curves, as a plain function of normalized progress.
 *
 * This is a port of `AnimationInterpolator.easedProgress` in the `AnimatedView` package, and the two
 * must stay identical for the same reason the compilers must: `arcTo` bakes eased progress into the
 * keyframes it emits, so a drifted curve here would produce a document the other side recompiles
 * differently and the document schema then rejects.
 *
 * The polynomial cases are written as repeated multiplication rather than `Math.pow`. `pow` is not
 * required to be correctly rounded, so V8 and libm may disagree in the last bit; multiplication is
 * exact IEEE-754 in both. The two springs have no such form — they are a damped cosine, and the
 * `exp`/`cos` there carry the same (so far theoretical) parity risk the compiler's existing `sin`
 * already does.
 *
 * The springs deliberately overshoot 1 before settling. Callers that need to land exactly on a
 * target must pin the final sample themselves rather than trusting `easedProgress(1)`.
 */
export function easedProgress(progress: number, easing: StickerEasingV1): number {
  const t = Math.min(Math.max(progress, 0), 1);
  switch (easing) {
  case "linear":
    return t;
  case "easeIn":
    return t * t * t;
  case "easeOut": {
    const remaining = 1 - t;
    return 1 - remaining * remaining * remaining;
  }
  case "easeInOut": {
    if (t < 0.5) return 4 * t * t * t;
    const remaining = -2 * t + 2;
    return 1 - (remaining * remaining * remaining) / 2;
  }
  case "springSoft":
    return 1 - Math.exp(-7 * t) * Math.cos(8 * t);
  case "springBouncy":
    return 1 - Math.exp(-5 * t) * Math.cos(12 * t);
  }
}
