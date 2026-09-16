import type { PresetText } from "@/lib/contracts/creation-presets";

const text = (en: string, simplified: string, traditional: string): PresetText => ({ en, "zh-Hans": simplified, "zh-Hant": traditional });
const poses = [
  { id: "idle", title: text("Idle", "待机", "待機") },
  { id: "wave", title: text("Wave", "挥手", "揮手") },
  { id: "bounce", title: text("Bounce", "弹跳", "彈跳") },
  { id: "sway", title: text("Sway", "摇摆", "搖擺") },
  { id: "wiggle", title: text("Wiggle", "扭动", "扭動") },
  { id: "hop", title: text("Hop", "跳跃", "跳躍") },
  { id: "spin", title: text("Spin", "转身", "轉身") },
  { id: "dance", title: text("Dance", "跳舞", "跳舞") },
];
const moods = [
  { id: "neutral", title: text("Neutral", "平静", "平靜") },
  { id: "happy", title: text("Happy", "开心", "開心") },
  { id: "surprised", title: text("Surprised", "惊讶", "驚訝") },
];

/** Immutable GIFs exported from the app's generated sprite documents, not CSS transforms. */
export function creationPreview(id: string) {
  const base = `/images/creation/v2/${id}`;
  return {
    url: `${base}/wave-happy.gif`, defaultPose: "wave", defaultMood: "happy", poses, moods,
    variants: poses.flatMap(pose => moods.map(mood => ({ pose: pose.id, mood: mood.id, url: `${base}/${pose.id}-${mood.id}.gif` }))),
  };
}
