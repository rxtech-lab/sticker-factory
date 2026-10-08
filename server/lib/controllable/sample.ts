import type { SVGAnimationRig, SVGState } from "@/lib/contracts/controllable";

export function matchesSVGState(when: Record<string, (string | boolean)[]>, state: SVGState): boolean {
  return Object.entries(when).every(([key, choices]) => choices.includes(state[key]));
}
export function sampleSVG(rig: SVGAnimationRig, selected: SVGState, time: number) {
  const state = { ...rig.defaults, ...selected };
  if (typeof state.expression === "string" && rig.emotions[state.expression] && selected.emotion === undefined) state.emotion = rig.emotions[state.expression];
  return rig.groups.map(group => {
    const result = { id: group.id, x: 0, y: 0, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1,
      visible: matchesSVGState(group.when, state), color: null as string | null };
    for (const track of group.tracks) {
      const elapsed = Math.max(0, Number.isFinite(time) ? time : 0);
      const t = track.loop ? elapsed % track.duration : Math.min(elapsed, track.duration);
      let value = track.frames[0].value;
      for (let i = 1; i < track.frames.length; i++) {
        const a = track.frames[i - 1], b = track.frames[i];
        if (t >= b.time) { value = b.value; continue; }
        value = track.interpolation === "step" ? a.value : a.value + (b.value - a.value) * (t - a.time) / (b.time - a.time);
        break;
      }
      result[track.property] = value;
    }
    result.opacity = Math.min(1, Math.max(0, result.opacity));
    for (const color of group.colors) if (matchesSVGState(color.when, state)) result.color = color.color;
    return result;
  });
}
export function renderSVG(rig: SVGAnimationRig, state: SVGState = {}, time = 0): string {
  const samples = sampleSVG(rig, state, time);
  const groups = rig.groups.map((group, i) => {
    const s = samples[i]; if (!s.visible || s.opacity === 0) return "";
    const px = group.pivot.x * rig.width, py = group.pivot.y * rig.height;
    // Namespace all local ids before combining otherwise independent SVG documents.
    let markup = group.markup.replace(/\bid=(["'])([^"']+)\1/g, (_, _q, id) => `id="${group.id}_${id}"`)
      .replace(/url\(#([A-Za-z][A-Za-z0-9_-]*)\)/g, `url(#${group.id}_$1)`);
    if (s.color) markup = markup.replace(/\bfill=(["'])(?!none\1)([^"']*)\1/g, `fill="${s.color}"`);
    return `<g opacity="${s.opacity}" transform="translate(${s.x} ${s.y}) translate(${px} ${py}) rotate(${s.rotation}) scale(${s.scaleX} ${s.scaleY}) translate(${-px} ${-py})">${markup}</g>`;
  }).join("");
  const flip = (state.facing ?? rig.defaults.facing) === "left" && !rig.groups.some(g => g.when.facing);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${rig.width}" height="${rig.height}" viewBox="0 0 ${rig.width} ${rig.height}">${flip ? `<g transform="translate(${rig.width} 0) scale(-1 1)">${groups}</g>` : groups}</svg>`;
}
