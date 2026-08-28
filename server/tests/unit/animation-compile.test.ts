import { describe, expect, it } from "vitest";
import {
  AnimationCompileError,
  compileLayerAnimation,
  compileLayerAnimations,
  countKeyframes,
  MAX_DOCUMENT_KEYFRAMES,
  type AnimationTiming,
} from "@/lib/animation/compile";
import {
  AnimationSpecV1Schema,
  DEFAULT_ANCHOR,
  type AnimationAnchorV1,
  type AnimationSpecV1,
} from "@/lib/contracts/animation";

const ANIMATED: AnimationTiming = { kind: "animated", durationSeconds: 4 };
const STATIC: AnimationTiming = { kind: "static", durationSeconds: 0 };

/** Parse through the schema so every test exercises the same defaults the model gets. */
function spec(value: unknown): AnimationSpecV1 {
  return AnimationSpecV1Schema.parse(value);
}

const anchorAt = (x: number, y: number, scale = 1): AnimationAnchorV1 => ({
  position: { x, y },
  scale: { x: scale, y: scale },
  rotationDegrees: 0,
  opacity: 1,
  trim: { start: 0, end: 1 },
});

describe("delay handling", () => {
  it("places keyframes at delay and delay+duration", () => {
    const compiled = compileLayerAnimation(
      [spec({ type: "fadeIn", delay: 0.3, duration: 0.5 })],
      DEFAULT_ANCHOR,
      ANIMATED,
    );
    expect(compiled.opacity.map((frame) => frame.timeSeconds)).toEqual([0.3, 0.8]);
    expect(compiled.opacity.map((frame) => frame.value)).toEqual([0, 1]);
  });

  it("staggers layers purely by delay", () => {
    const times = [0, 0.2, 0.4].map((delay) => compileLayerAnimation(
      [spec({ type: "popIn", delay, duration: 0.4 })],
      DEFAULT_ANCHOR,
      ANIMATED,
    ).scale.map((frame) => frame.timeSeconds));
    expect(times).toEqual([[0, 0.4], [0.2, 0.6], [0.4, 0.8]]);
  });

  it("rejects a spec that runs past the sticker duration", () => {
    expect(() => compileLayerAnimation(
      [spec({ type: "fadeIn", delay: 1.8, duration: 0.5 })],
      DEFAULT_ANCHOR,
      { kind: "animated", durationSeconds: 2 },
    )).toThrow(AnimationCompileError);
  });
});

describe("easing lands on the destination keyframe", () => {
  // StickerInterpolator reads easing from the upper keyframe of the blended pair, so easing on the
  // first keyframe of a channel would never be applied.
  it("puts the spec easing on the end frame and linear on the start frame", () => {
    const compiled = compileLayerAnimation(
      [spec({ type: "popIn", duration: 0.5, easing: "springBouncy" })],
      DEFAULT_ANCHOR,
      ANIMATED,
    );
    expect(compiled.scale[0].easing).toBe("linear");
    expect(compiled.scale[1].easing).toBe("springBouncy");
  });
});

describe("anchors", () => {
  it("emits a resting keyframe only for channels that differ from the renderer default", () => {
    const compiled = compileLayerAnimation([], anchorAt(0.25, 0.75, 0.4), ANIMATED);
    expect(compiled.position).toEqual([{ timeSeconds: 0, x: 0.25, y: 0.75, easing: "linear" }]);
    expect(compiled.scale).toEqual([{ timeSeconds: 0, x: 0.4, y: 0.4, easing: "linear" }]);
    // Rotation and opacity match the renderer default, so they cost nothing.
    expect(compiled.rotation).toEqual([]);
    expect(compiled.opacity).toEqual([]);
  });

  it("spends nothing at all on a layer resting at the defaults", () => {
    expect(countKeyframes(compileLayerAnimation([], DEFAULT_ANCHOR, ANIMATED))).toBe(0);
  });

  it("does not add an anchor keyframe to a channel a spec already drives", () => {
    const compiled = compileLayerAnimation(
      [spec({ type: "moveTo", x: 0.9, y: 0.9, duration: 1 })],
      anchorAt(0.2, 0.2),
      ANIMATED,
    );
    expect(compiled.position).toHaveLength(2);
    expect(compiled.position[0]).toMatchObject({ timeSeconds: 0, x: 0.2, y: 0.2 });
  });

  it("animates relative to the anchor rather than the canvas centre", () => {
    const compiled = compileLayerAnimation(
      [spec({ type: "popIn", from: 0.5, duration: 0.4 })],
      anchorAt(0.5, 0.5, 0.8),
      ANIMATED,
    );
    expect(compiled.scale.map((frame) => frame.x)).toEqual([0.4, 0.8]);
  });
});

describe("per spec type", () => {
  const cases: Array<{ name: string; input: unknown; expect: (compiled: ReturnType<typeof compileLayerAnimation>) => void }> = [
    {
      name: "fadeOut ends invisible",
      input: { type: "fadeOut", duration: 0.5 },
      expect: (c) => expect(c.opacity.map((f) => f.value)).toEqual([1, 0]),
    },
    {
      name: "popOut shrinks and fades",
      input: { type: "popOut", to: 0.5, duration: 0.5 },
      expect: (c) => {
        expect(c.scale.map((f) => f.x)).toEqual([1, 0.5]);
        expect(c.opacity.map((f) => f.value)).toEqual([1, 0]);
      },
    },
    {
      name: "slideIn arrives at the anchor",
      input: { type: "slideIn", direction: "up", distance: 0.3, duration: 0.5 },
      expect: (c) => {
        expect(c.position[0]).toMatchObject({ y: 0.8 });
        expect(c.position[1]).toMatchObject({ y: 0.5 });
        expect(c.opacity.map((f) => f.value)).toEqual([0, 1]);
      },
    },
    {
      name: "slideOut departs from the anchor",
      input: { type: "slideOut", direction: "left", distance: 0.4, duration: 0.5 },
      expect: (c) => {
        expect(c.position[0]).toMatchObject({ x: 0.5 });
        expect(c.position[1]).toMatchObject({ x: 0.9 });
      },
    },
    {
      name: "scaleTo reaches the target",
      input: { type: "scaleTo", x: 2, y: 3, duration: 0.5 },
      expect: (c) => expect(c.scale[1]).toMatchObject({ x: 2, y: 3 }),
    },
    {
      name: "rotateTo reaches the target",
      input: { type: "rotateTo", degrees: 45, duration: 0.5 },
      expect: (c) => expect(c.rotation.map((f) => f.degrees)).toEqual([0, 45]),
    },
    {
      name: "spin cw turns a full circle",
      input: { type: "spin", turns: 1, duration: 1 },
      expect: (c) => expect(c.rotation.map((f) => f.degrees)).toEqual([0, 360]),
    },
    {
      name: "spin ccw turns backwards",
      input: { type: "spin", turns: 0.5, direction: "ccw", duration: 1 },
      expect: (c) => expect(c.rotation.map((f) => f.degrees)).toEqual([0, -180]),
    },
    {
      name: "wiggle samples zero/peak/zero/trough and returns to rest",
      input: { type: "wiggle", amplitudeDegrees: 10, cycles: 1, duration: 1 },
      expect: (c) => expect(c.rotation.map((f) => f.degrees)).toEqual([0, 10, 0, -10, 0]),
    },
    {
      name: "pulse peaks at maxScale and troughs at minScale",
      input: { type: "pulse", minScale: 0.9, maxScale: 1.2, cycles: 1, duration: 1 },
      expect: (c) => expect(c.scale.map((f) => f.x)).toEqual([1, 1.2, 1, 0.9, 1]),
    },
    {
      name: "float moves up first (negative y is up)",
      input: { type: "float", amplitude: 0.1, cycles: 1, duration: 1 },
      expect: (c) => expect(c.position.map((f) => f.y)).toEqual([0.5, 0.4, 0.5, 0.6, 0.5]),
    },
    {
      name: "bounce decays each hop and lands at rest",
      input: { type: "bounce", height: 0.2, bounces: 2, duration: 1 },
      expect: (c) => {
        expect(c.position.map((f) => f.y)).toEqual([0.5, 0.3, 0.5, 0.38, 0.5]);
        expect(c.position[c.position.length - 1].y).toBe(0.5);
      },
    },
    {
      name: "arcTo lands exactly on its target",
      input: { type: "arcTo", x: 0.9, y: 0.5, duration: 1 },
      expect: (c) => {
        expect(c.position[0]).toMatchObject({ x: 0.5, y: 0.5 });
        expect(c.position.at(-1)).toMatchObject({ x: 0.9, y: 0.5 });
      },
    },
    {
      name: "blurIn resolves to sharp",
      input: { type: "blurIn", radius: 6, duration: 0.5 },
      expect: (c) => expect(c.effects.map((f) => f.blurRadius)).toEqual([6, 0]),
    },
    {
      name: "blurOut ends blurred",
      input: { type: "blurOut", radius: 6, duration: 0.5 },
      expect: (c) => expect(c.effects.map((f) => f.blurRadius)).toEqual([0, 6]),
    },
    {
      name: "hueShift reaches the target hue",
      input: { type: "hueShift", degrees: -90, duration: 0.5 },
      expect: (c) => expect(c.effects.map((f) => f.hueDegrees)).toEqual([0, -90]),
    },
    {
      name: "wipeIn opens the window from nothing to the whole layer",
      input: { type: "wipeIn", direction: "right", duration: 0.5 },
      expect: (c) => {
        expect(c.wipe.map((f) => [f.start, f.end])).toEqual([[0, 0], [0, 1]]);
        // `right` means the reveal travels rightwards, which is the paint convention's 0°.
        expect(c.wipe.every((f) => f.angleDegrees === 0)).toBe(true);
      },
    },
    {
      name: "wipeOut eats the layer from the edge it was revealed from",
      input: { type: "wipeOut", direction: "up", duration: 0.5 },
      expect: (c) => {
        expect(c.wipe.map((f) => [f.start, f.end])).toEqual([[0, 1], [1, 1]]);
        expect(c.wipe.every((f) => f.angleDegrees === 270)).toBe(true);
      },
    },
    {
      name: "wipeTo starts from the fully open window",
      input: { type: "wipeTo", start: 0.25, end: 0.75, angleDegrees: 45, duration: 0.5 },
      expect: (c) => {
        expect(c.wipe.map((f) => [f.start, f.end])).toEqual([[0, 1], [0.25, 0.75]]);
        expect(c.wipe.every((f) => f.angleDegrees === 45)).toBe(true);
      },
    },
    {
      name: "shine sweeps a band clean across and off the far edge",
      input: { type: "shine", width: 0.2, intensity: 0.8, duration: 1 },
      expect: (c) => {
        expect(c.sheen).toHaveLength(4);
        // Fully off-canvas at both ends: the band is centred on `position`, so half a width past.
        expect(c.sheen.at(0)?.position).toBe(-0.1);
        expect(c.sheen.at(-1)?.position).toBe(1.1);
        // Trapezoid, not a triangle — full brightness is held across the middle of the traverse.
        expect(c.sheen.map((f) => f.intensity)).toEqual([0, 0.8, 0.8, 0]);
      },
    },
    {
      name: "bloomIn ramps the halo up and bloomOut takes it away",
      input: { type: "bloomIn", intensity: 0.5, radius: 0.1, duration: 0.5 },
      expect: (c) => {
        expect(c.glow.map((f) => f.amount)).toEqual([0, 0.5]);
        expect(c.glow.every((f) => f.radius === 0.1)).toBe(true);
      },
    },
    {
      name: "bloomPulse breathes back to dark on every cycle",
      input: { type: "bloomPulse", intensity: 0.6, cycles: 2, duration: 1 },
      expect: (c) => {
        // 2n+1, not the 4n+1 a sine sampling would cost: a glow only brightens.
        expect(c.glow.map((f) => f.amount)).toEqual([0, 0.6, 0, 0.6, 0]);
        expect(c.glow.map((f) => f.timeSeconds)).toEqual([0, 0.25, 0.5, 0.75, 1]);
      },
    },
  ];

  for (const testCase of cases) {
    it(testCase.name, () => {
      testCase.expect(compileLayerAnimation([spec(testCase.input)], DEFAULT_ANCHOR, ANIMATED));
    });
  }
});

describe("shine", () => {
  const shine = (value: Record<string, unknown>) =>
    compileLayerAnimation([spec({ type: "shine", duration: 1, ...value })], DEFAULT_ANCHOR, ANIMATED).sheen;

  it("travels at a constant speed", () => {
    // Position and time both advance linearly in the same phase, so equal time gaps cover equal
    // distance. A band that accelerates reads as a stutter rather than as light moving.
    const frames = shine({ width: 0.2 });
    for (let index = 1; index < frames.length; index += 1) {
      const dt = frames[index].timeSeconds - frames[index - 1].timeSeconds;
      const dx = frames[index].position - frames[index - 1].position;
      expect(dx / dt).toBeCloseTo(1.2 / (1 * 0.88), 6);
    }
  });

  it("ignores the spec easing entirely", () => {
    // Easing the closing keyframe would decelerate only the second half of the traverse.
    const frames = shine({ easing: "springBouncy" });
    expect(frames.every((frame) => frame.easing === "linear")).toBe(true);
  });

  it("repeats without ever putting two positions on one timestamp", () => {
    // The reason `cycles` can exist at all: the retreat to the next cycle's leading edge happens
    // during the reserved tail, at zero intensity, so it needs no discontinuity.
    const frames = shine({ cycles: 3 });
    expect(frames).toHaveLength(12);
    const times = frames.map((frame) => frame.timeSeconds);
    expect(new Set(times).size).toBe(times.length);
    expect([...times]).toEqual([...times].sort((a, b) => a - b));
  });

  it("is dark whenever the band is outside the layer", () => {
    const frames = shine({ width: 0.2, cycles: 2 });
    for (const frame of frames) {
      if (frame.position <= -0.1 || frame.position >= 1.1) expect(frame.intensity).toBe(0);
    }
  });

  it("composes with a wipe over the very same window", () => {
    // The whole reason wipe and sheen are separate channels: these two would collide on one.
    const compiled = compileLayerAnimation(
      [spec({ type: "wipeIn", direction: "right", duration: 1 }), spec({ type: "shine", duration: 1 })],
      DEFAULT_ANCHOR,
      ANIMATED,
    );
    expect(compiled.wipe).toHaveLength(2);
    expect(compiled.sheen).toHaveLength(4);
  });

  it("composes with a blur, which a shared effects channel would have rejected", () => {
    const compiled = compileLayerAnimation(
      [spec({ type: "blurOut", duration: 1 }), spec({ type: "bloomIn", duration: 1 })],
      DEFAULT_ANCHOR,
      ANIMATED,
    );
    expect(compiled.effects).toHaveLength(2);
    expect(compiled.glow).toHaveLength(2);
  });

  it("still rejects two shines that genuinely overlap", () => {
    expect(() => compileLayerAnimation(
      [
        spec({ type: "shine", delay: 0, duration: 1 }),
        spec({ type: "shine", delay: 0.5, duration: 1 }),
      ],
      DEFAULT_ANCHOR,
      ANIMATED,
    )).toThrow(AnimationCompileError);
  });
});

describe("arcTo", () => {
  const arc = (value: Record<string, unknown>, anchor = DEFAULT_ANCHOR) =>
    compileLayerAnimation([spec({ type: "arcTo", duration: 1, ...value })], anchor, ANIMATED).position;

  it("bows away from the straight line by arcHeight at the apex", () => {
    // A horizontal move: the midpoint of the chord is (0.5, 0.5), so an apex of 0.25 above it is
    // y = 0.25. Negative y is up, hence the subtraction.
    const frames = arc({ x: 0.9, y: 0.5, arcHeight: 0.25, easing: "linear" }, anchorAt(0.1, 0.5));
    const apex = frames[Math.floor((frames.length - 1) / 2)];
    expect(apex).toMatchObject({ x: 0.5, y: 0.25 });
  });

  it("is exactly a straight line at arcHeight 0", () => {
    const frames = arc({ x: 0.9, y: 0.9, arcHeight: 0, easing: "linear" });
    // Every sample sits on the chord from (0.5, 0.5) to (0.9, 0.9), which here means x === y.
    for (const frame of frames) expect(frame.y).toBeCloseTo(frame.x, 10);
  });

  it("arcs over the top whichever way the layer travels", () => {
    // The perpendicular of the travel vector flips with direction, so without the sign
    // normalisation these two would mirror rather than both bow upward.
    const rightward = arc({ x: 0.9, y: 0.5, arcHeight: 0.3, easing: "linear" }, anchorAt(0.1, 0.5));
    const leftward = arc({ x: 0.1, y: 0.5, arcHeight: 0.3, easing: "linear" }, anchorAt(0.9, 0.5));
    expect(Math.min(...rightward.map((frame) => frame.y))).toBeLessThan(0.5);
    expect(Math.min(...leftward.map((frame) => frame.y))).toBeLessThan(0.5);
    // Same path, walked backwards.
    expect(rightward.map((frame) => frame.y)).toEqual([...leftward.map((frame) => frame.y)].reverse());
  });

  it("tosses straight up when it returns to where it started", () => {
    const frames = arc({ x: 0.5, y: 0.5, arcHeight: 0.2, easing: "linear" });
    expect(new Set(frames.map((frame) => frame.x))).toEqual(new Set([0.5]));
    expect(frames[0].y).toBe(0.5);
    expect(frames.at(-1)!.y).toBe(0.5);
    expect(Math.min(...frames.map((frame) => frame.y))).toBeLessThan(0.4);
  });

  it("emits linear keyframes so the interpolator does not re-ease each sample", () => {
    // The easing is baked into where the samples sit. Leaving it on the keyframes would drop the
    // velocity to zero eleven times over and read as a stutter.
    const frames = arc({ x: 0.9, y: 0.2, easing: "springBouncy" });
    expect(frames.every((frame) => frame.easing === "linear")).toBe(true);
  });

  it("keeps a spring on the path instead of extrapolating past the end", () => {
    // springBouncy's eased progress exceeds 1; an unclamped Bézier parameter would throw the layer
    // off canvas rather than overshooting along the arc.
    const straight = arc({ x: 0.9, y: 0.5, arcHeight: 0, easing: "springBouncy" }, anchorAt(0.1, 0.5));
    for (const frame of straight) {
      expect(frame.x).toBeGreaterThanOrEqual(0.1);
      expect(frame.x).toBeLessThanOrEqual(0.9);
    }
  });

  it("costs eleven of the channel's thirty-two keyframes", () => {
    expect(arc({ x: 0.9, y: 0.2 })).toHaveLength(11);
  });

  it("cannot be chained, because every spec departs from the layer's anchor", () => {
    // The second arc starts at the anchor at 1s while the first leaves the layer at its target, so
    // the shared boundary keyframe is a real discontinuity rather than a duplicate. This is not
    // specific to arcTo — moveTo behaves the same — but it is the trap a "bounce it across the
    // frame" instruction walks straight into, so it is pinned here.
    expect(() => compileLayerAnimation(
      [
        spec({ type: "arcTo", x: 0.9, y: 0.5, delay: 0, duration: 1 }),
        spec({ type: "arcTo", x: 0.2, y: 0.5, delay: 1, duration: 1 }),
      ],
      DEFAULT_ANCHOR,
      ANIMATED,
    )).toThrow(/different position values at 1s/);
  });

  it("conflicts with another position spec over the same window", () => {
    expect(() => compileLayerAnimation(
      [
        spec({ type: "arcTo", x: 0.9, y: 0.5, delay: 0, duration: 1 }),
        spec({ type: "float", delay: 0.5, duration: 1 }),
      ],
      DEFAULT_ANCHOR,
      ANIMATED,
    )).toThrow(/both drive the position channel/);
  });
});

describe("channel conflicts", () => {
  it("rejects two specs driving one channel over the same window", () => {
    expect(() => compileLayerAnimation(
      [
        spec({ type: "fadeIn", delay: 0, duration: 1 }),
        spec({ type: "fadeOut", delay: 0.5, duration: 1 }),
      ],
      DEFAULT_ANCHOR,
      ANIMATED,
    )).toThrow(/both drive the opacity channel/);
  });

  it("rejects an indirect conflict through a shared channel", () => {
    // popIn writes scale *and* opacity, so it collides with a concurrent fadeIn.
    expect(() => compileLayerAnimation(
      [
        spec({ type: "popIn", delay: 0, duration: 1 }),
        spec({ type: "fadeIn", delay: 0.2, duration: 0.5 }),
      ],
      DEFAULT_ANCHOR,
      ANIMATED,
    )).toThrow(/opacity channel/);
  });

  it("allows specs on different channels to run concurrently", () => {
    const compiled = compileLayerAnimation(
      [
        spec({ type: "fadeIn", delay: 0, duration: 1 }),
        spec({ type: "spin", delay: 0, duration: 1 }),
      ],
      DEFAULT_ANCHOR,
      ANIMATED,
    );
    expect(compiled.opacity).toHaveLength(2);
    expect(compiled.rotation).toHaveLength(2);
  });

  it("merges a shared boundary keyframe when the values agree", () => {
    const compiled = compileLayerAnimation(
      [
        spec({ type: "fadeIn", delay: 0, duration: 0.5 }),
        spec({ type: "fadeOut", delay: 0.5, duration: 0.5 }),
      ],
      DEFAULT_ANCHOR,
      ANIMATED,
    );
    // Three, not four: the shared t=0.5 keyframe (opacity 1 on both sides) is deduplicated.
    expect(compiled.opacity.map((f) => [f.timeSeconds, f.value])).toEqual([[0, 0], [0.5, 1], [1, 0]]);
  });
});

describe("static documents", () => {
  it("refuses to animate a static sticker", () => {
    expect(() => compileLayerAnimation(
      [spec({ type: "fadeIn", duration: 0.5 })],
      DEFAULT_ANCHOR,
      STATIC,
    )).toThrow(/static sticker cannot animate/);
  });

  it("still lays out a static sticker via anchors at t=0", () => {
    const compiled = compileLayerAnimation([], anchorAt(0.3, 0.7, 0.5), STATIC);
    expect(compiled.position).toEqual([{ timeSeconds: 0, x: 0.3, y: 0.7, easing: "linear" }]);
    expect(compiled.scale[0].timeSeconds).toBe(0);
  });
});

describe("determinism", () => {
  it("compiles identical input to deep-equal output", () => {
    const specs = [
      spec({ type: "popIn", delay: 0.1, duration: 0.3 }),
      spec({ type: "wiggle", delay: 0.4, duration: 1.1, cycles: 3 }),
    ];
    const anchor = anchorAt(0.31, 0.67, 0.43);
    const first = compileLayerAnimation(specs, anchor, ANIMATED);
    const second = compileLayerAnimation(specs, anchor, ANIMATED);
    expect(first).toEqual(second);
    // Deep-equality is the document invariant, so float noise would break it.
    expect(JSON.stringify(first)).toBe(JSON.stringify(second));
  });

  it("survives a JSON round-trip", () => {
    // The compiled track is persisted as JSON and compared against a fresh compile on the way back
    // in. `JSON.stringify` renders -0 as "0", so any -0 the compiler emitted would fail to match.
    const specs = [
      spec({ type: "wiggle", duration: 2, cycles: 3 }),
      spec({ type: "float", delay: 2, duration: 2, cycles: 2 }),
    ];
    const compiled = compileLayerAnimation(specs, anchorAt(0.5, 0.5), ANIMATED);
    expect(JSON.parse(JSON.stringify(compiled))).toEqual(compiled);
  });

  it("never emits negative zero", () => {
    const compiled = compileLayerAnimation(
      [spec({ type: "wiggle", amplitudeDegrees: 10, cycles: 4, duration: 2 })],
      DEFAULT_ANCHOR,
      ANIMATED,
    );
    for (const frame of compiled.rotation) {
      expect(Object.is(frame.degrees, -0)).toBe(false);
      expect(Object.is(frame.timeSeconds, -0)).toBe(false);
    }
  });
});

describe("document keyframe budget", () => {
  it("keeps eight wiggling layers inside the 128-keyframe ceiling", () => {
    const layers = Array.from({ length: 8 }, (_, index) => ({
      layerId: `layer_${index}`,
      specs: [spec({ type: "wiggle", duration: 2, cycles: 8 })],
      anchor: anchorAt(0.1 + index * 0.1, 0.5, 0.3),
    }));
    const compiled = compileLayerAnimations(layers, ANIMATED);
    const total = compiled.reduce((sum, animation) => sum + countKeyframes(animation), 0);
    expect(total).toBeLessThanOrEqual(MAX_DOCUMENT_KEYFRAMES);
    // Degraded to fewer shakes, but every layer still wiggles.
    for (const animation of compiled) expect(animation.rotation.length).toBeGreaterThan(2);
  });

  it("lowers the cycle cap uniformly so the result is order independent", () => {
    const build = (ids: number[]) => ids.map((index) => ({
      layerId: `layer_${index}`,
      specs: [spec({ type: "pulse", duration: 2, cycles: 6 })],
      anchor: DEFAULT_ANCHOR,
    }));
    const forward = compileLayerAnimations(build([0, 1, 2, 3, 4, 5]), ANIMATED);
    const reversed = compileLayerAnimations(build([5, 4, 3, 2, 1, 0]), ANIMATED);
    expect(forward.map(countKeyframes)).toEqual(reversed.map(countKeyframes));
  });

  it("does not degrade animations that already fit", () => {
    const compiled = compileLayerAnimations(
      [{ layerId: "a", specs: [spec({ type: "wiggle", duration: 1, cycles: 2 })], anchor: DEFAULT_ANCHOR }],
      ANIMATED,
    );
    expect(compiled[0].rotation).toHaveLength(9);
  });

  it("rethrows a conflict rather than shrinking cycles forever", () => {
    expect(() => compileLayerAnimations(
      [{
        layerId: "a",
        specs: [
          spec({ type: "fadeIn", delay: 0, duration: 1 }),
          spec({ type: "fadeOut", delay: 0, duration: 1 }),
        ],
        anchor: DEFAULT_ANCHOR,
      }],
      ANIMATED,
    )).toThrow(/both drive the opacity channel/);
  });
});
