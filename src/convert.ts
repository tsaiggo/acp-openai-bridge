/**
 * Message converter — transforms OpenAI Chat Completion messages into
 * ACP ContentBlock arrays suitable for `sendPrompt()`.
 *
 * Because the ACP/Copilot protocol is single-turn, we encode the full
 * conversation history as structured text within a single ContentBlock.
 */

import type { ContentBlock } from "@agentclientprotocol/sdk";
import type { OpenAIMessage } from "./types.js";

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
// convertMessages
// ---------------------------------------------------------------------------

/**
 * Convert an array of OpenAI messages into ACP ContentBlock[].
 *
 * Produces a single text ContentBlock whose `text` field encodes the full
 * conversation using labeled sections:
 *
 * ```
 * [System]
 * You are a helpful assistant.
 *
 * [User]
 * Hello!
 * ```
 *
 * @param messages - OpenAI Chat Completion messages array.
 * @returns A single-element ContentBlock array with type "text".
 * @throws {Error} If `messages` is empty.
 * @throws {Error} If no message with role "user" is present.
 */
export function convertMessages(messages: OpenAIMessage[]): ContentBlock[] {
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

  for (const msg of messages) {
    const content = msg.content ?? "";

    if (msg.role === "tool") {
      // Tool results include the tool_call_id for context
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
