# pikuri-tui

[![status](https://ci.codeberg.org/api/badges/17231/status.svg)](https://ci.codeberg.org/repos/17231)

Terminal UI front-ends for [pikuri](https://codeberg.org/mvysny/pikuri) — a Ruby LLM agent framework.

Three shells:

- **`pikuri-tui-chat`** — general-purpose chat with web search and calculator tools.
- **`pikuri-tui-code`** — in-repo coding agent (sandboxed file/shell tools, git diff view, plan mode).
- **`pikuri-tui-computer`** — desktop assistant for this machine: the OS helper (file + network-severed sandboxed bash tools) plus local Thunderbird mail + calendar (search/read + human-gated draft hand-offs), with web research quarantined behind an isolated sub-agent.

Pikuri owns the agent loop, tool execution, and LLM transport. This project owns nothing but the TUI shell: a conversation pane, a diagnostic log pane, an input field, and a status bar.

## Prerequisites

- Ruby ≥ 3.3
- A local LLM server (e.g. [llama.cpp](https://github.com/ggerganov/llama.cpp) `server`),
  or a cloud-based LLM server (Grok, Anthropic, ...)

## Install

```sh
bundle install
```

## Run the chat shell

```sh
bin/pikuri-tui-chat
```

Defaults to `http://localhost:8080` and model `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`. Override with `--server` and `--model`:

```sh
bin/pikuri-tui-chat --server http://localhost:8082 --model my-model
```

## Run the coding shell

```sh
bin/pikuri-tui-code
```

Discovers the project root (VCS marker), `chdir`s to it, and roots the
workspace + bubblewrap sandbox there. `--no-sandbox` / `--no-confirm` /
`--yolo` relax the safety machinery (see `[code]` below); `--server` /
`--model` override the connection.

## Run the computer assistant

```sh
bin/pikuri-tui-computer
```

A desktop assistant for this machine, composing two surfaces: the **OS
helper** (the five file tools plus a **network-severed** sandboxed `bash`, for
understanding and operating the local host) and **local Thunderbird mail +
calendar** — search/read your own messages and events, and draft a reply or
add an event that opens in Thunderbird for **you** to review and Send/confirm
(pikuri sends nothing itself).

The main agent holds no direct network egress; web research is on by default
but **quarantined** — the `web_search` / `web_scrape` / `fetch` tools are
registered sub-agent-only, so the main agent delegates each research task to
an isolated `RESEARCHER` sub-agent (web tools, no filesystem), gated by the
same y/n confirmation as writes and bash. `--no-internet` drops the researcher
(mail + calendar still work). The sandbox requires
[bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`) and refuses to
start without it. `--no-sandbox` lifts the no-egress guarantee on `bash` (it
can then reach the internet directly — use only in a throwaway environment);
`--profile-dir` pins the Thunderbird profile (otherwise auto-discovered);
`--no-confirm` / `--yolo` / `--server` / `--model` behave as in the other
shells.

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
# Model connections. This is an array of tables — list as many as you like.
# The FIRST entry is the boot connection; if you list more than one, the
# leader menu (Ctrl+K → m) lets you switch between them live by name. Each
# `name` must be unique.
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
# A local llama.cpp reports its real window automatically; a cloud server
# can't be probed, so set context_window to see a used/cap figure in the
# footer (omit it and the cap simply stays blank).
# context_window = 1000000

# Web-search provider keys. Used by the chat shell (web_search is a main
# tool) and by the sub-agent-only research tools of the coding and computer shells.
# Both fields are optional — set one,
# both, or neither — and, like api_key, go in verbatim (keep this file
# chmod 600). pikuri's search cascade decides what to do when a key is unset.
[search]
brave_key = "BSA..."   # Brave Search API key
exa_key   = "..."      # Exa API key

# Sandbox + confirmation settings. Applies to BOTH the coding shell
# (bubblewrap sandbox around bash) and the computer assistant (network-severed
# sandbox); the chat shell has no sandbox and ignores this table.
[code]
sandbox = true   # sandbox around bash; --no-sandbox / --yolo force false
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

Secrets in the config file — `api_key` and any MCP
`bearer_token` / `basic_auth` / `headers` / `env` value — should be kept
private; pikuri-tui prints a `chmod 600` advisory to the diagnostic log
when a file holding one is group- or world-readable.

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

All commands route through one leader key: **`Ctrl+K`** opens a which-key-style menu
(`l` logs, `d` git diff, `p` plan mode, `m` switch model, `c` clear conversation,
`q` quit); the entries vary per shell. The diagnostic log pane (`l`) shows pikuri
internals, library errors, and agent-loop diagnostics. `Ctrl+C` cancels the
current turn or quits — it is the only other direct shortcut.
