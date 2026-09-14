# Hooks the doc-layer checks into rake (the layout is described in AGENTS.md, "Design docs").
# The bash script is the single implementation; this task only runs it. It is part of `rake check`,
# so a dangling slug or an oversized AGENTS.md trips in the agent's inner loop rather than in CI.
#
# The script needs bash and git — it finds the repo root with `git rev-parse` and enumerates with
# `git ls-files`, so "the tree" means the files this repo tracks and no prune list has to keep up
# with build output. Developer machines have both and so does CI's `ruby:3.3`.

desc 'Design docs: cited slugs resolve, headings and caps hold, CLAUDE.md is a symlink'
task :design_tripwires do
  sh 'design/verify_design_tripwires.sh'
end
