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
