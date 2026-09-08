# frozen_string_literal: true

require 'tomlrb'

# Layered TOML configuration loaded once at boot by all three shells,
# before the screen is up, and read from there on:
#
#   config = Shared::Config.load(overrides: { sandbox: cli_sandbox })
#   config.primary_llm   # the boot connection
#   config.llms          # every [[llm]], for the model picker
#   config.servers       # every [[server]], for the request throttle
#   config.sandbox       # coding/OS sandbox switch (flag > file > default)
#
# It holds the resolved model connections, the web-search selection,
# the coding shell's sandbox / confirm switches, its MCP server list, and
# the +[ui]+ transcript-density defaults, merged from the XDG config search
# path with the bins' CLI overrides on top.
#
# == +[[server]]+ and +[[llm]]+
#
#   [[server]]
#   id                      = "grok"
#   url                     = "https://api.x.ai/v1"
#   api_key                 = "xai-..."
#   max_concurrent_requests = 4
#
#   [[llm]]
#   name           = "Grok 4 Fast"
#   server         = "grok"
#   model          = "grok-4-fast"
#   context_window = 131072
#
# The box and the model running on it are separate tables, so four models on
# one provider state its URL and its key once instead of four times. +id+ is
# referenced by machine, +name+ is shown to a person — the rule
# +[[code.mcp]]+ already follows — and those two are what {.load} checks for
# uniqueness. Two +[[server]]+ entries may share a URL (two accounts on one
# provider), and an unreferenced +[[server]]+ is legal, so commenting out an
# +[[llm]]+ cannot break the file.
#
# {Llm#server} is the resolved *URL*, and the +id+ leaves this class only in a
# log line: an id means nothing away from the file defining it, so anything
# that stored one would hold a reference a later edit can orphan, where a URL
# stands on its own.
#
# Nothing here has a default connection to fall back on. No +[[llm]]+ at all,
# a missing +server+ or +model+, and a +server+ resolving to nothing each raise
# {Error} — a hardcoded model tag reached silently would be a second, invisible
# connection source, so that knowledge is {EXAMPLE_CONFIG}, quoted by the raise
# for the user to edit. A file written against the older URL-in-+[[llm]]+ shape
# is guided by those messages, never accepted.
#
# == The +[ui]+ table
#
#   [ui]
#   show_thinking = false     # start with reasoning blocks collapsed
#   tool_lines    = "verbose" # start on the raw argument dump
#
# One table for all three shells — no +[chat.ui]+ / +[code.ui]+ — because
# transcript density is a preference per *person* far more than per shell.
# Each key sets the *starting* value of a {Shared::UIToggleMenu} toggle;
# flipping one lasts the session and is never written back, the same
# file-sets-default / runtime-overrides shape +sandbox+ and +confirm+ have.
# Making them session-only with no file key at all would have meant re-typing
# a taste every boot; a rewrite-in-place preferences store can still replace
# this table later without the pane noticing, since the pane is handed only a
# resolved value.
#
# The conversation pane's +markdown:+ flag is the same shape and has no key
# here yet — the natural third entry when someone wants it.
#
# == Precedence
#
# Lowest to highest: built-in defaults → +/etc/xdg/pikuri/config.toml+
# (each +$XDG_CONFIG_DIRS+ entry, earlier = higher) →
# +$XDG_CONFIG_HOME/pikuri/config.toml+ (default +~/.config+) → the CLI
# safety switches. Files merge deeply (tables key-by-key); arrays — the
# +[[server]]+, +[[llm]]+ and +[[code.mcp]]+ lists — replace wholesale,
# nearest file wins. The +[search]+ table merges key-by-key like any table, so
# a system file can supply +brave_key+ while the user file adds +exa_key+.
#
# +server+ references resolve *after* the whole merge, so a user file can add
# one +[[llm]]+ against a system file's +[[server]]+ rather than re-pasting
# that block, secrets included. The consequence, since arrays replace: a nearer
# file declaring +[[server]]+ at all replaces every farther one, which can
# leave a farther file's +[[llm]]+ dangling. That raises; it never falls back.
#
# == No connection overrides
#
# +overrides:+ takes the safety switches and nothing else. Don't add a
# +--server+ / +--model+ pair: an override lands on one {Llm}'s
# +server+/+model+ but cannot rename it, so the picker offers that entry
# under its configured {Llm#name} while talking to something else — a
# mislabel no test catches, and one that outlives the flag, since
# +Shared::Model::Picker+ builds its whole catalog from {#llms}. A model
# identifier is long enough (+unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M+) that it
# wants writing down once anyway, and the picker already covers switching at
# runtime.
#
# There is deliberately no project-local layer: a config file inside the
# repo would be git-committable and readable by the sandboxed coding
# agent — exactly where a literal {Server#api_key} or {Search} provider key
# must not live.
#
# == The Pikuri seam
#
# This class is eager-loaded by all three shells, including the chat shell,
# whose +Bundler.setup(:default)+ never puts +pikuri-mcp+ (nor the rest of
# the +:code+ group) on the load path. So {Config} references nothing from
# those gems: MCP servers surface as plain {McpServer} value objects whose
# field names ({McpServer#id} / +command+ / +url+ / +headers+) match
# +Pikuri::Mcp::Registry+'s entries 1:1, and the coding bin does the
# trivial pass-through into +Registry::StdioEntry+ / +Registry::HttpEntry+.
# The +bearer_token+ / +basic_auth+ HTTP-auth conveniences are resolved
# here into {McpServer#headers} so that pass-through stays trivial.
# Translation lives in the wiring layer where +Pikuri::*+ is allowed, not
# here.
#
# The one +Pikuri+ touch allowed here is +pikuri-core+'s logging facade:
# {.load} reports which config files it read — and any loose-permissions
# advisory ({.warn_loose_perms}) — through +Pikuri.logger_for+ (memoized,
# +progname+-tagged), which all three shells load (+pikuri-core+ is in the
# +:default+ group). +Pikuri.log_io+ defaults to +$stderr+, so these lines
# surface immediately at boot — before any screen exists. The bins install a
# {Shared::Log::BufferingIO} as that boot sink, which tees to +$stderr+ and retains
# every line, so each bin's +App+ replays the pre-screen lines into the
# diagnostic LogWindow when it rewires +Pikuri.log_io+. {Config} just logs;
# it never collects advisories for the caller to surface.
#
# == Errors
#
# Every load failure — unreadable file, malformed TOML, schema
# violation — raises {Error}. Loading runs at boot before the screen is
# up, so the bins rescue {Error} into a plain +warn+ + +exit+ rather
# than the usual route-to-LogWindow path (there is no LogWindow yet).
#
# Immutable.
class Shared::Config
  LOG = Pikuri.logger_for('config')
  private_constant :LOG

  # Raised for any unreadable / malformed / schema-invalid config file.
  # Carries a human-readable message naming the offending key or file.
  class Error < StandardError; end

  # One inference server: what is true of the box rather than of a model
  # running on it, referenced by {#id} from any number of +[[llm]]+ entries
  # (the class header shows the pair of tables).
  #
  # @!attribute [r] id
  #   @return [String] unique reference an +[[llm]]+ names in its +server+
  #     key; never shown to the user, never stored anywhere outside this
  #     class (see the class header).
  # @!attribute [r] url
  #   @return [String] base URL, with or without the +/v1+ suffix — pikuri
  #     normalizes both the transport's base and the throttle's key by
  #     stripping it, so either spelling names one server.
  # @!attribute [r] api_key
  #   @return [String, nil] the API key/token, stored literally, or +nil+ for
  #     a server that needs none (a local llama.cpp). Kept in this file rather
  #     than an env var on purpose: the environment is inherited by every
  #     subprocess pikuri spawns — sandboxed bash, stdio MCP servers — so a key
  #     there leaks to code the agent runs, whereas this file is read only by
  #     the parent and never exported. It also lives outside the workspace the
  #     coding agent can read. Both protections rely on the file sitting in the
  #     user/system config (see {.load}); project-local files are not loaded
  #     for exactly this reason.
  # @!attribute [r] max_concurrent_requests
  #   @return [Integer, nil] ceiling on requests in flight against this server
  #     — a +llama-server --parallel+ number — or +nil+ to let pikuri's
  #     +/props+ probe size it. See +Shared::RequestPermits+ for what the key
  #     does and does not buy.
  Server = Data.define(:id, :url, :api_key, :max_concurrent_requests)

  # One model connection: a +[[llm]]+ entry with its +[[server]]+ already
  # resolved into it, so nothing downstream has to hold the reference.
  # Every entry becomes a leader-menu model-picker choice (the bins map each
  # to a +Shared::Model::Choice+ + +ChatTransport+); the first {Config#llms}
  # entry is the boot connection.
  #
  # @!attribute [r] name
  #   @return [String] unique display name, e.g. +"Local Qwen 3.6"+.
  # @!attribute [r] server
  #   @return [String] the referenced {Server}'s {Server#url} — a base URL,
  #     never the +id+ the file wrote.
  # @!attribute [r] model
  #   @return [String] model identifier passed to the transport.
  # @!attribute [r] api_key
  #   @return [String, nil] the referenced {Server}'s {Server#api_key}, or
  #     +nil+ when that server omits it (the bins then fall back to
  #     +"not-needed"+, fine for a local llama.cpp).
  # @!attribute [r] context_window
  #   @return [Integer, nil] explicit context-window cap for this
  #     connection, or +nil+ to let pikuri auto-detect it (its llama.cpp
  #     +/props+ probe, which yields +nil+ for a non-llama server). Set it
  #     for a cloud model the probe can't reach — e.g. a 2M-window model on
  #     x.ai — so the status rule shows a real +used/cap+. Rides the connection's
  #     +Pikuri::Agent::ChatTransport+, so it is correct per-model across a
  #     model switch.
  Llm = Data.define(:name, :server, :model, :api_key, :context_window)

  # One MCP server definition (coding shell only). Exactly one of
  # {#command} (local stdio subprocess) / {#url} (remote HTTP) is
  # non-nil. Mirrors +Pikuri::Mcp::Registry+'s two entry types without
  # naming them — see the class header's "Pikuri seam" note.
  #
  # The convenience +bearer_token+ / +basic_auth+ TOML keys are not fields
  # here: they are sugar that {.build_mcp_headers} folds into {#headers} at
  # load time, so this value object exposes only the single +headers+ hash
  # that +Pikuri::Mcp::Registry::HttpEntry+ consumes 1:1.
  #
  # @!attribute [r] id
  #   @return [String] unique id the LLM uses to call +mcp_connect+.
  # @!attribute [r] command
  #   @return [Array<String>, nil] full argv to spawn a stdio server
  #     (exe first), or +nil+ for an HTTP server.
  # @!attribute [r] url
  #   @return [String, nil] endpoint URL of an HTTP server, or +nil+ for
  #     a stdio server.
  # @!attribute [r] headers
  #   @return [Hash{String => String}] HTTP headers sent on every request
  #     to an HTTP server (auth + custom), frozen. Always empty for a
  #     stdio server.
  # @!attribute [r] env
  #   @return [Hash{String => String}] extra environment variables for a
  #     stdio server's subprocess (merged over the inherited environment),
  #     frozen. Always empty for an HTTP server.
  McpServer = Data.define(:id, :command, :url, :headers, :env) do
    def initialize(id:, command: nil, url: nil, headers: {}, env: {})
      super(id: id, command: command, url: url, headers: headers.freeze, env: env.freeze)
    end

    # @return [Boolean] true for a local-subprocess (stdio) server.
    def stdio? = !command.nil?

    # @return [Boolean] true for a remote HTTP server.
    def http? = !url.nil?
  end

  # The web-search selection: which engines to search with, and the keys the
  # paid ones need (chat wires +web_search+ as a main tool; the coding /
  # computer shells wire it sub-agent-only). Every field is +nil+ when
  # omitted, which leaves pikuri's own default — DuckDuckGo plus whichever
  # keyed provider was configured.
  #
  # The keys are secrets and get the same treatment as {Server#api_key}: stored
  # literally in this parent-only file (never an env var pikuri would
  # inherit into the sandboxed bash / stdio MCP subprocesses, never a CLI
  # flag visible in +ps+), outside the workspace the coding agent reads,
  # and flagged by a logged warning when the file has loose permissions.
  #
  # Field names match +Pikuri::Tool::WebSearch.build+'s keyword arguments
  # 1:1, and both the bins and the shells rely on that: they splat
  # +search.to_h+ straight into +build+ (and into
  # +Pikuri::Tool::Search::Engines.resolve+ for the boot-time check). Keep the
  # mirror exact — a field pikuri does not take is an unknown-keyword crash at
  # wiring time (see the "Pikuri seam" note).
  #
  # @!attribute [r] brave_key
  #   @return [String, nil] Brave Search API key, or +nil+ when unset.
  # @!attribute [r] exa_key
  #   @return [String, nil] Exa API key, or +nil+ when unset.
  # @!attribute [r] engines
  #   @return [Array<String>, nil] the engines to search with — any of
  #     +duckduckgo+, +brave+, +exa+ — or +nil+ to let pikuri derive the set
  #     from the keys. A *set*, not a preference order: pikuri shuffles per
  #     query, so +["brave", "duckduckgo"]+ splits traffic between the two
  #     rather than preferring Brave. Naming an engine whose key is absent is
  #     an error pikuri raises; this class checks only the shape.
  Search = Data.define(:brave_key, :exa_key, :engines) do
    def initialize(brave_key: nil, exa_key: nil, engines: nil)
      super(brave_key: brave_key, exa_key: exa_key, engines: engines&.freeze)
    end
  end

  # The smallest file that boots — a local llama.cpp. Every "no connection
  # configured" raise quotes it, so a first run ends in a block to paste and
  # edit rather than in a backtrace.
  #
  # @return [String] a paste-ready +config.toml+, newline-terminated.
  EXAMPLE_CONFIG = <<~TOML
    [[server]]
    id  = "local"
    url = "http://localhost:8080"

    [[llm]]
    name   = "Local Qwen 3.6"
    server = "local"
    model  = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
  TOML

  # @return [Boolean] sandbox on unless a file or +--no-sandbox+ says otherwise.
  DEFAULT_SANDBOX = true
  # @return [Boolean] confirm on unless a file or +--no-confirm+ says otherwise.
  DEFAULT_CONFIRM = true
  # @return [Boolean] reasoning blocks are shown unless +[ui]+ says otherwise.
  DEFAULT_SHOW_THINKING = true
  # @return [Symbol] the tool-line form to start on; one of
  #   {Shared::ConversationTextView::TOOL_DETAIL_MODES}.
  DEFAULT_TOOL_LINES = :short

  # Config file basename and the per-app subdirectory under each XDG
  # config root.
  FILENAME   = 'config.toml'
  XDG_SUBDIR = 'pikuri'

  # Load and resolve the layered configuration.
  #
  # @param overrides [Hash{Symbol => Boolean, nil}] CLI overrides; +nil+
  #   values are ignored (treated as "flag not given"). The only recognized
  #   keys are +:sandbox+ and +:confirm+, the coding/OS safety switches —
  #   pass +false+ for +--no-sandbox+ / +--no-confirm+ / +--yolo+. Nothing
  #   about a *connection* is overridable — no server, no model (see "No
  #   connection overrides" above), and no key (a secret must never travel
  #   on the command line, visible in +ps+ and shell history); those come
  #   only from an {Llm} table in this file.
  # @param env [#[]] environment consulted for +XDG_CONFIG_HOME+ /
  #   +XDG_CONFIG_DIRS+. Defaults to +ENV+; injectable for tests.
  # @return [Config] the resolved configuration.
  # @raise [Error] on an unreadable / malformed / schema-invalid file, and
  #   when the merged result defines no +[[llm]]+ — the message then quotes
  #   {EXAMPLE_CONFIG} and the path to write it to.
  def self.load(overrides: {}, env: ENV)
    merged = {}
    any_loaded = false
    candidate_paths(env).each do |path|
      next unless File.file?(path)

      parsed = parse_file(path)
      LOG.info("loaded #{path}")
      any_loaded = true
      warn_loose_perms(path, parsed)
      merged = deep_merge(merged, parsed)
    end
    validate_top!(merged)

    servers = (merged['server'] || []).each_with_index.map { |h, i| build_server(h, i) }
    check_unique!(servers.map(&:id), 'server id')

    llm_tables = merged['llm'] || []
    raise Error, no_connection_message(any_loaded, env) if llm_tables.empty?

    by_id = servers.to_h { |s| [s.id, s] }
    llms = llm_tables.each_with_index.map { |h, i| build_llm(h, i, by_id) }
    check_unique!(llms.map(&:name), 'llm name')

    code = merged['code'] || {}
    validate_code!(code)
    mcp = (code['mcp'] || []).each_with_index.map { |h, i| build_mcp(h, i) }
    check_unique!(mcp.map(&:id), 'code.mcp id')

    ui = merged['ui'] || {}
    validate_ui!(ui)

    new(
      llms:          llms,
      servers:       servers,
      search:        build_search(merged['search']),
      sandbox:       pick(overrides[:sandbox], code['sandbox'], DEFAULT_SANDBOX),
      confirm:       pick(overrides[:confirm], code['confirm'], DEFAULT_CONFIRM),
      mcp:           mcp,
      show_thinking: pick(ui['show_thinking'], DEFAULT_SHOW_THINKING),
      tool_lines:    pick(ui['tool_lines']&.to_sym, DEFAULT_TOOL_LINES)
    )
  end

  # @param llms [Array<Llm>] one or more model connections (never empty).
  # @param servers [Array<Server>] the +[[server]]+ definitions {#llms} was
  #   resolved against. Defaults to empty: only the request throttle reads it,
  #   and a config built in code has no ceilings to install.
  # @param search [Search] web-search provider keys (fields may be nil).
  # @param sandbox [Boolean] resolved coding sandbox switch.
  # @param confirm [Boolean] resolved coding confirmer switch.
  # @param mcp [Array<McpServer>] coding-shell MCP servers (may be empty).
  # @param show_thinking [Boolean] resolved +[ui]+ reasoning-block default.
  # @param tool_lines [Symbol] resolved +[ui]+ tool-line form.
  def initialize(llms:, search:, sandbox:, confirm:, mcp:, servers: [],
                 show_thinking: DEFAULT_SHOW_THINKING, tool_lines: DEFAULT_TOOL_LINES)
    @llms    = llms.freeze
    @servers = servers.freeze
    @search  = search
    @sandbox = sandbox
    @confirm = confirm
    @mcp     = mcp.freeze
    @show_thinking = show_thinking
    @tool_lines    = tool_lines
    freeze
  end

  # @return [Array<Llm>] all configured connections, declaration order;
  #   never empty.
  attr_reader :llms
  # @return [Array<Server>] every +[[server]]+, declaration order, including
  #   any that no +[[llm]]+ references.
  attr_reader :servers
  # @return [Search] the web-search provider keys (fields may be nil).
  attr_reader :search
  # @return [Boolean] coding sandbox switch (flag > file > default).
  attr_reader :sandbox
  # @return [Boolean] coding confirmer switch (flag > file > default).
  attr_reader :confirm
  # @return [Array<McpServer>] coding-shell MCP servers, declaration order.
  attr_reader :mcp
  # @return [Boolean] whether reasoning blocks start shown (+[ui]+ > default).
  attr_reader :show_thinking
  # @return [Symbol] the tool-line form to start on (+[ui]+ > default), one of
  #   {Shared::ConversationTextView::TOOL_DETAIL_MODES}.
  attr_reader :tool_lines

  # @return [Llm] the boot connection (the first); the rest are
  #   reachable at runtime through the leader menu's model picker.
  def primary_llm = @llms.first

  # File layers, lowest priority first. +$XDG_CONFIG_DIRS+ (default
  # +/etc/xdg+) is +:+-separated with earlier entries ranking higher, so
  # we append them reversed; +$XDG_CONFIG_HOME+ (default +~/.config+)
  # outranks all of them. No project-local layer — see the class header.
  def self.candidate_paths(env)
    paths = []
    dirs = env['XDG_CONFIG_DIRS'].to_s.empty? ? '/etc/xdg' : env['XDG_CONFIG_DIRS']
    dirs.split(':').reverse_each { |d| paths << File.join(d, XDG_SUBDIR, FILENAME) }
    home = env['XDG_CONFIG_HOME'].to_s.empty? ? File.join(Dir.home, '.config') : env['XDG_CONFIG_HOME']
    paths << File.join(home, XDG_SUBDIR, FILENAME)
    paths
  end

  # Advise (non-fatally, through {LOG}) when a file carrying a literal
  # secret (an +[[llm]]+ api_key or a +[search]+ provider key) is
  # group/other-accessible — a plaintext secret should be +chmod 600+.
  # Only files that actually contain a secret are checked, so a
  # world-readable but secret-free /etc/xdg config raises no noise. Logged
  # at boot rather than collected: pikuri's default +$stderr+ sink (or the
  # bins' {Shared::Log::BufferingIO}) carries it to the diagnostic pane once a screen
  # exists, with no caller-side replay.
  def self.warn_loose_perms(path, parsed)
    return unless holds_secret?(parsed)

    mode = File.stat(path).mode
    return if (mode & 0o077).zero?

    LOG.warn("#{path} holds a literal secret but is group/other-accessible " \
             "(mode #{format('%04o', mode & 0o7777)}); run `chmod 600 #{path}`.")
  rescue SystemCallError
    # stat failed (race, odd filesystem) — skip the advisory, never fatal.
  end

  # Reads +[[server]]+ for the key, not +[[llm]]+: this check runs per file
  # and pre-merge, on raw TOML, so it sees the table the key is *written* in
  # rather than the {Llm} it is later resolved into.
  #
  # @return [Boolean] true when the parsed file carries any literal secret
  #   (a +[[server]]+ +api_key+, a +[search]+ +brave_key+/+exa_key+, or an
  #   +[[code.mcp]]+ +bearer_token+/+basic_auth+/+headers+/+env+).
  def self.holds_secret?(parsed)
    servers = parsed['server']
    return true if servers.is_a?(Array) && servers.any? { |e| e.is_a?(Hash) && e['api_key'] }

    search = parsed['search']
    return true if search.is_a?(Hash) && (search['brave_key'] || search['exa_key'])

    mcp = parsed.dig('code', 'mcp')
    mcp.is_a?(Array) && mcp.any? do |e|
      e.is_a?(Hash) && (e['bearer_token'] || e['basic_auth'] || e['headers'] || e['env'])
    end
  end

  # Parse one file, wrapping any failure (read error, TOML syntax) in
  # {Error} with the path attached — a library exception we surface at
  # boot rather than let escape as a bare backtrace.
  def self.parse_file(path)
    Tomlrb.parse(File.read(path))
  rescue StandardError => e
    raise Error, "failed to read config #{path}: #{e.class}: #{e.message}"
  end

  # Recursive merge: tables merge key-by-key; scalars and arrays take the
  # right-hand (higher-priority) value wholesale.
  def self.deep_merge(lower, higher)
    lower.merge(higher) do |_key, lo, hi|
      lo.is_a?(Hash) && hi.is_a?(Hash) ? deep_merge(lo, hi) : hi
    end
  end

  def self.validate_top!(merged)
    unknown = merged.keys - %w[server llm search code ui]
    raise Error, "unknown top-level key(s): #{unknown.join(', ')}" unless unknown.empty?
    %w[server llm].each do |k|
      next unless merged.key?(k) && !merged[k].is_a?(Array)

      raise Error, "`#{k}` must be an array of tables (use [[#{k}]], not [#{k}])"
    end
    if merged.key?('search') && !merged['search'].is_a?(Hash)
      raise Error, '`search` must be a table ([search])'
    end
    raise Error, '`code` must be a table ([code])' if merged.key?('code') && !merged['code'].is_a?(Hash)
    return unless merged.key?('ui') && !merged['ui'].is_a?(Hash)

    raise Error, '`ui` must be a table ([ui])'
  end

  # Unlike +[search]+, whose engine names are pikuri's to define, the
  # +tool_lines+ vocabulary is this app's own — so it is checked against the
  # pane's list rather than a copy that could rot.
  def self.validate_ui!(ui)
    unknown = ui.keys - %w[show_thinking tool_lines]
    raise Error, "ui: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
    if ui.key?('show_thinking') && ![true, false].include?(ui['show_thinking'])
      raise Error, 'ui.show_thinking must be true or false'
    end
    return unless ui.key?('tool_lines')

    forms = Shared::ConversationTextView::TOOL_DETAIL_MODES
    return if forms.any? { |form| form.to_s == ui['tool_lines'] }

    raise Error, "ui.tool_lines must be one of: #{forms.join(', ')}"
  end

  # Build the {Search} value object from the +[search]+ table (or +nil+
  # when the section is absent — every field then defaults to +nil+).
  # Rejects unknown keys and values of the wrong type.
  #
  # Shape only: *which* engine names are valid, and which of them need a key,
  # is pikuri's to say — the bins ask it at boot (see {Search#engines}), so
  # this class stays on the Pikuri-free side of the seam and the engine list
  # is not duplicated here to rot.
  def self.build_search(table)
    table ||= {}
    unknown = table.keys - %w[brave_key exa_key engines]
    raise Error, "search: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
    %w[brave_key exa_key].each do |k|
      raise Error, "search.#{k} must be a string" if table[k] && !table[k].is_a?(String)
    end
    engines = table['engines']
    if engines && !(engines.is_a?(Array) && engines.all?(String))
      raise Error, 'search.engines must be an array of strings, e.g. engines = ["brave"]'
    end

    Search.new(brave_key: table['brave_key'], exa_key: table['exa_key'], engines: engines)
  end

  def self.validate_code!(code)
    unknown = code.keys - %w[sandbox confirm mcp]
    raise Error, "code: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
    %w[sandbox confirm].each do |k|
      raise Error, "code.#{k} must be true or false" if code.key?(k) && ![true, false].include?(code[k])
    end
    return unless code.key?('mcp') && !code['mcp'].is_a?(Array)

    raise Error, 'code.mcp must be an array of tables (use [[code.mcp]])'
  end

  def self.build_server(hash, index)
    raise Error, "server[#{index}] must be a table" unless hash.is_a?(Hash)

    unknown = hash.keys - %w[id url api_key max_concurrent_requests]
    raise Error, "server[#{index}]: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

    id = hash['id']
    raise Error, "server[#{index}]: `id` is required and must be a non-empty string" unless non_empty_string?(id)

    url = hash['url']
    raise Error, "server #{id.inspect}: `url` is required and must be a non-empty string" unless non_empty_string?(url)

    key = hash['api_key']
    raise Error, "server #{id.inspect}: `api_key` must be a string" if key && !key.is_a?(String)

    max = hash['max_concurrent_requests']
    if max && !(max.is_a?(Integer) && max.positive?)
      raise Error, "server #{id.inspect}: `max_concurrent_requests` must be a positive integer"
    end

    Server.new(id: id, url: url, api_key: key, max_concurrent_requests: max)
  end

  # +by_id+ is every {Server} the merged file defined, so a reference resolves
  # against the whole layered set rather than the file it was written in.
  def self.build_llm(hash, index, by_id)
    raise Error, "llm[#{index}] must be a table" unless hash.is_a?(Hash)

    # +api_key+ is listed so it survives to resolve_server, which fails it with
    # a message naming its new home rather than as an anonymous unknown key.
    unknown = hash.keys - %w[name server model api_key context_window]
    raise Error, "llm[#{index}]: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

    name = hash['name']
    raise Error, "llm[#{index}]: `name` is required and must be a non-empty string" unless non_empty_string?(name)

    %w[server model].each do |k|
      next if non_empty_string?(hash[k])

      raise Error, "llm #{name.inspect}: `#{k}` is required and must be a non-empty string"
    end

    cw = hash['context_window']
    if cw && !(cw.is_a?(Integer) && cw.positive?)
      raise Error, "llm #{name.inspect}: `context_window` must be a positive integer"
    end

    key = hash['api_key']
    server = resolve_server(hash['server'], name, by_id, key)
    raise Error, "llm #{name.inspect}: `api_key` belongs on [[server]] #{server.id.inspect}, not here." if key

    Llm.new(
      name:           name,
      server:         server.url,
      model:          hash['model'],
      api_key:        server.api_key, # nil when omitted → "not-needed" at the bin
      context_window: cw # nil when omitted → pikuri auto-detects
    )
  end

  # Each way a reference can fail gets its own message, since with no compat
  # path the raise *is* the whole migration. A URL in +server+ earns the most
  # effort: it parses cleanly and fails as a *lookup*, which reads like the
  # user's mistake rather than a key whose meaning changed. The entry's stray
  # +api_key+ rides along into the suggested block, so one edit fixes both
  # halves of an old file instead of two round trips.
  def self.resolve_server(ref, name, by_id, api_key)
    found = by_id[ref]
    return found if found

    raise Error, "llm #{name.inspect}: #{server_is_now_an_id(ref, api_key)}" if ref.include?('://')
    raise Error, "llm #{name.inspect}: no [[server]] is defined — add one:\n\n#{EXAMPLE_CONFIG}" if by_id.empty?

    raise Error, "llm #{name.inspect}: unknown server id #{ref.inspect}; " \
                 "known: #{by_id.keys.map(&:inspect).join(', ')}"
  end

  def self.server_is_now_an_id(url, api_key)
    block = +"[[server]]\nid  = \"myserver\"\nurl = #{url.inspect}\n"
    block << "api_key = #{api_key.inspect}\n" if api_key
    "`server` names a [[server]] `id` now, not a URL. Add:\n\n#{block}\n" \
      "and on this [[llm]] set `server = \"myserver\"`" \
      "#{api_key ? ', dropping its `api_key`.' : '.'}"
  end

  # Covers both "no config file at all" and "a file that defines no
  # connection" — the same hole with the same fix, so one message with the
  # path to write it to.
  def self.no_connection_message(any_loaded, env)
    opening = any_loaded ? 'no [[llm]] is defined' : 'no config file found'
    "#{opening}, and there is no built-in default connection. " \
      "Write #{candidate_paths(env).last}:\n\n#{EXAMPLE_CONFIG}"
  end

  def self.build_mcp(hash, index)
    raise Error, "code.mcp[#{index}] must be a table" unless hash.is_a?(Hash)

    unknown = hash.keys - %w[id command url bearer_token basic_auth headers env]
    raise Error, "code.mcp[#{index}]: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

    id = hash['id']
    raise Error, "code.mcp[#{index}]: `id` is required and must be a non-empty string" unless non_empty_string?(id)

    command = hash['command']
    url     = hash['url']
    unless command.nil? ^ url.nil?
      raise Error, "code.mcp #{id.inspect}: set exactly one of `command` (stdio) or `url` (http)"
    end
    if command && !(command.is_a?(Array) && !command.empty? && command.all?(String))
      raise Error, "code.mcp #{id.inspect}: `command` must be a non-empty array of strings"
    end
    raise Error, "code.mcp #{id.inspect}: `url` must be a non-empty string" if url && !non_empty_string?(url)

    auth_keys = hash.keys & %w[bearer_token basic_auth headers]
    if command && !auth_keys.empty?
      raise Error, "code.mcp #{id.inspect}: #{auth_keys.map { |k| "`#{k}`" }.join(', ')} apply only to " \
                   'HTTP servers (set `url`, not `command`)'
    end
    if url && hash.key?('env')
      raise Error, "code.mcp #{id.inspect}: `env` applies only to stdio servers (set `command`, not `url`)"
    end

    McpServer.new(
      id:      id,
      command: command,
      url:     url,
      headers: build_mcp_headers(hash, id),
      env:     build_mcp_env(hash, id)
    )
  end

  # Validate and return a stdio MCP entry's +env+ table (a
  # +Hash{String => String}+ merged over the subprocess's inherited
  # environment), or +{}+ when absent.
  #
  # @param hash [Hash] the raw +[[code.mcp]]+ table.
  # @param id [String] the entry id, for error messages.
  # @return [Hash{String => String}] the env overrides (empty when none).
  # @raise [Error] when +env+ is not a table of string => string.
  def self.build_mcp_env(hash, id)
    env = hash['env']
    return {} if env.nil?
    unless env.is_a?(Hash) && env.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
      raise Error, "code.mcp #{id.inspect}: `env` must be a table of string => string"
    end

    env
  end

  # Resolve an HTTP MCP entry's auth/custom keys into the single
  # +Hash{String => String}+ +HttpEntry+ consumes. +bearer_token+ and
  # +basic_auth+ are convenience sugar that both yield an +Authorization+
  # header, so they are mutually exclusive and also conflict with an
  # explicit +Authorization+ inside +headers+; the +headers+ table carries
  # arbitrary extras verbatim.
  #
  # @param hash [Hash] the raw +[[code.mcp]]+ table.
  # @param id [String] the entry id, for error messages.
  # @return [Hash{String => String}] the merged headers (empty when none).
  # @raise [Error] on a malformed +headers+/+bearer_token+/+basic_auth+
  #   value or an +Authorization+ conflict.
  def self.build_mcp_headers(hash, id)
    headers = {}

    custom = hash['headers']
    unless custom.nil?
      unless custom.is_a?(Hash) && custom.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
        raise Error, "code.mcp #{id.inspect}: `headers` must be a table of string => string"
      end
      headers.merge!(custom)
    end

    bearer = hash['bearer_token']
    basic  = hash['basic_auth']
    raise Error, "code.mcp #{id.inspect}: set at most one of `bearer_token` or `basic_auth`" if bearer && basic

    auth =
      if bearer
        raise Error, "code.mcp #{id.inspect}: `bearer_token` must be a non-empty string" unless non_empty_string?(bearer)

        "Bearer #{bearer}"
      elsif basic
        build_basic_auth(basic, id)
      end
    return headers unless auth

    if headers.keys.any? { |k| k.casecmp?('Authorization') }
      raise Error, "code.mcp #{id.inspect}: `bearer_token`/`basic_auth` conflicts with an `Authorization` " \
                   'entry in `headers` — set only one'
    end
    headers['Authorization'] = auth
    headers
  end

  # Build the +Authorization: Basic+ value from a +basic_auth+ table.
  # Encodes +username:password+ with strict (newline-free) Base64 via
  # +Array#pack+ so no +base64+ require is needed.
  #
  # @param basic [Object] the raw +basic_auth+ value (expected a table).
  # @param id [String] the entry id, for error messages.
  # @return [String] the full +"Basic <base64>"+ header value.
  # @raise [Error] when +basic_auth+ is not a table with a non-empty
  #   +username+ and a +password+ string.
  def self.build_basic_auth(basic, id)
    raise Error, "code.mcp #{id.inspect}: `basic_auth` must be a table" unless basic.is_a?(Hash)

    unknown = basic.keys - %w[username password]
    raise Error, "code.mcp #{id.inspect}: basic_auth unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

    username = basic['username']
    password = basic['password']
    unless non_empty_string?(username) && password.is_a?(String)
      raise Error, "code.mcp #{id.inspect}: `basic_auth` needs a non-empty `username` and a `password` string"
    end

    "Basic #{["#{username}:#{password}"].pack('m0')}"
  end

  # First non-nil value — precedence resolution that treats +false+ as a
  # real value (so a +sandbox = false+ in a file is not skipped).
  def self.pick(*values) = values.find { |v| !v.nil? }

  def self.check_unique!(values, label)
    dups = values.tally.select { |_, n| n > 1 }.keys
    raise Error, "duplicate #{label}(s): #{dups.join(', ')}" unless dups.empty?
  end

  def self.non_empty_string?(value) = value.is_a?(String) && !value.strip.empty?

  private_class_method :candidate_paths, :warn_loose_perms, :holds_secret?, :parse_file, :deep_merge,
                       :validate_top!, :validate_code!, :build_server, :build_llm, :resolve_server,
                       :server_is_now_an_id, :no_connection_message, :build_mcp, :build_mcp_headers,
                       :build_basic_auth, :build_mcp_env, :build_search,
                       :pick, :check_unique!, :non_empty_string?
end
