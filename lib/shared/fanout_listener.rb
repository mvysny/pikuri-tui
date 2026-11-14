# frozen_string_literal: true

require 'pikuri-core'

# Opened as +module Shared+ rather than +class Shared::FanoutListener+: YARD
# registers the namespace only from a file that opens it so, and without one
# sord drops every +Shared::+ class from sig/pikuri_tui.rbs.
module Shared
  # One listener standing for several: a +Pikuri::Conversations#open+ takes a
  # single +listener:+, which hears both the agent's events and the
  # conversation's own, and each pane wants its slice of both.
  #
  #   listener = Shared::FanoutListener.new([transcript_listener, status_rule, task_listener])
  #   conversations.open(id: 'main', transport:, listener:)
  #
  # A spawned sub-agent gets a fan-out of each listener's sub-agent variant, by
  # +Pikuri::Agent::ListenerList#for_sub_agent+'s rule: a listener without
  # +for_sub_agent+ is kept by reference, one answering +nil+ is dropped.
  #
  # Thread-safe when every listener in it is: it holds no state of its own.
  class FanoutListener < Pikuri::Agent::Listener::Base
    # @param listeners [Array<Pikuri::Agent::Listener::Base>] the listeners, in
    #   the order each event reaches them.
    def initialize(listeners)
      super()
      @list = Pikuri::Agent::ListenerList.new(listeners)
    end

    # @param event [Object] any agent or conversation event.
    # @return [void]
    def on_event(event)
      @list.emit(event)
    end

    # @param params [Hash{Symbol => Object}] forwarded to each listener's
    #   +for_sub_agent+.
    # @return [Shared::FanoutListener]
    def for_sub_agent(**params)
      self.class.new(@list.for_sub_agent(**params).each.to_a)
    end

    # @return [String] e.g. +"Fanout[RateLimited(…), StatusRule]"+.
    def to_s = "Fanout#{@list}"
  end
end
