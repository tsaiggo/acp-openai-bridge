/**
 * POST /v1/chat/completions — chat completion handler (streaming & non-streaming).
 *
 * Session-per-request flow: creates an ACP session, sends the converted
 * messages as a prompt, collects the response, and tears down the session.
 */

import type {
  OpenAIChatCompletionRequest,
  OpenAIChatCompletionResponse,
  OpenAIChatCompletionStreamChunk,
} from "../types.js";
import { convertMessages } from "../convert.js";
import {
  createSession,
  sendPrompt,
  streamPrompt,
  destroySession,
} from "../copilot.js";
import { isModelAvailable } from "./models.js";
import { badRequest, internalError } from "../errors.js";
import { formatSSEChunk, formatSSEDone } from "../sse.js";

// ---------------------------------------------------------------------------
// handleChatCompletion
// ---------------------------------------------------------------------------

/**
 * Handle POST /v1/chat/completions.
 *
 * 1. Parses + validates the request body
 * 2. Routes to streaming or non-streaming handler
 * 3. Creates an ACP session, sends prompt, returns response
 * 4. Destroys the session in a finally block
 */
export async function handleChatCompletion(req: Request): Promise<Response> {
  // --- Parse body -----------------------------------------------------------

  let body: OpenAIChatCompletionRequest;
  try {
    body = (await req.json()) as OpenAIChatCompletionRequest;
  } catch {
    return badRequest("Invalid JSON in request body");
  }

  // --- Validate fields ------------------------------------------------------

  if (!body.model || typeof body.model !== "string") {
    return badRequest("'model' is required and must be a string", "model");
  }

  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return badRequest("'messages' is required and must be a non-empty array", "messages");
  }

  // --- Streaming -------------------------------------------------------------

  if (body.stream === true) {
    return handleStreamingCompletion(body);
  }

  // --- Model validation -----------------------------------------------------

  if (!isModelAvailable(body.model)) {
    return badRequest(
      `Model '${body.model}' is not available. Use GET /v1/models to list available models.`,
      "model",
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
    return internalError(`Internal error: ${msg}`);
  } finally {
    if (sessionId) {
      await destroySession(sessionId);
    }
  }
}

// ---------------------------------------------------------------------------
// handleStreamingCompletion
// ---------------------------------------------------------------------------

async function handleStreamingCompletion(
  body: OpenAIChatCompletionRequest,
): Promise<Response> {
  if (!isModelAvailable(body.model)) {
    return badRequest(
      `Model '${body.model}' is not available. Use GET /v1/models to list available models.`,
      "model",
    );
  }

  let sessionId: string | undefined;

  try {
    const session = await createSession();
    sessionId = session.sessionId;

    const contentBlocks = convertMessages(body.messages);
    const completionId = `chatcmpl-${crypto.randomUUID()}`;
    const created = Math.floor(Date.now() / 1000);

    const stream = new ReadableStream({
      async start(controller) {
        const encoder = new TextEncoder();

        const roleChunk: OpenAIChatCompletionStreamChunk = {
          id: completionId,
          object: "chat.completion.chunk",
          created,
          model: body.model,
          choices: [{
            index: 0,
            delta: { role: "assistant" },
            finish_reason: null,
          }],
        };
        controller.enqueue(encoder.encode(formatSSEChunk(roleChunk)));

        try {
          const { finishReason } = await streamPrompt(
            sessionId!,
            contentBlocks,
            (text: string) => {
              const contentChunk: OpenAIChatCompletionStreamChunk = {
                id: completionId,
                object: "chat.completion.chunk",
                created,
                model: body.model,
                choices: [{
                  index: 0,
                  delta: { content: text },
                  finish_reason: null,
                }],
              };
              controller.enqueue(encoder.encode(formatSSEChunk(contentChunk)));
            },
          );

          const finalChunk: OpenAIChatCompletionStreamChunk = {
            id: completionId,
            object: "chat.completion.chunk",
            created,
            model: body.model,
            choices: [{
              index: 0,
              delta: {},
              finish_reason: finishReason as "stop" | "length" | "content_filter" | "tool_calls",
            }],
          };
          controller.enqueue(encoder.encode(formatSSEChunk(finalChunk)));
          controller.enqueue(encoder.encode(formatSSEDone()));
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          console.error(`[chat] Stream error: ${msg}`);
          const errData = { error: { message: msg, type: "server_error" } };
          controller.enqueue(encoder.encode(formatSSEChunk(errData)));
          controller.enqueue(encoder.encode(formatSSEDone()));
        } finally {
          if (sessionId) {
            await destroySession(sessionId);
          }
          controller.close();
        }
      },
    });

    return new Response(stream, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
      },
    });
  } catch (err: unknown) {
    if (sessionId) {
      await destroySession(sessionId);
    }
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[chat] Error starting stream: ${msg}`);
    return internalError(`Internal error: ${msg}`);
  }
}
