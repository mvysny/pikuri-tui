# frozen_string_literal: true

require 'pikuri-core'

module Shared
  # Owns one agent's turn lifecycle for a shell: run the loop off the UI
  # thread, serialize concurrent turns, absorb mid-turn injections, drive
  # the status rule's spinner, and escalate Ctrl+C. Construct it, hand it the
  # agent once the build block has run, then feed it user input:
  #
  #   session = Shared::AgentSession.new(
  #     screen: @screen, conversation: @conversation, status_rule: @status_rule,
  #     model_picker: @model_picker, logger: LOG
  #   )
  #   session.agent = built_agent          # once the agent exists
  #   input = Shared::InputPane.new(on_submit: session.method(:submit))
  #   # Ctrl+C -> session.interrupt ; leader 'c' -> session.clear_conversation
  #
  # This is a *coordinator*, not a UI-independent service: unlike
  # {Code::GitWatcher} it deliberately holds the +screen+ and drives two panes'
  # surfaces — the rule's spinner and the transcript's error / notice lines.
  # Coordinating those with off-thread agent work is its whole job. It only
  # ever calls their public action verbs (+start_animation+ /
  # +stop_animation+ / +render_turn_error+ — tell, don't ask); each pane keeps
  # owning how it draws.
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
    #   until it's set. Set it once, after the shell's build block has
    #   returned the agent: the agent, hence its interloper and transport,
    #   doesn't exist at construction.
    attr_accessor :agent

    # @param screen [Tuile::Screen] the screen whose +event_queue+ the worker
    #   marshals back through, and whose focus / loop {#interrupt} escalates.
    # @param conversation [Shared::ConversationTextView] the transcript pane
    #   whose error / notice surface this drives (+render_turn_error+ /
    #   +render_notice+).
    # @param status_rule [Shared::StatusRuleLabel] the status rule whose
    #   mid-turn spinner this drives (+start_animation+ / +stop_animation+).
    # @param model_picker [Shared::Model::Picker] the shared picker; a pending
    #   switch is consumed via +take_pending+ at the top of each turn, and read
    #   via +pending+ by {#attachment_refusal}.
    # @param logger [Logger] the per-shell logger (so dropped-injection and
    #   clear-during-turn warnings keep the shell's subsystem tag in the
    #   diagnostic pane); typically the +App+'s +LOG+ constant.
    def initialize(screen:, conversation:, status_rule:, model_picker:, logger:)
      @screen = screen
      @conversation = conversation
      @status_rule = status_rule
      @model_picker = model_picker
      @logger = logger
      @agent = nil
      @turn_in_progress = false
      @on_attachment_refused = nil
    end

    # Subscribe to a turn the model refused for its images
    # (+Pikuri::Agent::UnsupportedAttachmentError+): nothing was sent, and the
    # block runs on the UI thread with the reason.
    #
    #   session.on_attachment_refused { |reason| input.refuse_attachment(reason) }
    #
    # @yieldparam reason [String] e.g. +"shot.png (image/png): model m takes no vision input"+.
    # @return [void]
    def on_attachment_refused(&block)
      @on_attachment_refused = block
    end

    # @return [Boolean] whether a turn is currently running. Read on the UI
    #   thread.
    def turn_in_progress? = @turn_in_progress

    # Why the model a {#submit} would reach can't see +attachments+, asked
    # before anything is sent. Mid-turn that is the running model; between
    # turns, a pending switch's.
    #
    #   session.attachment_refusal([png])
    #   # => "shot.png (image/png): model m takes no vision input"
    #
    # Only a reported +false+ for +:vision+ refuses (+Pikuri::Agent#modalities+).
    # When nothing is known yet, the answer is +nil+ and the attachment goes
    # out. On the first turn pikuri's own check catches it, and
    # {#on_attachment_refused} hears; mid-turn, pikuri withholds it with a
    # note.
    #
    # @param attachments [Array<Pikuri::Attachment>]
    # @return [String, nil] the reason, worded as +run_loop+'s own refusal; +nil+
    #   when they may go out.
    def attachment_refusal(attachments)
      image = attachments.find { |a| a.mime.start_with?('image/') }
      return nil unless image

      pending = @model_picker.pending unless @turn_in_progress
      transport = pending || @agent.transport
      modalities = pending ? pending.modalities : @agent.modalities
      return nil unless modalities&.[](:vision) == false

      Pikuri::Agent::UnsupportedAttachmentError.new(image, "model #{transport.model} takes no vision input").message
    end

    # Start a turn for +message+, or — if one is already running — queue it as
    # a mid-turn injection instead of starting a second +run_loop+. The
    # {Shared::InputPane}'s +on_submit+ target, and the re-entry point
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
    # @param attachments [Array<Pikuri::Attachment>] images to show the model
    #   with +message+.
    # @return [void]
    def submit(message, attachments: [])
      if @turn_in_progress
        return if message.to_s.strip.empty? && attachments.empty?

        queue_mid_turn(message, attachments)
        return
      end

      @turn_in_progress = true
      start_turn(message, attachments)
    end

    # The +Ctrl+C+ escalation, mirroring ESC's two-press quit but driven
    # explicitly because a global shortcut fires before the pane and so never
    # "falls through" to the loop's unhandled-key quit the way ESC does. Three
    # states, in priority order:
    #
    # 1. A turn is running -> cancel it. {Shared::ConversationTextView::Listener}
    #    renders the +Cancelled+ event; the worker's +ensure+ clears the flag.
    # 2. Nothing running but something is focused (normally the
    #    {Shared::InputPane}) -> drop focus, the same visible effect as ESC.
    # 3. Nothing running and nothing focused -> stop the event loop, which
    #    unwinds the +App+'s +run+ into +Screen#close+ (what an unhandled ESC
    #    does).
    #
    # The host registers this +over_modal: false+, so it never runs while a
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
    # +Pikuri::Agent::Event::Reset+, off which {Shared::ConversationTextView::Listener}
    # wipes the pane and the +TokenLog+ zeroes the status rule — so this only kicks
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
    # @param attachments [Array<Pikuri::Attachment>]
    # @return [void]
    def queue_mid_turn(message, attachments)
      interloper = @agent.interloper
      if interloper.nil?
        @logger.warn('mid-turn message dropped: the agent has no Interloper wired')
        return
      end

      interloper.inject_user_message(message, attachments: attachments)
    end

    # Spawn a worker thread for one agent turn. Library exceptions are logged
    # (the long-running TUI takes the "exceptions logged, our bugs raise" path
    # from +D_tui_degrades_not_crashes+) and a short red one-liner is echoed into the conversation
    # pane; cancellation is silent because {Shared::ConversationTextView::Listener}
    # already rendered the +Cancelled+ event.
    #
    # @param message [String]
    # @param attachments [Array<Pikuri::Attachment>]
    # @return [void]
    def start_turn(message, attachments)
      # Consume the picker's pending model switch (if any) on the UI thread,
      # before the worker spawns: run_loop applies it at the top of the turn.
      # take_pending clears it so it's applied at most once.
      transport = @model_picker.take_pending
      @status_rule.start_animation
      # Here, on the UI thread where {#interrupt} reads @turn_in_progress, not
      # in the worker: a cancel sent before the worker reaches run_loop then
      # still ends this turn.
      @agent.cancellable&.reset!
      Thread.new do
        @agent.run_loop(user_message: message, attachments: attachments, transport: transport)
      rescue Pikuri::Agent::Control::Cancellable::Cancelled
        # Notice already rendered by the Shared::ConversationTextView::Listener; nothing else to do.
      rescue Pikuri::Agent::EmptyTurnError
        # A bare load (blank turn on a system-hoisting provider) can't complete —
        # not a failure. Whatever was injected (a skill) already rendered its own
        # SystemInjected block; nudge the user to say something, dim not red.
        @conversation.render_notice('Nothing to send yet — type a message to start the turn.')
      rescue Pikuri::Agent::UnsupportedAttachmentError => e
        @screen.event_queue.submit { @on_attachment_refused&.call(e.message) }
      rescue StandardError => e
        @logger.error(
          "agent turn failed: #{e.class}: #{e.message}\n#{(e.backtrace || []).join("\n")}"
        )
        @conversation.render_turn_error(e)
      ensure
        @screen.event_queue.submit do
          @status_rule.stop_animation
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
    # the fresh turn's message, their attachments with them; +:system+ leftovers (e.g. a skill scheduled
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
      submit(user_items.map(&:content).join("\n\n"), attachments: user_items.flat_map(&:attachments))
    end
  end
end
