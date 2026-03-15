/**
 * Shared TypeScript types for the OpenAI-compatible bridge.
 *
 * These mirror the OpenAI Chat Completion API shapes used by clients
 * (e.g. Presenton) when talking to the bridge.
 */

// ---------------------------------------------------------------------------
// Tool-related types
// ---------------------------------------------------------------------------

export interface ToolCall {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
}

export interface Tool {
  type: "function";
  function: {
    name: string;
    description?: string;
    parameters?: Record<string, unknown>;
  };
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

export interface OpenAIMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  name?: string;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
}

// ---------------------------------------------------------------------------
// Request / Response shapes
// ---------------------------------------------------------------------------

export interface OpenAIChatCompletionRequest {
  model: string;
  messages: OpenAIMessage[];
  stream?: boolean;
  tools?: Tool[];
  max_completion_tokens?: number;
  temperature?: number;
  top_p?: number;
}

export interface OpenAIChatCompletionResponse {
  id: string;
  object: "chat.completion";
  created: number;
  model: string;
  choices: Array<{
    index: number;
    message: {
      role: "assistant";
      content: string | null;
      tool_calls?: ToolCall[];
    };
    finish_reason: "stop" | "length" | "content_filter" | "tool_calls";
  }>;
  usage: null;
}

// ---------------------------------------------------------------------------
// Streaming chunk shape
// ---------------------------------------------------------------------------

export interface OpenAIChatCompletionStreamChunk {
  id: string;
  object: "chat.completion.chunk";
  created: number;
  model: string;
  choices: Array<{
    index: number;
    delta: {
      role?: "assistant";
      content?: string | null;
      tool_calls?: Array<{
        index: number;
        id?: string;
        type?: "function";
        function?: { name?: string; arguments?: string };
      }>;
    };
    finish_reason:
      | "stop"
      | "length"
      | "content_filter"
      | "tool_calls"
      | null;
  }>;
}
