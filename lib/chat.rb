# frozen_string_literal: true

# Namespace for the +bin/pikuri-tui-chat+ TUI: the conversation-pane shell
# ({Chat::App}) and its vertical-split root layout ({Chat::Layout}).
#
# Components reused across the chat / code / OS shells — the
# conversation-pane listener ({Shared::TuileListener}), the diagnostic log sink
# ({Shared::Log::CountingIO}), the popup wrapper around the diagnostic +LogWindow+
# ({Shared::Log::Popup}), the Enter-submits text input ({Shared::InputArea}), the
# conversation-window footer ({Shared::StatusLabel}) — live in the {Shared}
# namespace. Anything genuinely specific to the chat front-end (system prompt
# wiring, layout) lives here; the coding and OS shells have their own
# {Code} / {Os} sibling namespaces.
module Chat
end
