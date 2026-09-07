import { shareImage } from "@/lib/share-image";

export const alt = "Your idea. Your sticker. Five free generations each day with Sticker Factory.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";
export const runtime = "nodejs";

export default function Image() {
  return shareImage({ title: "Your idea. Your sticker.", subtitle: "Make something worth sending. Open quick mode with our App Clip." });
}
