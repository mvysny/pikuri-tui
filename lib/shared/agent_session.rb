# frozen_string_literal: true

require 'pikuri-core'

module Shared
  # Owns one agent's turn lifecycle for a shell: run the loop off the UI
  # thread, serialize concurrent turns, absorb mid-turn injections, drive
  # the conversation spinner, and escalate Ctrl+C. Construct it, hand it the
  # agent once the build block has run, then feed it user input:
  #
  #   session = Shared::AgentSession.new(
  #     screen: @screen, conversation_window: @conversation_window,
  #     model_picker: @model_picker, logger: LOG
  #   )
  #   session.agent = built_agent          # once the agent exists
  #   input_window = Shared::InputWindow.new(on_submit: session.method(:submit))
  #   # Ctrl+C -> session.interrupt ; leader 'c' -> session.clear_conversation
  #
  # This is a *coordinator/presenter*, not a UI-independent service: unlike
  # {Code::GitWatcher} it deliberately holds the +screen+ and drives the
  # conversation window's spinner / error surface — coordinating the spinner
  # with off-thread agent work is its whole job, so its sibling is
  # {Shared::StatusFooterUpdater}, not a pure service. It only ever calls the
  # window's public action verbs (+start_animation+ / +stop_animation+ /
  # +render_turn_error+ — tell, don't ask); the window keeps owning how it
  # draws.
  #
  # Each shell's +App+ composes one of these and delegates into it; the +App+
  # keeps its own construction / layout / leader-menu / shortcuts / +run+
  # loop, plus +quit+ and +on_screen_error+ (which touch neither the agent
  # nor the turn flag, so they don't belong to the turn lifecycle).
  #
  # == Threading
  #
  # UI-thread-confined, with a worker exception. Every method here must be
  # called on the thread that owns +Screen#run_event_loop+ (the UI thread) —
  # the +@turn_in_progress+ flag is read and written only there. The agent
  # loop blocks on the LLM, so {#submit} spawns a fresh +Thread.new+ per turn
  # that calls +agent.run_loop+; that worker never touches the UI directly,
  # marshaling the spinner-off / flag-clear / leftover-delivery back through
  # +screen.event_queue.submit+ so they execute on the UI thread. Concurrent
  # turns are prevented by +@turn_in_progress+: while a turn runs, {#submit}
  # routes into the agent's +Interloper+ instead of starting a second loop.
  #
  # UI-thread-confined (its own methods; the worker it spawns runs the pikuri
  # loop off-thread and marshals back).
  class AgentSession
    # @return [Pikuri::Agent, nil] the agent this session drives, or +nil+
    #   until {#agent=} is called.
    attr_reader :agent

    # @param screen [Tuile::Screen] the screen whose +event_queue+ the worker
    #   marshals back through, and whose focus / loop {#interrupt} escalates.
    # @param conversation_window [Shared::ConversationWindow] the transcript
    #   window whose spinner and error surface this drives (+start_animation+
    #   / +stop_animation+ / +render_turn_error+).
    # @param model_picker [Shared::Model::Picker] the shared picker; a pending
    #   switch is consumed via +take_pending+ at the top of each turn.
    # @param logger [Logger] the per-shell logger (so dropped-injection and
    #   clear-during-turn warnings keep the shell's subsystem tag in the
    #   diagnostic pane); typically the +App+'s +LOG+ constant.
    def initialize(screen:, conversation_window:, model_picker:, logger:)
      @screen = screen
      @conversation_window = conversation_window
      @model_picker = model_picker
      @logger = logger
      @agent = nil
      @turn_in_progress = false
    end

    # Installs the agent this session drives; call once, after the shell's
    # build block has returned the constructed +Pikuri::Agent+ (the agent —
    # hence its interloper and transport — doesn't exist at construction).
    #
    # @param agent [Pikuri::Agent] the wired agent.
    # @return [void]
    def agent=(agent)
      @agent = agent
    end

    # @return [Boolean] whether a turn is currently running. Read on the UI
    #   thread.
    def turn_in_progress? = @turn_in_progress

    # Start a turn for +message+, or — if one is already running — queue it as
    # a mid-turn injection instead of starting a second +run_loop+. The
    # {Shared::InputWindow}'s +on_submit+ target, and the re-entry point
    # {#deliver_pending_injections} uses to flush leftovers as a fresh turn.
    #
    # +message+ is normally non-blank (the input suppresses blank submits), but a
    # skill command submits +""+ to drive a *bare* load (the skill it just
    # scheduled becomes the whole turn). A blank submit is only meaningful when
    # idle — it runs a bare +run_loop+; a blank submit *mid-turn* is a no-op, as
    # the scheduled skill already rides the running turn and there's no message to
    # inject.
    #
    # @param message [String] the draft; blank only from a skill bare-load.
    # @return [void]
    def submit(message)
      if @turn_in_progress
        return if message.to_s.strip.empty?

        queue_mid_turn(message)
        return
      end

      @turn_in_progress = true
      start_turn(message)
    end

    # The +Ctrl+C+ escalation, mirroring ESC's two-press quit but driven
    # explicitly because a global shortcut fires before the pane and so never
    # "falls through" to the loop's unhandled-key quit the way ESC does. Three
    # states, in priority order:
    #
    # 1. A turn is running -> cancel it. {Shared::ConversationWindow::Listener}
    #    renders the +Cancelled+ event; the worker's +ensure+ clears the flag.
    # 2. Nothing running but something is focused (normally the
    #    {Shared::InputWindow}) -> drop focus, the same visible effect as ESC.
    # 3. Nothing running and nothing focused -> stop the event loop, which
    #    unwinds the +App+'s +run+ into +Screen#close+ (what an unhandled ESC
    #    does).
    #
    # The host registers this +over_popups: false+, so it never runs while a
    # popup is open — no need to guard the unfocus/quit steps against orphaning
    # a modal popup's focus. Runs on the UI thread (global-shortcut dispatch),
    # so touching +focused=+ / +event_queue.stop+ and reading the flag are safe.
    #
    # @return [void]
    def interrupt
      if @turn_in_progress
        @agent.cancellable&.cancel!
      elsif @screen.focused
        @screen.focused = nil
      else
        @screen.event_queue.stop
      end
    end

    # Reset the agent to a fresh-conversation state via
    # +Pikuri::Agent#clear_conversation+ (chat history, controls, and each
    # extension's conversation-scoped state). That emits a single
    # +Pikuri::Agent::Event::Reset+, off which {Shared::ConversationWindow::Listener}
    # wipes the pane and the +TokenLog+ zeroes the footer — so this only kicks
    # the agent; the visible reset falls out of the event stream. The leader
    # menu's +c+ action.
    #
    # A no-op (logged) while a turn is running: +clear_conversation+ is not
    # designed to race an in-flight +run_loop+.
    #
    # @return [void]
    def clear_conversation
      if @turn_in_progress
        @logger.warn('clear conversation ignored: a turn is in progress')
        return
      end

      @agent.clear_conversation
    end

    private

    # Route a message submitted while a turn is in flight into the agent's
    # +Pikuri::Agent::Control::Interloper+. The agent drains the queue at its
    # next +after_tool_result+ boundary; when the host wired no interloper the
    # message is dropped with a warn in the diagnostic log.
    #
    # @param message [String]
    # @return [void]
    def queue_mid_turn(message)
      interloper = @agent.interloper
      if interloper.nil?
        @logger.warn('mid-turn message dropped: the agent has no Interloper wired')
        return
      end

      interloper.inject_user_message(message)
    end

    # Spawn a worker thread for one agent turn. Library exceptions are logged
    # (the long-running TUI takes the "exceptions logged, our bugs raise" path
    # from CLAUDE.md) and a short red one-liner is echoed into the conversation
    # pane; cancellation is silent because {Shared::ConversationWindow::Listener}
    # already rendered the +Cancelled+ event.
    #
    # @param message [String]
    # @return [void]
    def start_turn(message)
      # Consume the picker's pending model switch (if any) on the UI thread,
      # before the worker spawns: run_loop applies it at the top of the turn.
      # take_pending clears it so it's applied at most once.
      transport = @model_picker.take_pending
      @conversation_window.start_animation
      Thread.new do
        @agent.run_loop(user_message: message, transport: transport)
      rescue Pikuri::Agent::Control::Cancellable::Cancelled
        # Notice already rendered by the Shared::ConversationWindow::Listener; nothing else to do.
      rescue Pikuri::Agent::EmptyTurnError
        # A bare load (blank turn on a system-hoisting provider) can't complete —
        # not a failure. Whatever was injected (a skill) already rendered its own
        # SystemInjected block; nudge the user to say something, dim not red.
        @conversation_window.render_notice('Nothing to send yet — type a message to start the turn.')
      rescue StandardError => e
        @logger.error(
          "agent turn failed: #{e.class}: #{e.message}\n#{(e.backtrace || []).join("\n")}"
        )
        @conversation_window.render_turn_error(e)
      ensure
        @screen.event_queue.submit do
          @conversation_window.stop_animation
          @turn_in_progress = false
          deliver_pending_injections
        end
      end
    end

    # A turn can end with items still sitting in the interloper queue (the agent
    # only drains it at +after_tool_result+ boundaries). Drain them and start a
    # fresh turn so every leftover is delivered promptly. Fires after a cancelled
    # turn too: a mid-turn message is usually a correction, and the cancel is
    # what makes room for it.
    #
    # The queue holds two {Pikuri::Agent::Control::Interloper::Item} kinds
    # (+:user+ / +:system+). +:user+ leftovers join, in submission order, into
    # the fresh turn's message; +:system+ leftovers (e.g. a skill scheduled
    # during the final assistant message and never drained) go *back* on the
    # queue via +inject_system_message+, so the next +run_loop+ re-applies them
    # as system context at its top rather than folding a skill body into a user
    # message. With only +:system+ leftovers the fresh turn is bare, which still
    # drains + applies them.
    #
    # Runs on the UI thread (the caller marshals via +submit+), so the
    # +@turn_in_progress+ read inside {#submit} is safe.
    #
    # @return [void]
    def deliver_pending_injections
      interloper = @agent.interloper
      pending = interloper&.drain! || []
      return if pending.empty?

      system_items, user_items = pending.partition { |item| item.kind == :system }
      system_items.each { |item| interloper.inject_system_message(item.content) }
      submit(user_items.map(&:content).join("\n\n"))
    end
  end
end
