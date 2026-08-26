"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";

export function FullscreenPreview({
  children,
  fullScreenChildren,
  label,
}: {
  children: ReactNode;
  fullScreenChildren?: ReactNode;
  label: string;
}) {
  const [expanded, setExpanded] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!expanded) return;
    const previousOverflow = document.body.style.overflow;
    const trigger = triggerRef.current;
    document.body.style.overflow = "hidden";
    closeRef.current?.focus();
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setExpanded(false);
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      document.body.style.overflow = previousOverflow;
      window.removeEventListener("keydown", closeOnEscape);
      trigger?.focus();
    };
  }, [expanded]);

  return <>
    <button
      aria-label={`Open ${label} full screen`}
      className="fullscreen-preview-trigger"
      onClick={() => setExpanded(true)}
      ref={triggerRef}
      type="button"
    >
      {children}
      <span aria-hidden="true" className="fullscreen-preview-icon">↗</span>
    </button>
    {expanded && createPortal(
      <div aria-label={`${label} full-screen player`} aria-modal="true" className="fullscreen-preview-overlay" role="dialog">
        <div className="fullscreen-preview-content">{fullScreenChildren ?? children}</div>
        <button
          aria-label="Close full-screen player"
          className="fullscreen-preview-close"
          onClick={() => setExpanded(false)}
          ref={closeRef}
          type="button"
        >×</button>
      </div>,
      document.body,
    )}
  </>;
}
