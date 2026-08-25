# frozen_string_literal: true

require 'tuile'

# The always-visible bottom row: a one-line hint strip assembled from named
# segments. Tuile draws no status bar and reserves no row (see its
# +DECISIONS.md+ +D-status-bar+), so each shell builds this into its own root
# layout and the two contributors write into it by name:
#
#   bar = Shared::StatusBar.new(%i[cancel menu])
#   bar[:cancel] = "^C #{screen.theme.error('cancel')}"   # App, at registration
#   bar[:menu]   = "^K #{screen.theme.hint('menu')}"      # Shared::Log::UI, per tally change
#
# Segments render left to right in the *declared* order, joined by two spaces,
# never in the order they were written. That matters because the writers don't
# assign in reading order — {Shared::Log::UI} seeds +:menu+ from its own
# constructor, long before the App registers +Ctrl+C+ — and because the error
# tally rewrites +:menu+ on every bump, which under insertion order would
# reshuffle the strip. Assigning +nil+ or an empty string removes a segment;
# an unset one takes no space.
#
# A segment's colors are baked in at assignment (+theme.hint+ / +theme.error+
# return styled strings), so a writer that wants to survive a light/dark flip
# re-assigns its segment from +on_theme_changed+.
#
# There is deliberately no +q quit+ segment. Tuile's event loop still quits on
# an *unhandled* +q+, but in every pikuri shell the focused input consumes it,
# so advertising it would be a lie — which is exactly what the framework's old
# hardcoded prefix did.
#
# UI-thread-confined.
class Shared::StatusBar < Tuile::Component::Label
  # @param order [Array<Symbol>] every segment key this strip may hold, left to
  #   right. Declaring them up front makes the order one visible decision and
  #   turns a typo'd key into a raise instead of a segment nobody sees.
  def initialize(order)
    super()
    @order = order.freeze
    @segments = {}
  end

  # @return [Array<Symbol>] the declared segment order.
  attr_reader :order

  # Sets, replaces or removes the named segment and re-renders the row.
  #
  # @param name [Symbol] one of the keys declared at construction.
  # @param text [String, Tuile::StyledString, nil] the preformatted segment;
  #   +nil+ or empty removes it.
  # @raise [ArgumentError] if +name+ was not declared.
  # @return [void]
  def []=(name, text)
    raise ArgumentError, "unknown segment #{name.inspect}; declared: #{@order.inspect}" unless @order.include?(name)

    if text.nil? || text.to_s.empty?
      @segments.delete(name)
    else
      @segments[name] = text
    end
    self.text = @order.filter_map { @segments[_1] }.join('  ')
  end

  # @param name [Symbol]
  # @return [String, Tuile::StyledString, nil] the segment, or nil if unset.
  def [](name) = @segments[name]
end
