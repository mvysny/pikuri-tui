# Port the computer shell's specs to `Pikuri::Testing.fake_transport`

Chat and code already build their *real* agent on a scripted-HTTP
`fake_transport` (the `transport:` test seam on `Chat::App` / `Code::App`);
computer still swaps the whole agent for `ComputerStubAgent` via the
`&build_agent` block, so its real `default_build_agent` wiring is never run in
a spec and it lacks the "a real streamed turn renders in the conversation
pane" test the other two gained.

The port mirrors chat/code: add the `transport:` seam to `Computer::App`, swap
`&build_agent` → `transport:` in `spec/computer/app_spec.rb`, delete
`ComputerStubAgent`, add the render test. Computer's agent is `streaming:
true`, so scripted turns use `llm.stream(...)`.

## What makes it more than mechanical

`default_build_agent` wires `Os::Extension` + `Thunderbird::Extension`, which
probe the host at build. Every seam needed already exists in pikuri — nothing
upstream to change:

- **Thunderbird profile.** `Profile.discover(profile_dir: nil)` finds the dev
  machine's *real* profile (opens real mail) and raises on an ambiguous
  install. App already forwards its `profile_dir:` to the extension, so the
  spec passes an empty temp dir (deterministic: Gloda absent → inbound tools
  omitted, outbound tools harmlessly wired).
- **Machine facts.** `Os::SystemInfo#prompt_section` spawns `inxi -b` at
  *every* agent build — ~30 builds ⇒ ~30 spawns, slow and machine-coupled.
  `Os::Extension` takes `system_info:`, but App doesn't thread it. Either stub
  `Os::SystemInfo.new` in the spec (`define_singleton_method`, restored in
  `after`) returning a fake with a fixed `prompt_section`, or let App accept a
  `system_info:` — prefer the stub unless a second caller wants the seam.
- **Sandbox.** `config.sandbox: true` builds `FullFsNoNet`, whose bwrap probe
  may raise; boot the spec with `sandbox: false` (`Sandbox::NONE`) — first
  confirm no test asserts the sandbox wiring.
