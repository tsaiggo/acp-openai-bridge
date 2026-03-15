/**
 * Centralized OpenAI-compatible error response factories.
 *
 * Every error returned by the bridge follows the standard shape:
 * { error: { message, type, param, code } }
 */

/** Generic OpenAI-shaped error response */
export function errorResponse(
  status: number,
  message: string,
  type: string,
  param: string | null = null,
  code: string | null = null,
): Response {
  return Response.json(
    { error: { message, type, param, code } },
    { status },
  );
}

/** 400 — invalid request */
export function badRequest(message: string, param: string | null = null): Response {
  return errorResponse(400, message, "invalid_request_error", param);
}

/** 404 — not found */
export function notFound(message: string): Response {
  return errorResponse(404, message, "not_found_error");
}

/** 500 — internal server error */
export function internalError(message: string): Response {
  return errorResponse(500, message, "server_error");
}

/** 501 — not implemented */
export function notImplemented(message: string): Response {
  return errorResponse(501, message, "not_implemented");
}

/** 503 — service unavailable */
export function serviceUnavailable(message: string): Response {
  return errorResponse(503, message, "service_unavailable");
}
