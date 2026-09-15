import type { NextFetchEvent, NextRequest } from "next/server";
import { NextResponse } from "next/server";
import { proxy as authProxy } from "@/lib/auth/web";

export default function proxy(request: NextRequest, event: NextFetchEvent) {
  if (process.env.NODE_ENV !== "production" && process.env.STICKER_FACTORY_E2E === "true") {
    return NextResponse.next();
  }
  return authProxy(request, event);
}

export const config = {
  matcher: [
    "/((?!privacy(?:/|$)|share/ios(?:/|$)|.well-known/apple-app-site-association|api/auth|api/v1|api/cron|_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt|.well-known/workflow/|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
