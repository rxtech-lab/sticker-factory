"use client";

import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { recordPageView } from "@/lib/analytics/client";

export function WebAnalytics() {
  const pathname = usePathname();
  useEffect(() => { recordPageView(pathname); }, [pathname]);
  return null;
}
