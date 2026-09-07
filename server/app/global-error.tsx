"use client";

import ErrorPage from "./error";

export default function GlobalError(props: Parameters<typeof ErrorPage>[0]) {
  return <html lang="en"><body><ErrorPage {...props} /></body></html>;
}
