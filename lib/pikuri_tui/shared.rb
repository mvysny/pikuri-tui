# frozen_string_literal: true

# Namespace for the reusable building blocks the three shells ({Chat},
# {Code}, {Os}) compose out of — the toolkit, as opposed to each shell's own
# +App+ / +Layout+ scaffolding (which stays deliberately duplicated per
# shell). Anything that stands alone with a clear contract and carries no
# shell-specific divergence lives here; a triplicated field or method across
# the three +App+s is the signal that a block belongs here instead.
#
# Grouped by subsystem underneath: {Shared::Log} (diagnostic-log plumbing),
# {Shared::Model} (model-switch value object / listener / picker), and
# {Shared::Markdown} (Markdown → ANSI rendering). The standalone pieces sit
# directly here: {Shared::AppTheme}, {Shared::Config}, {Shared::TuileListener},
# {Shared::InputArea}, {Shared::StatusLabel}, {Shared::LeaderMenu}.
module Shared
end
