/**
 * Copilot ACP subprocess lifecycle manager.
 *
 * Spawns `copilot --acp --stdio` as a child process, connects via the ACP SDK,
 * and exposes a simple API for the bridge to interact with Copilot.
 *
 * Lifecycle: startCopilot() → createSession() → sendPrompt() → destroySession() → stopCopilot()
 */

import { spawn, type ChildProcess } from "node:child_process";
import { Readable, Writable } from "node:stream";
import {
  ClientSideConnection,
  PROTOCOL_VERSION,
  ndJsonStream,
  type Client,
  type Agent,
  type SessionNotification,
  type RequestPermissionRequest,
  type RequestPermissionResponse,
  type ContentBlock,
  type StopReason,
} from "@agentclientprotocol/sdk";

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let copilotProcess: ChildProcess | null = null;
let connection: ClientSideConnection | null = null;
let status: "connected" | "disconnected" | "starting" = "disconnected";

// Accumulated text per session during prompt processing
const sessionTextBuffers = new Map<string, string>();

// ---------------------------------------------------------------------------
// stopReason → OpenAI finish_reason mapping
// ---------------------------------------------------------------------------

export function mapStopReason(
  stopReason: StopReason
): "stop" | "length" | "content_filter" {
  switch (stopReason) {
    case "end_turn":
      return "stop";
    case "max_tokens":
      return "length";
    case "refusal":
      return "content_filter";
    case "cancelled":
      return "stop";
    case "max_turn_requests":
      return "stop";
    default:
      return "stop";
  }
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

export function getCopilotStatus(): "connected" | "disconnected" | "starting" {
  return status;
}

// ---------------------------------------------------------------------------
// startCopilot
// ---------------------------------------------------------------------------

export async function startCopilot(): Promise<void> {
  if (status === "connected" && connection) {
    console.log("[copilot] Already connected");
    return;
  }

  status = "starting";
  console.log("[copilot] Spawning copilot --acp --stdio ...");

  const executable = process.env.COPILOT_CLI_PATH ?? "copilot";

  const proc = spawn(executable, ["--acp", "--stdio"], {
    stdio: ["pipe", "pipe", "inherit"],
  });

  if (!proc.stdin || !proc.stdout) {
    status = "disconnected";
    throw new Error("Failed to start Copilot ACP process with piped stdio.");
  }

  copilotProcess = proc;

  // Detect subprocess crash
  proc.on("exit", (code, signal) => {
    console.error(
      `[copilot] Process exited: code=${code}, signal=${signal}`
    );
    status = "disconnected";
    connection = null;
    copilotProcess = null;
  });

  proc.on("error", (err) => {
    console.error(`[copilot] Process error: ${err.message}`);
    status = "disconnected";
    connection = null;
    copilotProcess = null;
  });

  // Create ACP streams (NDJSON over stdio)
  const output = Writable.toWeb(
    proc.stdin
  ) as WritableStream<Uint8Array>;
  const input = Readable.toWeb(
    proc.stdout
  ) as ReadableStream<Uint8Array>;
  const stream = ndJsonStream(output, input);

  // The Client factory — handles incoming requests from the agent
  const clientFactory = (_agent: Agent): Client => ({
    async requestPermission(
      _params: RequestPermissionRequest
    ): Promise<RequestPermissionResponse> {
      // Refuse all permission requests — we're a headless bridge
      console.log("[copilot] Permission requested — refusing (cancelled)");
      return { outcome: { outcome: "cancelled" } };
    },

    async sessionUpdate(params: SessionNotification): Promise<void> {
      const update = params.update;

      if (
        update.sessionUpdate === "agent_message_chunk" &&
        update.content.type === "text"
      ) {
        // Accumulate text for the session
        const existing = sessionTextBuffers.get(params.sessionId) ?? "";
        sessionTextBuffers.set(
          params.sessionId,
          existing + update.content.text
        );
      }
      // We silently consume all other update types (tool_call, plan, etc.)
    },
  });

  connection = new ClientSideConnection(clientFactory, stream);

  // Initialize handshake
  console.log("[copilot] Sending initialize ...");
  const initResult = await connection.initialize({
    protocolVersion: PROTOCOL_VERSION,
    clientInfo: { name: "acp-openai-bridge", version: "0.1.0" },
    clientCapabilities: {},
  });

  console.log(
    `[copilot] Initialized: protocol=${initResult.protocolVersion}, agent=${initResult.agentInfo?.name ?? "unknown"} v${initResult.agentInfo?.version ?? "?"}`
  );

  status = "connected";
}

// ---------------------------------------------------------------------------
// createSession
// ---------------------------------------------------------------------------

export async function createSession(): Promise<{
  sessionId: string;
  models: string[];
}> {
  if (!connection || status !== "connected") {
    throw new Error("Copilot not connected. Call startCopilot() first.");
  }

  const result = await connection.newSession({
    cwd: process.cwd(),
    mcpServers: [],
  });

  console.log(`[copilot] Session created: ${result.sessionId}`);

  // Extract model IDs from the models field (ACP unstable capability)
  const models = (result.models?.availableModels ?? []).map((m) => m.modelId);
  console.log(`[copilot] Available models: ${models.join(", ") || "(none)"}`);

  return { sessionId: result.sessionId, models };
}

// ---------------------------------------------------------------------------
// sendPrompt
// ---------------------------------------------------------------------------

export async function sendPrompt(
  sessionId: string,
  contentBlocks: ContentBlock[]
): Promise<{ content: string; finishReason: string }> {
  if (!connection || status !== "connected") {
    throw new Error("Copilot not connected. Call startCopilot() first.");
  }

  // Clear any previous accumulated text for this session
  sessionTextBuffers.set(sessionId, "");

  console.log(`[copilot] Sending prompt to session ${sessionId} ...`);

  // connection.prompt() blocks until the agent finishes the turn.
  // During processing, session/update notifications arrive via sessionUpdate callback
  // which accumulates text in sessionTextBuffers.
  const promptResult = await connection.prompt({
    sessionId,
    prompt: contentBlocks,
  });

  const content = sessionTextBuffers.get(sessionId) ?? "";
  const finishReason = mapStopReason(promptResult.stopReason);

  console.log(
    `[copilot] Prompt complete: stopReason=${promptResult.stopReason} → finishReason=${finishReason}, chars=${content.length}`
  );

  // Clean up buffer
  sessionTextBuffers.delete(sessionId);

  return { content, finishReason };
}

// ---------------------------------------------------------------------------
// destroySession
// ---------------------------------------------------------------------------

export async function destroySession(sessionId: string): Promise<void> {
  if (!connection || status !== "connected") {
    console.warn("[copilot] Not connected — skipping destroySession");
    return;
  }

  try {
    // ACP spec has session/close as an unstable capability.
    // Try it; if the agent doesn't support it, just log and move on.
    await connection.unstable_closeSession({ sessionId });
    console.log(`[copilot] Session ${sessionId} destroyed`);
  } catch (err: unknown) {
    // If session/close is not supported, that's OK — session is ephemeral
    const msg = err instanceof Error ? err.message : String(err);
    console.log(
      `[copilot] session/close not supported or failed: ${msg} — session will expire with process`
    );
  }

  sessionTextBuffers.delete(sessionId);
}

// ---------------------------------------------------------------------------
// stopCopilot
// ---------------------------------------------------------------------------

export function stopCopilot(): void {
  if (copilotProcess) {
    console.log("[copilot] Killing copilot process ...");
    try {
      copilotProcess.stdin?.end();
    } catch {
      // ignore
    }
    copilotProcess.kill("SIGTERM");
    copilotProcess = null;
  }

  connection = null;
  status = "disconnected";
  sessionTextBuffers.clear();
  console.log("[copilot] Stopped");
}

// ---------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------

function onShutdown(signal: string) {
  console.log(`[copilot] Received ${signal} — shutting down`);
  stopCopilot();
}

process.on("SIGINT", () => onShutdown("SIGINT"));
process.on("SIGTERM", () => onShutdown("SIGTERM"));
