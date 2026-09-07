import type { Instrumentation } from "next";
import { sendServerEvent } from "@/lib/analytics/server";

export const onRequestError: Instrumentation.onRequestError = async (_error, request, context) => {
  await sendServerEvent("server_error", { path: context.routePath, method: request.method, status: 500 });
};
