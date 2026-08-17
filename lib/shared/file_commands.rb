# frozen_string_literal: true

# Turns pikuri's on-disk slash commands — the +.md+ prompt templates under
# +.pikuri/commands+ / +.claude/commands+ — into {Shared::SlashCommand}s the
# palette can list and run:
#
#   commands = Shared::FileCommands.build(
#     registry: command_registry, reserved: built_ins.map(&:name),
#     screen: screen, logger: LOG,
#     on_expand: ->(text) { session.submit(text) }
#   )
#   #=> [#<SlashCommand name="/wh" description="<label> — weekly work log" …>]
#
# Running one expands its template (+$ARGUMENTS+, +$1+…+$9+) against the rest
# of the typed line and hands the result to +on_expand+ as an ordinary user
# turn — the human wrote it, the template just saved the typing. So it is not a
# +:system+ block and it is not hidden from the transcript.
#
# A command whose file pikuri refuses — it declares +allowed-tools:+, or its
# body carries a <code>!`cmd`</code> shell directive — is still listed, marked
# +(unavailable)+, and answers with the reason instead of running. A menu entry
# that silently vanished would be the worse failure, since the human is looking
# straight at the list.
#
# +reserved+ is what a built-in already took. A file command may not capture a
# built-in verb: a cloned repo shipping +.claude/commands/plan.md+ would
# otherwise take over +/plan+, which flips a safety gate. The loser is dropped
# with a warn, and dropped is all it is — unlike a shadowed skill, nothing else
# reaches it.
#
# Requires no pikuri gem: +registry+ is duck-typed, so the lean chat process
# (which never loads pikuri-skills) can still eager-load this file.
module Shared::FileCommands
  module_function

  # @param registry [Pikuri::Command::Registry] the scanned command files.
  # @param reserved [Array<String>] command names already taken, leading slash
  #   included.
  # @param screen [Tuile::Screen] resolves the theme at run time, so a refusal
  #   is toned by whatever theme is current rather than the boot one.
  # @param logger [Logger] takes the shadowing warnings, so they carry the
  #   composing shell's subsystem tag.
  # @param on_expand [Proc] called with the expanded template +String+; drives
  #   it as a user turn.
  # @return [Array<Shared::SlashCommand>] in the registry's own precedence
  #   order.
  def build(registry:, reserved:, screen:, logger:, on_expand:)
    registry.list.filter_map do |command|
      name = "/#{command.name}"
      if reserved.include?(name)
        logger.warn("command #{command.name.inspect} at #{command.location} shadows a built-in; " \
                    "not registered as #{name}")
        next
      end

      Shared::SlashCommand.new(name, hint(command), callback(registry, command, screen, on_expand))
    end
  end

  # @param command [Pikuri::Command::Registry::Command]
  # @return [String] the palette's right column: the argument hint leads when
  #   the file declared one, since that is what you type next.
  def hint(command)
    text = command.argument_hint.to_s.empty? ? command.description : "#{command.argument_hint} — #{command.description}"
    command.refused? ? "#{text} (unavailable)" : text
  end
  private_class_method :hint

  # @param registry [Pikuri::Command::Registry]
  # @param command [Pikuri::Command::Registry::Command]
  # @param screen [Tuile::Screen]
  # @param on_expand [Proc]
  # @return [Proc] the +(rest)+ action; +nil+ return for a command that ran (the
  #   turn is its own record), the refusal reason for one that cannot.
  def callback(registry, command, screen, on_expand)
    return ->(_rest) { screen.theme.error("/#{command.name} is unavailable — #{command.refusal}") } if command.refused?

    lambda do |rest|
      on_expand.call(registry.expand(command.name, arguments: rest))
      nil
    end
  end
  private_class_method :callback
end
