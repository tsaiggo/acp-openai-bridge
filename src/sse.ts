/**
 * SSE (Server-Sent Events) formatting helpers.
 *
 * Used by the streaming chat completion handler to format
 * chunks according to the SSE wire protocol.
 */

/** Format a data object as an SSE chunk: `data: {json}\n\n` */
export function formatSSEChunk(data: object): string {
  return `data: ${JSON.stringify(data)}\n\n`;
}

/** Format the SSE termination signal: `data: [DONE]\n\n` */
export function formatSSEDone(): string {
  return "data: [DONE]\n\n";
}
