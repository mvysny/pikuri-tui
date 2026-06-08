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
3. `./.pikuri/config.toml` (project-local, relative to the project root)

With no file present, the built-in defaults apply (local llama.cpp on
`http://localhost:8080`), so the config file is entirely optional.

```toml
# Model connections. This is an array of tables — list as many as you like;
# for now both shells use the FIRST entry. Each `name` must be unique (a
# future release will let you switch between them by name in the TUI).
[[llm]]
name        = "Local Qwen 3.6"
server      = "http://localhost:8080"
model       = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
# api_key_env names the ENVIRONMENT VARIABLE that holds the API key/token —
# NEVER put the secret itself in this file. The shell reads the variable at
# startup. Omit this line (as a local llama.cpp needs no key) and it falls
# back to "not-needed".
api_key_env = "OPENAI_API_KEY"

# A second connection, e.g. an authenticated remote endpoint. Export the
# token in your shell first:
#     export OPENROUTER_API_KEY="sk-or-..."
# and reference the variable name here. Keeping tokens in the environment (or
# a sourced, git-ignored secrets file) keeps them out of config files, shell
# history, and version control.
# [[llm]]
# name        = "OpenRouter Claude"
# server      = "https://openrouter.ai/api"
# model       = "anthropic/claude-opus-4-8"
# api_key_env = "OPENROUTER_API_KEY"

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

# [[code.mcp]]
# id  = "example-remote"
# url = "https://mcp.example.com/v1"
```

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
