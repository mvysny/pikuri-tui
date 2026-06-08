# pikuri-tui

[![status](https://ci.codeberg.org/api/badges/17231/status.svg)](https://ci.codeberg.org/repos/17231)

Terminal UI front-ends for [pikuri](https://codeberg.org/mvysny/pikuri) — a Ruby LLM agent framework.

Two shells:

- **`pikuri-tui-chat`** — general-purpose chat with web search and calculator tools.
- **`pikuri-tui-code`** *(planned)* — in-repo coding agent.

Pikuri owns the agent loop, tool execution, and LLM transport. This project owns nothing but the TUI shell: a conversation pane, a diagnostic log pane, an input field, and a status bar.

## Prerequisites

- Ruby ≥ 3.4
- A local LLM server (e.g. [llama.cpp](https://github.com/ggerganov/llama.cpp) `server`)

## Install

```sh
bundle install
```

## Run the chat shell

```sh
bin/pikuri-tui-chat
```

Defaults to `http://localhost:8080` and model `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`. Override with `--server`, `--model`, and `--api-key-env`:

```sh
bin/pikuri-tui-chat --server http://localhost:8082 --model my-model
```

## Configuration

Both shells read an optional TOML config file. It is looked up in this order,
later layers overriding earlier ones, and command-line flags overriding all of
them:

1. `/etc/xdg/pikuri/config.toml` (system-wide)
2. `$XDG_CONFIG_HOME/pikuri/config.toml` (defaults to `~/.config/pikuri/config.toml`)

With no file present, the built-in defaults apply (local llama.cpp on
`http://localhost:8080`), so the config file is entirely optional.

There is deliberately **no project-local config** (e.g. `./.pikuri/`): a file
inside a repo could be committed to git and is readable by the sandboxed
coding agent — exactly where an API key must not live.

### API keys / tokens

Put the secret **literally** in this file via `api_key`, and keep the file
readable only by you (`chmod 600 ~/.config/pikuri/config.toml`). pikuri-tui
flags loose permissions on a key-bearing file in the diagnostic log.

This is intentional, and *safer* than an environment variable: the process
environment is inherited by every subprocess pikuri spawns — the sandboxed
bash tool, stdio MCP servers — so a key in `OPENAI_API_KEY` is readable by any
command the agent runs. The config file is read only by the parent process,
never exported to children, and (being outside the project root) is not even
visible to the sandboxed agent's filesystem.

```toml
# Model connections. This is an array of tables — list as many as you like;
# for now both shells use the FIRST entry. Each `name` must be unique (a
# future release will let you switch between them by name in the TUI).
[[llm]]
name    = "Local Qwen 3.6"
server  = "http://localhost:8080"
model   = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
# A local llama.cpp needs no key — omit api_key and it falls back to
# "not-needed".

# A second connection, e.g. an authenticated remote endpoint. The token goes
# verbatim into api_key (see "API keys / tokens" above — keep this file
# chmod 600).
# [[llm]]
# name    = "OpenRouter Claude"
# server  = "https://openrouter.ai/api"
# model   = "anthropic/claude-opus-4-8"
# api_key = "sk-or-..."

# Coding-shell settings (bin/pikuri-tui-code only).
[code]
sandbox = true   # bubblewrap sandbox around bash; --no-sandbox / --yolo force false
confirm = true   # y/n prompt before writes + bash;  --no-confirm / --yolo force false

# MCP (Model Context Protocol) servers for the coding shell. Declare a local
# stdio server with `command` (the full argv), or a remote HTTP server with
# `url` — exactly one per entry. Each `id` must be unique.
#
# We recommend wrapping stdio MCP servers in a Docker image rather than
# running them straight on the host: the server stays isolated from your
# filesystem and credentials, and you avoid installing its toolchain (Node,
# Python, …) locally. Use `docker run -i --rm` — `-i` keeps stdin open for the
# stdio transport, `--rm` discards the container on exit.
[[code.mcp]]
id      = "playwright"
command = ["docker", "run", "-i", "--rm", "mcr.microsoft.com/playwright/mcp"]

# A stdio server may also set `env` — environment variables merged over the
# inherited environment of the subprocess (the natural home for its tokens,
# kept out of pikuri-tui's own environment). stdio only.
[[code.mcp]]
id      = "github"
command = ["github-mcp"]
[code.mcp.env]
GITHUB_TOKEN = "ghp-..."

# A remote HTTP server may authenticate three ways (HTTP only). All resolve
# into the headers sent on every request; pick at most one of bearer_token /
# basic_auth (both set Authorization), and add custom headers as needed.
#
#   bearer_token →  Authorization: Bearer <token>
#   basic_auth   →  Authorization: Basic  base64("<username>:<password>")
#   headers      →  arbitrary extra headers, sent verbatim
[[code.mcp]]
id           = "example-bearer"
url          = "https://mcp.example.com/v1"
bearer_token = "sk-..."

# [[code.mcp]]
# id  = "example-basic"
# url = "https://mcp.example.com/v1"
# basic_auth = { username = "user", password = "pass" }   # or a [code.mcp.basic_auth] sub-table

# [[code.mcp]]
# id  = "example-headers"
# url = "https://mcp.example.com/v1"
# headers = { "X-Api-Key" = "abc" }                        # or a [code.mcp.headers] sub-table
```

Secrets in the config file — `api_key`, the `[search]` keys, and any MCP
`bearer_token` / `basic_auth` / `headers` / `env` value — should be kept
private; pikuri-tui prints a `chmod 600` advisory to the diagnostic log
(`Ctrl+L`) when a file holding one is group- or world-readable.

## Layout

```
┌──────────────────────────────────┐
│ Conversation (TextView)          │
│                                  │
│ assistant: markdown, reasoning   │
│ tool calls & observations        │
│                                  │
├──────────────────────────────────┤
│ Input field (Enter to submit)    │
├──────────────────────────────────┤
│ Status bar                       │
└──────────────────────────────────┘
```

`Ctrl+L` toggles the diagnostic log pane (pikuri internals, library errors, agent-loop diagnostics).
