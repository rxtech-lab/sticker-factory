"use client";
import { useState } from "react";
import { packShareURL } from "@/lib/sharing";
export function SharePackButton({ slug, title }: { slug: string; title: string }) {
  const [status, setStatus] = useState("");
  async function share() {
    try {
      const url = packShareURL(slug);
      if (navigator.share) await navigator.share({ title, url });
      else { await navigator.clipboard.writeText(url); setStatus("Link copied"); }
    } catch (error) { if (!(error instanceof DOMException && error.name === "AbortError")) setStatus("Could not share. Please try again."); }
  }
  return <><button className="secondary-button" onClick={share}>Share pack</button><span role="status">{status}</span></>;
}
