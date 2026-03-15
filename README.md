# acp-openai-bridge

Exposes GitHub Copilot's language models as a local OpenAI-compatible API server, enabling any tool that speaks the OpenAI protocol to use Copilot models.

## Prerequisites

- [Bun](https://bun.sh/) v1.3+
- GitHub Copilot CLI (`gh copilot`) — authenticated and working
- The `copilot` command available (provided by the `@anthropic/copilot-mcp` or `@agentclientprotocol/sdk` toolchain)
- `curl` and `jq` (for test scripts)

## Quick Start

```bash
bun install
bun run start
```

The server starts on `http://localhost:4000`. It connects to Copilot on boot, discovers available models, then serves requests.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/v1/health` | Health check — returns `{"status":"ok","copilot":"connected"}` |
| `GET` | `/v1/models` | List available models (OpenAI-compatible format) |
| `POST` | `/v1/chat/completions` | Chat completion — supports streaming (`stream: true`) and tool calls |
| `OPTIONS` | `*` | CORS preflight |

## Usage with OpenAI SDK

Any OpenAI-compatible client works. Point it at `http://localhost:4000/v1`:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:4000/v1", api_key="dummy")

# List models
models = client.models.list()

# Chat
response = client.chat.completions.create(
    model="claude-sonnet-4",
    messages=[{"role": "user", "content": "hello"}],
)
print(response.choices[0].message.content)

# Streaming
stream = client.chat.completions.create(
    model="claude-sonnet-4",
    messages=[{"role": "user", "content": "count to 3"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="")
```

## Presenton Integration

To use this bridge as the LLM backend for [Presenton](https://github.com/nicepkg/presenton):

1. Start the bridge: `bun run start`
2. Configure Presenton's environment:

```bash
LLM_PROVIDER=custom
CUSTOM_LLM_URL=http://localhost:4000/v1
CUSTOM_LLM_API_KEY=dummy
CUSTOM_MODEL=claude-sonnet-4
```

Presenton will send requests to the bridge, which forwards them to Copilot and returns OpenAI-formatted responses.

## Development

```bash
# Dev mode with auto-reload
bun run dev

# Run test suites
bun run test              # Full QA suite (v3 — includes all regressions)
bun run test:v0           # Health, models, 404 handling
bun run test:v1           # Chat completions (non-streaming + streaming)
bun run test:v2           # Regressions (v0 + v1 combined)
bun run test:v3           # Tool calls + all regressions
bun run test:integration  # OpenAI Python SDK end-to-end test
```
