# frozen_string_literal: true

# Builders for the two tool events. Both carry display strings the *tool*
# composes upstream (+display_name+ / +argument+ / +summary+), and the
# transcript prints those rather than deriving its own — so a fixture leads
# with what shows on screen:
#
#   listener.on_event(tool_call('bash', 'rm -rf build'))
#   listener.on_event(tool_result('Error: exit 1'))
#
# +arguments:+ (the raw hash) and +content:+ (the observation the model reads)
# matter only to the +:verbose+ form and the per-tool formatters; +content:+
# defaults to the summary, since most fixtures care about one or the other.
module ToolEvents
  # @param name [String] the registered tool name.
  # @param argument [String] the tool's own one-argument description.
  # @param arguments [Hash] the raw tool-call arguments.
  # @param display_name [String, nil] defaults to pikuri's mechanical
  #   +web_search+ → +WebSearch+ derivation.
  # @param tool_call_id [String]
  # @return [Pikuri::Agent::Event::ToolCall]
  def tool_call(name, argument = '', arguments: {}, display_name: nil, tool_call_id: 'c1')
    Pikuri::Agent::Event::ToolCall.new(
      tool_call_id: tool_call_id, name: name, arguments: arguments,
      display_name: display_name || Pikuri::Tool.display_name_for(name),
      argument: argument
    )
  end

  # @param summary [String] the tool's own one-line status.
  # @param content [String, nil] the observation the model reads; defaults to
  #   +summary+.
  # @param name [String] the registered tool name.
  # @param tool_call_id [String]
  # @return [Pikuri::Agent::Event::ToolResult]
  def tool_result(summary = '', content: nil, name: 'tool', tool_call_id: 'c1')
    Pikuri::Agent::Event::ToolResult.new(
      tool_call_id: tool_call_id, name: name, content: content || summary, summary: summary
    )
  end
end
