/**
 * POST /v1/chat/completions — non-streaming chat completion handler.
 *
 * Session-per-request flow: creates an ACP session, sends the converted
 * messages as a prompt, collects the response, and tears down the session.
 */

import type {
  OpenAIChatCompletionRequest,
  OpenAIChatCompletionResponse,
} from "../types.js";
import { convertMessages } from "../convert.js";
import {
  createSession,
  sendPrompt,
  destroySession,
} from "../copilot.js";
import { isModelAvailable } from "./models.js";

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------

function errorResponse(
  status: number,
  message: string,
  type: string = "invalid_request_error",
): Response {
  return Response.json(
    { error: { message, type, code: null } },
    { status },
  );
}

// ---------------------------------------------------------------------------
// handleChatCompletion
// ---------------------------------------------------------------------------

/**
 * Handle POST /v1/chat/completions — non-streaming only.
 *
 * 1. Parses + validates the request body
 * 2. Creates an ACP session
 * 3. Converts messages → ContentBlocks and sends prompt
 * 4. Returns an OpenAI-shaped response
 * 5. Destroys the session in a finally block
 */
export async function handleChatCompletion(req: Request): Promise<Response> {
  // --- Parse body -----------------------------------------------------------

  let body: OpenAIChatCompletionRequest;
  try {
    body = (await req.json()) as OpenAIChatCompletionRequest;
  } catch {
    return errorResponse(400, "Invalid JSON in request body");
  }

  // --- Validate fields ------------------------------------------------------

  if (!body.model || typeof body.model !== "string") {
    return errorResponse(400, "'model' is required and must be a string");
  }

  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return errorResponse(400, "'messages' is required and must be a non-empty array");
  }

  // --- Streaming not supported ----------------------------------------------

  if (body.stream === true) {
    return errorResponse(501, "Streaming not yet implemented", "not_implemented");
  }

  // --- Model validation -----------------------------------------------------

  if (!isModelAvailable(body.model)) {
    return errorResponse(
      400,
      `Model '${body.model}' is not available. Use GET /v1/models to list available models.`,
    );
  }

  // --- Session-per-request lifecycle ----------------------------------------

  let sessionId: string | undefined;

  try {
    const session = await createSession();
    sessionId = session.sessionId;

    const contentBlocks = convertMessages(body.messages);
    const { content, finishReason } = await sendPrompt(sessionId, contentBlocks);

    const response: OpenAIChatCompletionResponse = {
      id: `chatcmpl-${crypto.randomUUID()}`,
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model: body.model,
      choices: [
        {
          index: 0,
          message: { role: "assistant", content },
          finish_reason: finishReason as OpenAIChatCompletionResponse["choices"][0]["finish_reason"],
        },
      ],
      usage: null,
    };

    return Response.json(response);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[chat] Error processing completion: ${msg}`);
    return errorResponse(500, `Internal error: ${msg}`, "server_error");
  } finally {
    if (sessionId) {
      await destroySession(sessionId);
    }
  }
}
