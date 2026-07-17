# Two-phase `Pikuri::Agent` init (upstream, parked)

Parked. The bin→App agent-ownership refactor (all three shells) is now
done; this is the follow-up for the "testing-with-agent" goal. It's an
*upstream pikuri* idea, not a pikuri-tui change, and it's only worth doing
in service of that goal — the App refactor itself didn't need it.

## Why it does NOT help the App refactor

Once `Chat::App` builds its own components before the agent, the dependency
chain is linear — no cycle to break:

```
screen → ConversationWindow → listener → Agent(listener)
```

The one apparent back-edge, `conversation_window.interloper = agent.interloper`,
isn't a real cycle: the `interloper` (and `cancellable`) are independent
shared objects handed to *both* `Pikuri::Agent.new(interloper:)` and the
window. So a two-phase `Agent.new` + `agent.init` would only add a
"constructed-but-not-wired" state our code never sits in.

## Where it WOULD earn its keep: side-effect-free construction

The real motivation is that the agent build isn't a pure object graph — it
has network side effects buried in construction:

- `Mcp::Extension` makes boot-time **synthesize/verify LLM calls** during
  `add_extension` (only stays offline because the registry is empty).
- the transport carries a **context-window `/props` probe** against the
  server.

That's exactly what makes a real `Pikuri::Agent` expensive/awkward to stand
up in a unit test, and why our specs inject a `StubAgent`.

## Sketch

Split construction into:

1. a **pure** ctor / build block — register listeners, tools, extensions;
   touches no network;
2. an explicit **activation** call (`agent.start` / `agent.activate`) that
   performs the network-touching work (MCP verify, context-window probe).

Then a test can construct a fully-wired agent offline and assert on its
tools/listeners/transport without a server — a cleaner seam than the
block-injection override we're keeping in pikuri-tui (option (a)).

## Status / next step

Bring this to the pikuri repo as part of the "testing-with-agent" support
brainstorm. Frame it as: *make `Agent.new` side-effect-free; move
activation to an explicit call.* Not a prerequisite for anything in
pikuri-tui.
