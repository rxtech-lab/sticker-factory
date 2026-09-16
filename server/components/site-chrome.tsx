"use client";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
export function SiteChrome({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  return pathname === "/tutorial" || pathname.startsWith("/tutorial/") ? null : children;
}
