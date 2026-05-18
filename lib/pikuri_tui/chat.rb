# frozen_string_literal: true

module PikuriTui
  # Namespace for the +bin/pikuri-chat+ TUI: the conversation-pane shell
  # ({Chat::App}), its vertical-split root layout ({Chat::Layout}), and the
  # Enter-submits text input ({Chat::Input}).
  #
  # Components that are reused by both chat and the future
  # +bin/pikuri-code+ shell — the conversation-pane listener
  # ({TuileListener}), the diagnostic log sink ({CountingLogIO}), the
  # popup wrapper around the diagnostic +LogWindow+ ({LogPopup}) — stay at
  # the {PikuriTui} top level. Anything genuinely specific to the chat
  # front-end (system prompt wiring, layout, input semantics) lives here;
  # +bin/pikuri-code+ will get its own +PikuriTui::Code+ sibling
  # namespace.
  module Chat
  end
end
