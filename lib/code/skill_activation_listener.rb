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
  #     catalog: skill_catalog, slash_menu: slash_menu,
  #     conversation: conversation_window, screen: screen,
  #     base: built_in_commands,
  #     on_load: ->(name, rest) { load_skill(name, rest) }
  #   )
  #   # in the Conversations' configure:, once per agent
  #   ext = Pikuri::Skill::Extension.new(catalog: skill_catalog, root: project_root)
  #   c.add_extension ext
  #   skill_activation.extension = ext   # re-lists the palette for the new agent
  #
  # It must hear the agent's events — put it in the conversation's listener.
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
  # Which skills are in play is the current agent's {Pikuri::Skill::Activation},
  # and every agent — a /clear builds a new one — starts with the gated ones
  # hidden; {#extension=} is how the palette follows. Before the first agent is
  # built, a fresh activation of the catalog's own answers the same.
  #
  # UI-thread-confined, with exceptions.
  class SkillActivationListener < Pikuri::Agent::Listener::Base
    # @return [Logger]
    LOG = Pikuri.logger_for('code')
    private_constant :LOG

    # @param catalog [Pikuri::Skill::Catalog] the skills a palette entry may
    #   load, those gated on +paths:+ included.
    # @param slash_menu [Shared::SlashMenuPopup] the palette to keep current.
    # @param conversation [Shared::ConversationTextView] where a promotion is
    #   announced.
    # @param screen [Tuile::Screen] whose +event_queue+ marshals a promotion
    #   back onto the event-loop thread.
    # @param base [Array<Shared::SlashCommand>] the commands that lead the
    #   palette and reserve their names against the skills.
    # @param on_load [Proc] called as +(name, rest)+ when a +/<skill-name>+
    #   runs: the catalog name, and the rest of the typed line.
    def initialize(catalog:, slash_menu:, conversation:, screen:, base:, on_load:)
      super()
      @catalog = catalog
      @extension = nil
      @unbooted = Pikuri::Skill::Activation.new(catalog: catalog)
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
      activation = @extension&.activation || @unbooted
      @base + @catalog.list.filter_map do |skill|
        next unless activation.in_play?(skill.name)

        skill_command(skill)
      end
    end

    # @return [Pikuri::Skill::Extension, nil] the extension the current agent
    #   was built with; +nil+ before the first is.
    attr_reader :extension

    # Follow a new agent's extension and re-list the palette for it. Safe from
    # any thread — the Conversations' +configure:+ runs on the boot thread — and
    # set before that agent goes idle, so a host that sees the conversation idle
    # reads the extension of the agent that runs its turn.
    #
    # @param extension [Pikuri::Skill::Extension]
    # @return [void]
    def extension=(extension)
      @extension = extension
      @screen.event_queue.submit { refresh }
    end

    # Push {#commands} onto the palette.
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
