# Configuring other providers

The template wires up Anthropic by default — see [setup-windows.md](setup-windows.md#the-api-key)
for the `remoteEnv` mechanism and how to set the key on each platform. Everything below
follows the same two mechanisms, just for other providers:

- **API-key providers** (OpenRouter, OpenAI, Gemini, …) — one more `remoteEnv` line in
  `devcontainer.json`.
- **Self-hosted or proxied endpoints** (a corporate proxy, Ollama, vLLM, a custom base URL)
  — a `models.json` in the personal layer.

Both files live in your own project's `.devcontainer/` (copied there by `init-project.sh`) or
your personal layer at `~/.pi/devcontainer/`, so edit them freely — this repository's copies
are only the starting point.

## OpenRouter

Add the key to `remoteEnv` in `devcontainer.json`, next to the Anthropic one:

```jsonc
"remoteEnv": {
  "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}",
  "OPENROUTER_API_KEY": "${localEnv:OPENROUTER_API_KEY}"
}
```

Set the environment variable the same way as `ANTHROPIC_API_KEY` — `setx OPENROUTER_API_KEY
sk-or-...` on Windows (full VS Code restart required, see setup-windows.md), `export` from
your shell profile on Linux/macOS. pi picks it up automatically; no further configuration is
needed.

## Other API-key providers

Every provider that authenticates through a single environment variable follows the same
pattern: add it to `remoteEnv`, set it on the host. The full list of variable names (OpenAI,
Gemini, Mistral, Groq, Azure, Bedrock, and more) is in pi's own provider reference —
[pi.dev/docs/providers](https://pi.dev/docs/providers), or the `envMap` in
[`packages/ai/src/env-api-keys.ts`](https://github.com/earendil-works/pi-mono/blob/main/packages/ai/src/env-api-keys.ts).

Only the variables you actually add to `remoteEnv` reach the container — an unused entry
resolves to an empty string and is otherwise harmless.

## Third-party or self-hosted base URLs

For a proxy in front of an existing provider, or a fully custom OpenAI/Anthropic-compatible
endpoint (Ollama, vLLM, LM Studio, a corporate gateway), pi reads
`~/.pi/agent/models.json` — see pi's [pi.dev/docs/models](https://pi.dev/docs/models) for the
full format. This template's personal layer copies that file the same way it already copies
`settings.json`: drop a `models.json` next to it in `~/.pi/devcontainer/` and it lands at
`~/.pi/agent/models.json` on the next container create.

Route the built-in Anthropic provider through a proxy:

```json
{
  "providers": {
    "anthropic": {
      "baseUrl": "https://my-proxy.example.com/v1"
    }
  }
}
```

Add a fully custom OpenAI-compatible endpoint:

```json
{
  "providers": {
    "my-server": {
      "baseUrl": "http://my-inference-server:8000/v1",
      "api": "openai-completions",
      "apiKey": "$MY_SERVER_API_KEY",
      "models": [{ "id": "my-model" }]
    }
  }
}
```

If the endpoint takes its own API key via an environment variable (as in the example above),
add that variable to `remoteEnv` too, the same way as `ANTHROPIC_API_KEY`.

## Which mechanism for which provider

| Provider needs | Mechanism | Example |
|---|---|---|
| Just an API key | `remoteEnv` in `devcontainer.json` | Anthropic, OpenRouter, OpenAI |
| A different base URL, same API shape | `models.json` `baseUrl` override | corporate proxy in front of Anthropic |
| A new provider entirely | `models.json` with `baseUrl`, `api`, `models` | Ollama, vLLM, a custom gateway |
