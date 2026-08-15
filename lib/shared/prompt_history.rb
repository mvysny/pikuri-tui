# frozen_string_literal: true

# Shell-style recall for the prompt: the messages submitted this session,
# oldest first, with the unsent draft pinned one slot *below* the newest — so
# browsing away from what you were typing and back is lossless.
#
#   history.append('deploy staging')  # the user submits
#   history.draft = 'half-typed'      # capture on leaving the draft (the first Up)
#   history.older                     # => 'deploy staging'
#   history.older                     # => nil — already at the oldest
#   history.newer                     # => 'half-typed' — back on the draft
#
# Entries are frozen and never rewritten — the arrows always show exactly what
# was sent, and the draft is the one mutable slot.
class Shared::PromptHistory
  def initialize
    @entries = []
    @draft = ''
    # nil = on the draft; otherwise an index into @entries.
    @position = nil
  end

  # @return [Array<String>] the entries, oldest first; a copy, so mutating it
  #   doesn't reach the store.
  def entries = @entries.dup

  # @return [Boolean] whether the cursor is on the draft, i.e. nothing is
  #   currently recalled.
  def at_draft? = @position.nil?

  # Record a submitted message, then return the cursor to a cleared draft —
  # so submitting while browsing discards the pending draft, as shells do.
  # Only *consecutive* duplicates collapse (zsh's +HIST_IGNORE_DUPS+):
  #
  #   history.append('ls'); history.append('ls')    # => one entry
  #   history.append('pwd'); history.append('ls')   # => ls, pwd, ls
  #
  # @param text [String] the submitted text; kept frozen, so the caller may
  #   go on mutating the String it passed.
  # @return [void]
  def append(text)
    entry = -text
    @entries << entry unless @entries.last == entry
    @draft = ''
    @position = nil
  end

  # @param text [String] the unsent buffer to preserve; kept frozen.
  # @return [void]
  def draft=(text)
    @draft = -text
  end

  # Step one entry toward the oldest.
  #
  # @return [String, nil] the entry to show, or +nil+ when the cursor is
  #   already on the oldest entry (or there is no history at all).
  def older
    return nil if @entries.empty? || @position&.zero?

    @position = @position.nil? ? @entries.size - 1 : @position - 1
    @entries[@position]
  end

  # Step one entry toward the newest, stopping on the draft.
  #
  # @return [String, nil] the entry to show — the draft, once past the newest
  #   entry — or +nil+ when the cursor is already on the draft.
  def newer
    return nil if @position.nil?

    @position += 1
    return @entries[@position] if @position < @entries.size

    jump_to_draft
  end

  # Abandon browsing and go straight back to the draft.
  #
  # @return [String] the preserved draft (+""+ when none was captured).
  def jump_to_draft
    @position = nil
    @draft
  end
end
