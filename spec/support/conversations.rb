# frozen_string_literal: true

# Helpers for the App specs, whose conversation boots its agent and runs its
# turns on threads of their own.
#
#   app = build_app { |llm| llm.stream('hi') }
#   wait_until_idle(app)          # booted, no turn running
#   booted_agent(app).tools       # the agent configure wired
#
# Every App built in an example is shut down as the example closes its screen,
# so no boot or turn thread outlives the example — or logs into a pane that is gone. Mixed into every example (see
# spec_helper).
module ConversationApps
  # The Apps built in the running example.
  OPEN = [] # rubocop:disable Style/MutableConstant -- the register itself

  # Records each App as it is built.
  module Tracked
    def initialize(...)
      super
      OPEN << self
    end
  end

  # Shuts the conversations down just before the screen goes.
  module ClosesWithScreen
    def close
      ConversationApps.close_all
      super
    end
  end

  # Shut down what the example left running. A closing agent's last events
  # may still reach a pane, so pikuri's log goes to the null sink first rather
  # than to the App's screen-bound log pane.
  def self.close_all
    Pikuri.log_io = NULL_LOG
    OPEN.pop.instance_variable_get(:@conversations).shutdown(timeout: 5) until OPEN.empty?
  end

  # Wait until +app+'s conversation has booted and no turn runs.
  #
  # @return [void]
  def wait_until_idle(app)
    wait_until { app.session.status.state == :idle }
  end

  # The agent +app+'s conversation booted — private to the conversation, read
  # here only to inspect what +configure+ wired.
  #
  # @return [Pikuri::Agent]
  def booted_agent(app)
    wait_until_idle(app)
    app.session.instance_variable_get(:@agent)
  end
end
