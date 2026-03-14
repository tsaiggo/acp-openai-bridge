const server = Bun.serve({
  port: 4000,
  fetch(_req: Request): Response {
    return Response.json({
      status: "ok",
      message: "acp-openai-bridge",
    });
  },
});

console.log(`acp-openai-bridge listening on http://localhost:${server.port}`);
