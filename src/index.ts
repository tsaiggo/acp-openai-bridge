/**
 * acp-openai-bridge — HTTP server entry point.
 *
 * On boot: starts Copilot, discovers models via a throwaway session,
 * then serves OpenAI-compatible endpoints.
 */

import { startCopilot, createSession, destroySession } from "./copilot.js";
import { setCachedModels, handleModels } from "./routes/models.js";
import { handleHealth } from "./routes/health.js";

// ---------------------------------------------------------------------------
// CORS headers applied to every response
// ---------------------------------------------------------------------------

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

/** Attach CORS headers to a Response. */
function withCors(res: Response): Response {
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    res.headers.set(key, value);
  }
  return res;
}

// ---------------------------------------------------------------------------
// Model discovery (runs once on boot)
// ---------------------------------------------------------------------------

async function discoverModels(): Promise<void> {
  console.log("[boot] Starting Copilot and discovering models ...");

  try {
    await startCopilot();

    const { sessionId, models } = await createSession();
    setCachedModels(models);

    // Clean up the discovery session
    await destroySession(sessionId);

    console.log(`[boot] Model discovery complete — ${models.length} models cached`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[boot] Model discovery failed: ${msg}`);
    console.error("[boot] Server will run, but /v1/models will be empty and /v1/health will report disconnected");
  }
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

const server = Bun.serve({
  port: 4000,
  fetch(req: Request): Response {
    const url = new URL(req.url);
    const { pathname } = url;

    // Handle CORS preflight
    if (req.method === "OPTIONS") {
      return withCors(new Response(null, { status: 204 }));
    }

    // Route: GET /v1/models
    if (req.method === "GET" && pathname === "/v1/models") {
      return withCors(handleModels());
    }

    // Route: GET /v1/health
    if (req.method === "GET" && pathname === "/v1/health") {
      return withCors(handleHealth());
    }

    // 404 — unknown route
    return withCors(
      Response.json(
        {
          error: {
            message: `Not found: ${req.method} ${pathname}`,
            type: "not_found_error",
            code: 404,
          },
        },
        { status: 404 },
      ),
    );
  },
});

console.log(`acp-openai-bridge listening on http://localhost:${server.port}`);

// Start Copilot + model discovery in the background (don't block server startup)
discoverModels();
