/**
 * GET /v1/models — returns cached models in OpenAI-compatible format.
 *
 * Model list is populated on server boot via Copilot session discovery.
 * If discovery hasn't completed yet, returns an empty list.
 */

// ---------------------------------------------------------------------------
// Cached model state (populated by index.ts on boot)
// ---------------------------------------------------------------------------

interface OpenAIModel {
  id: string;
  object: "model";
  created: number;
  owned_by: string;
}

let cachedModels: OpenAIModel[] = [];

/**
 * Replace the cached model list. Called once during boot after model discovery.
 */
export function setCachedModels(modelIds: string[]): void {
  const created = Math.floor(Date.now() / 1000);
  cachedModels = modelIds.map((id) => ({
    id,
    object: "model" as const,
    created,
    owned_by: "github-copilot",
  }));
  console.log(`[models] Cached ${cachedModels.length} models`);
}

/**
 * Check whether a model ID exists in the cached model list.
 */
export function isModelAvailable(modelId: string): boolean {
  return cachedModels.some((m) => m.id === modelId);
}

/**
 * Handle GET /v1/models — returns OpenAI-compatible model list.
 */
export function handleModels(): Response {
  return Response.json({
    object: "list",
    data: cachedModels,
  });
}
