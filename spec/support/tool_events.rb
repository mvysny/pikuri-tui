# frozen_string_literal: true

# Builders for the two tool events. Both carry display strings the *tool*
# composes upstream, and the transcript prints those rather than deriving its
# own — so a fixture leads with what shows on screen:
#
#   listener.on_event(tool_call('bash', 'rm -rf build'))   # => Bash(rm -rf build)
#   listener.on_event(tool_result('Error: exit 1'))
#
# +display_name+ defaults to pikuri's own +web_search+ → +WebSearch+
# derivation. +arguments:+ (the raw hash) and +content:+ (the observation the
# model reads) matter only to the +:verbose+ form and the per-tool formatters;
# +content:+ defaults to the summary, since a fixture rarely cares about both.
module ToolEvents
  def tool_call(name, argument = '', arguments: {}, display_name: nil, tool_call_id: 'c1')
    Pikuri::Agent::Event::ToolCall.new(
      tool_call_id: tool_call_id, name: name, arguments: arguments,
      display_name: display_name || Pikuri::Tool.display_name_for(name),
      argument: argument
    )
  end

  def tool_result(summary = '', content: nil, name: 'tool', tool_call_id: 'c1')
    Pikuri::Agent::Event::ToolResult.new(
      tool_call_id: tool_call_id, name: name, content: content || summary, summary: summary
    )
  end
end
