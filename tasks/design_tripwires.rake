# Hooks the tripwire scripts into rake (the layout is described in AGENTS.md, "Design docs").
# The two bash scripts are the single implementation; this task only runs them — the doc layer
# first (dangling slugs, the AGENTS.md caps, the CLAUDE.md shim), then this project's own
# invariant checks.
#
# Both need bash and git: they find the repo root with `git rev-parse` and enumerate with
# `git ls-files`, so "the tree" means the files this repo tracks and no prune list has to keep up
# with build output. Developer machines have both and so does CI's `ruby:3.3`; the task skips
# itself where either is missing (a git-less build image, Windows) rather than failing the build
# on a check it cannot run.

desc 'Tripwires: cited slugs resolve, AGENTS.md under its cap, CLAUDE.md is the shim, T_ checks pass'
task :design_tripwires do
  if %w[bash git].all? { |cmd| system("command -v #{cmd} > /dev/null 2>&1") }
    sh 'design/verify_design_tripwires.sh'
    sh 'design/verify_project_tripwires.sh'
  else
    warn 'design_tripwires: bash or git is missing — skipping the tripwire scripts'
  end
end
