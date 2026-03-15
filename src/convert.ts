/**
 * Message converter — transforms OpenAI Chat Completion messages into
 * ACP ContentBlock arrays suitable for `sendPrompt()`.
 *
 * Because the ACP/Copilot protocol is single-turn, we encode the full
 * conversation history as structured text within a single ContentBlock.
 * When the request includes `tools`, their definitions are encoded as
 * structured text prepended to the conversation.
 */

import type { ContentBlock } from "@agentclientprotocol/sdk";
import type { OpenAIMessage, Tool, ToolCall } from "./types.js";

// ---------------------------------------------------------------------------
// Role → label mapping
// ---------------------------------------------------------------------------

const ROLE_LABELS: Record<OpenAIMessage["role"], string> = {
  system: "System",
  user: "User",
  assistant: "Assistant",
  tool: "Tool Result",
};

// ---------------------------------------------------------------------------
// convertTools
// ---------------------------------------------------------------------------

/**
 * Encode an array of OpenAI tool definitions as structured text.
 *
 * Since ACP is single-turn text, we describe available functions in a
 * human-readable format that the model can reason about.
 *
 * @param tools - OpenAI tool definitions (function-type only).
 * @returns A text block describing the available tools, or empty string if none.
 */
export function convertTools(tools: Tool[]): string {
  if (tools.length === 0) return "";

  let text = "[Available Tools]\n";

  for (const tool of tools) {
    if (tool.type !== "function") continue;

    const fn = tool.function;
    text += `- ${fn.name}`;
    if (fn.description) {
      text += `: ${fn.description}`;
    }
    text += "\n";

    if (fn.parameters && Object.keys(fn.parameters).length > 0) {
      text += `  Parameters: ${JSON.stringify(fn.parameters)}\n`;
    }
  }

  text += "\n";
  return text;
}

// ---------------------------------------------------------------------------
// parseToolCalls
// ---------------------------------------------------------------------------

/**
 * Attempt to extract tool call intentions from the model's text response.
 *
 * Models may respond with structured JSON when they want to invoke a tool.
 * This parser looks for a known pattern — a JSON array of function calls
 * wrapped in a fenced code block or bare JSON.
 *
 * Expected patterns:
 * ```json
 * [{"name": "fn_name", "arguments": {...}}]
 * ```
 *
 * @param text - The raw text response from the model.
 * @returns Parsed ToolCall array, or null if no tool calls detected.
 */
export function parseToolCalls(text: string): ToolCall[] | null {
  const fencedMatch = text.match(
    /```(?:json)?\s*\n?\s*(\[[\s\S]*?\])\s*\n?\s*```/
  );
  const jsonSource = fencedMatch ? fencedMatch[1] : null;

  const bareMatch = !jsonSource
    ? text.match(/^\s*(\[[\s\S]*\])\s*$/)
    : null;
  const source = jsonSource ?? bareMatch?.[1] ?? null;

  if (!source) return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(source);
  } catch {
    return null;
  }

  if (!Array.isArray(parsed)) return null;

  const toolCalls: ToolCall[] = [];

  for (const item of parsed) {
    if (
      typeof item === "object" &&
      item !== null &&
      typeof item.name === "string"
    ) {
      toolCalls.push({
        id: `call_${crypto.randomUUID().replace(/-/g, "").slice(0, 24)}`,
        type: "function",
        function: {
          name: item.name,
          arguments:
            typeof item.arguments === "string"
              ? item.arguments
              : JSON.stringify(item.arguments ?? {}),
        },
      });
    }
  }

  return toolCalls.length > 0 ? toolCalls : null;
}

// ---------------------------------------------------------------------------
// convertMessages
// ---------------------------------------------------------------------------

/**
 * Convert an array of OpenAI messages into ACP ContentBlock[].
 *
 * Produces a single text ContentBlock whose `text` field encodes the full
 * conversation using labeled sections. When `tools` are provided, their
 * definitions are prepended as an `[Available Tools]` block.
 *
 * @param messages - OpenAI Chat Completion messages array.
 * @param tools - Optional tool definitions to prepend to the prompt.
 * @returns A single-element ContentBlock array with type "text".
 * @throws {Error} If `messages` is empty.
 * @throws {Error} If no message with role "user" is present.
 */
export function convertMessages(
  messages: OpenAIMessage[],
  tools?: Tool[],
): ContentBlock[] {
  if (messages.length === 0) {
    throw new Error(
      "Cannot convert empty messages array. At least one user message is required."
    );
  }

  const hasUserMessage = messages.some((m) => m.role === "user");
  if (!hasUserMessage) {
    throw new Error(
      "Messages array must contain at least one message with role \"user\"."
    );
  }

  let text = "";

  if (tools && tools.length > 0) {
    text += convertTools(tools);
  }

  for (const msg of messages) {
    const content = msg.content ?? "";

    if (msg.role === "tool") {
      const callId = msg.tool_call_id ?? "unknown";
      text += `[Tool Result for ${callId}]\n${content}\n\n`;
    } else {
      const label = ROLE_LABELS[msg.role];
      text += `[${label}]\n${content}\n\n`;
    }
  }

  return [{ type: "text", text }];
}

// ---------------------------------------------------------------------------
// convertModel
// ---------------------------------------------------------------------------

/**
 * Map an OpenAI model ID to the corresponding Copilot model ID.
 *
 * Currently a 1:1 passthrough — the client sends the exact model ID
 * that Copilot advertised via `/v1/models`.
 *
 * @param modelId - The model ID from the OpenAI request.
 * @returns The same model ID (passthrough).
 */
export function convertModel(modelId: string): string {
  return modelId;
}
