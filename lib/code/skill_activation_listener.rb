# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-skills'

module Code
  # Mirrors pikuri's path-activation gate into the two places the human reads
  # it: the slash palette's +/<skill-name>+ half, and a transcript line when a
  # touched file brings a gated skill into play.
  #
  #   · skills available: writing-rdoc (matched lib/code/app.rb)
  #
  #   skill_activation = Code::SkillActivationListener.new(
  #     skill_extension: skill_ext, slash_menu: slash_menu,
  #     conversation: conversation_window, screen: screen,
  #     base: built_in_commands,
  #     on_load: ->(name, rest) { skill_ext.schedule_load_skill(name); session.submit(rest) }
  #   )
  #   agent = Pikuri::Agent.new(...) { |c| c.add_listener skill_activation }
  #   skill_activation.refresh        # seed the palette, and again after every /clear
  #
  # A skill declaring +paths:+ is not in play until the model touches a matching
  # file, so it is not listed until then — and the moment it fires it appears
  # without the user reopening anything. +base+ leads the palette and reserves
  # its own names: a skill whose +/<name>+ is already taken is dropped with one
  # warn, so a built-in verb (+/plan+) can never be captured by a same-named
  # skill. What is lost is only the shortcut — the skill stays loadable by
  # asking the agent for it in plain language.
  #
  # == Implementation details
  #
  # The gate binds the human, not only the model: +schedule_load_skill+ refuses
  # a pending skill exactly as the +skill+ tool does, so listing one would
  # produce a palette entry that raises +KeyError+ on Enter. Reading the
  # activation is what keeps the two in step.
  #
  # The matched path is why the notice is rendered from the event rather than
  # left to the injected block {Shared::ConversationTextView} drops: activation
  # deliberately over-fires, so a skill *will* appear for no visible reason, and
  # without the trigger, diagnosing it means guessing which glob matched.
  #
  # {#refresh} is the reset half rather than a +Event::Reset+ arm:
  # +Agent#clear_conversation+ emits that event *before* it clears the
  # activation, so the host refreshes once that call has returned.
  #
  # The extension is held rather than its +activation+, because
  # +Skill::Extension#configure+ may swap that object out for an
  # +Activation::Open+ (an agent with no interloper has no channel a promotion
  # could land on, so the gate comes off wholesale). Reading it per call follows
  # the swap; a captured reference would keep gating a palette nothing can
  # un-gate.
  #
  # UI-thread-confined, with exceptions.
  class SkillActivationListener < Pikuri::Agent::Listener::Base
    # @return [Logger]
    LOG = Pikuri.logger_for('code')
    private_constant :LOG

    # @param skill_extension [Pikuri::Skill::Extension] source of both the
    #   catalog and the activation gate deciding what is in play right now.
    # @param slash_menu [Shared::SlashMenuPopup] the palette to keep current.
    # @param conversation [Shared::ConversationTextView] where a promotion is
    #   announced.
    # @param screen [Tuile::Screen] whose +event_queue+ marshals a promotion
    #   back onto the event-loop thread.
    # @param base [Array<Shared::SlashCommand>] the commands that lead the
    #   palette and reserve their names against the skills.
    # @param on_load [Proc] called as +(name, rest)+ when a +/<skill-name>+
    #   runs: the catalog name, and the rest of the typed line.
    def initialize(skill_extension:, slash_menu:, conversation:, screen:, base:, on_load:)
      super()
      @skill_extension = skill_extension
      @slash_menu = slash_menu
      @conversation = conversation
      @screen = screen
      @base = base
      @on_load = on_load
      @reserved = base.map(&:name).to_set
      @shadowed = Set.new
    end

    # The palette's full command set as of now: +base+ followed by one
    # +/<skill-name>+ per skill currently in play, in catalog order.
    #
    # @return [Array<Shared::SlashCommand>]
    def commands
      activation = @skill_extension.activation
      @base + @skill_extension.catalog.list.filter_map do |skill|
        next unless activation.in_play?(skill.name)

        skill_command(skill)
      end
    end

    # Push {#commands} onto the palette. Call it once the agent is built (to
    # seed), and after every +clear_conversation+ (which re-hides every gated
    # skill).
    #
    # @return [void]
    def refresh
      @slash_menu.commands = commands
      nil
    end

    # Announces a promotion and re-lists the palette; ignores every other event.
    # Safe from any thread — it fires on the agent's worker — because the
    # palette mutation is marshaled onto the UI thread and the notice marshals
    # itself.
    #
    # @param event [Data] any agent event; only
    #   {Pikuri::Skill::Promoted} is acted on.
    # @return [void]
    def on_event(event)
      return unless event.is_a?(Pikuri::Skill::Promoted)

      @conversation.render_notice(event.to_s)
      @screen.event_queue.submit { refresh }
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+ when this
    #   listener is in its +ListenerList+.
    def to_s = 'SkillActivationListener'

    private

    # @param skill [Pikuri::Skill::Catalog::Skill]
    # @return [Shared::SlashCommand, nil] +nil+ when +base+ already took the
    #   name, warned once per skill however often the palette is recomputed.
    def skill_command(skill)
      name = "/#{skill.name}"
      if @reserved.include?(name)
        LOG.warn("skill #{skill.name.inspect} shadows a built-in command; not registered as #{name}") \
          if @shadowed.add?(name)
        return nil
      end

      Shared::SlashCommand.new(name, skill.description, ->(rest) { @on_load.call(skill.name, rest); nil })
    end
  end
end
