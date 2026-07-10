# frozen_string_literal: true

module PikuriTui
  # Namespace for the +bin/pikuri-tui-chat+ TUI: the conversation-pane shell
  # ({Chat::App}) and its vertical-split root layout ({Chat::Layout}).
  #
  # Components reused across the chat / code / OS shells — the
  # conversation-pane listener ({TuileListener}), the diagnostic log sink
  # ({CountingLogIO}), the popup wrapper around the diagnostic +LogWindow+
  # ({LogPopup}), the Enter-submits text input ({InputArea}), the
  # conversation-window footer ({StatusLabel}) — stay at the {PikuriTui} top
  # level. Anything genuinely specific to the chat front-end (system prompt
  # wiring, layout) lives here; the coding and OS shells have their own
  # {Code} / {Os} sibling namespaces.
  module Chat
  end
end
