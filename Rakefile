# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

Dir.glob('tasks/*.rake').each { |r| load r }

# The cross-repo standard entry point: `bundle exec rake check` (or bare
# `bundle exec rake`) runs the full verification — the YARD → RBS signatures
# (tasks/sig.rake) first, since Shared::Config reads them at runtime, then the
# spec suite, rubocop and the design/ doc-layer tripwires, so an untyped tag, a
# style slip, a dangling slug or an oversized AGENTS.md trips in the agent's
# inner loop rather than in CI. Going through rake keeps
# the Bundler environment — see AGENTS.md on why plain `rspec` is never safe here.
desc 'Full check: the sord signatures, the spec suite, rubocop, then the design-doc tripwires ' \
     '(the cross-repo standard entry point)'
task check: %i[sig spec rubocop design_tripwires]

task default: :check
