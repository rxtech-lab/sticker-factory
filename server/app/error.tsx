"use client";

import { useEffect } from "react";
import { recordBrowserError } from "@/lib/analytics/client";

export default function ErrorPage({ error, retry }: { error: Error & { digest?: string }; retry: () => void }) {
  useEffect(() => { recordBrowserError(error); }, [error]);
  return <main className="shell"><h1>Something went wrong</h1><p>Please try again.</p><button onClick={retry}>Try again</button></main>;
}
