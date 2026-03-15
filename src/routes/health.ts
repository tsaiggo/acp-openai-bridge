/**
 * GET /v1/health — returns bridge + Copilot connectivity status.
 */

import { getCopilotStatus } from "../copilot.js";

/**
 * Handle GET /v1/health — reports whether Copilot is connected.
 */
export function handleHealth(): Response {
  const copilotStatus = getCopilotStatus();
  const connected = copilotStatus === "connected";

  return Response.json(
    {
      status: connected ? "ok" : "error",
      copilot: connected ? "connected" : "disconnected",
    },
    { status: connected ? 200 : 503 },
  );
}
