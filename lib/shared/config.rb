# frozen_string_literal: true

require 'tomlrb'
require 'typemap'

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
# == +params+, and the siblings' tables
#
#   [[llm]]
#   name   = "Local Qwen 3.6, no thinking"
#   server = "local"
#   model  = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
#   params = { chat_template_kwargs = { enable_thinking = false } }
#
#   [titler]              # which connection pikuri-web writes titles on;
#   llm = "qwen-titler"   # exposed nowhere here, these shells title nothing
#
#   [web]                 # the one password gating pikuri-web when it is
#   user     = "mavi"     # bound off loopback; a terminal shell has no
#   password = "…"        # port for anyone to knock on
#
# {Llm#params} is an opaque table of extra chat-completion payload keys, sent
# as written on that connection — the spelling being per-model-per-server,
# pikuri translates none of it. It rides the connection's
# +Pikuri::Agent::ChatTransport+ as {Llm#context_window} does, so it survives
# a model switch.
#
# +[titler]+ and +[web]+ are the shared keys nothing here reads: one file
# serves every pikuri shell, so this is the whole shared schema rather than the
# part these three use, and a table a sibling owns is parsed, logged as unread
# at load, and acted on in no way.
#
# Ownership also picks the strictness. A table these shells read is strict,
# because an unknown +[ui]+ key is a typo the user wants named; a sibling's is
# checked for shape only, so pikuri-web growing a second +[titler]+ key cannot
# stop this app from booting — the bargain its own +[ui]+ validation takes in
# the other direction.
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
# diagnostic log dialog when it rewires +Pikuri.log_io+. {Config} just logs;
# it never collects advisories for the caller to surface.
#
# == The file's shape
#
# Typemap maps the merged TOML onto {Root} and the classes nested in it, and
# checks every value against the type its YARD tag gives (read back from
# +sig/pikuri_tui.rbs+, which +rake sig+ generates). Typemap's limits add
# non-blank names and unique ids; a class's +validate+ keeps only what no limit
# can say, "exactly one of +command+ / +url+" and the like. {.load} then resolves the file's shape into the values
# the shells read: each {LlmTable} with its {Server} looked up becomes an {Llm},
# each {McpTable} with its auth sugar folded into +headers+ becomes an
# {McpServer}. {Server} and {Search} already match the file and pass through.
#
# == Errors
#
# Every load failure — unreadable file, malformed TOML, schema violation —
# raises {Error}. A schema message starts with the offending value's path, an
# array entry named after its index by its +entry_name+:
#
#   llm[1] "Grok 4 Fast".context_window: must be at least 1, got 0
#   code.mcp[0] "github": set exactly one of `command` (stdio) or `url` (http)
#
# Loading runs at boot before the screen is up, so the bins rescue {Error}
# into a plain +warn+ + +exit+ rather than the usual route-to-log-dialog path
# (there is no log dialog yet).
#
# Immutable.
class Shared::Config
  # @return [Logger]
  LOG = Pikuri.logger_for('config')
  private_constant :LOG

  # Raised for any unreadable / malformed / schema-invalid config file.
  # Carries a human-readable message naming the offending key or file.
  class Error < StandardError; end

  # @return [Boolean] sandbox on unless a file or +--no-sandbox+ says otherwise.
  DEFAULT_SANDBOX = true
  # @return [Boolean] confirm on unless a file or +--no-confirm+ says otherwise.
  DEFAULT_CONFIRM = true
  # @return [Boolean] reasoning blocks are shown unless +[ui]+ says otherwise.
  DEFAULT_SHOW_THINKING = true
  # @return [Symbol] the tool-line form to start on; one of
  #   {Shared::ConversationTextView::TOOL_DETAIL_MODES}.
  DEFAULT_TOOL_LINES = :short

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
  Server = Data.define(:id, :url, :api_key, :max_concurrent_requests) do
    extend Typemap::Constrain

    constrain :id, :url, not_blank: true
    constrain :max_concurrent_requests, in: (1..)

    # @param id [String] see {#id}
    # @param url [String] see {#url}
    # @param api_key [String, nil] see {#api_key}
    # @param max_concurrent_requests [Integer, nil] see {#max_concurrent_requests}
    def initialize(id:, url:, api_key: nil, max_concurrent_requests: nil) = super

    # Names the entry in a schema error, +server[1] "grok".url: required+.
    #
    # @param raw [Hash{String => Object}] the entry as the file wrote it, unchecked
    # @return [Object] its +id+, which Typemap strips; a blank or missing one
    #   leaves the bare index
    def self.entry_name(raw) = raw['id']
  end

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
  # @!attribute [r] params
  #   @return [Hash{String => Object}] extra request parameters merged into
  #     every chat completion on this connection, verbatim — e.g.
  #     +{"chat_template_kwargs" => {"enable_thinking" => false}}+ to turn
  #     Qwen 3.6's reasoning off. Frozen, and +{}+ when the entry omits it.
  Llm = Data.define(:name, :server, :model, :api_key, :context_window, :params) do
    # @param name [String] see {#name}
    # @param server [String] see {#server}
    # @param model [String] see {#model}
    # @param api_key [String, nil] see {#api_key}
    # @param context_window [Integer, nil] see {#context_window}
    # @param params [Hash{String => Object}] see {#params}; frozen here
    def initialize(name:, server:, model:, api_key:, context_window:, params: {})
      super(name:, server:, model:, api_key:, context_window:, params: params.freeze)
    end
  end

  # One MCP server definition (coding shell only). Exactly one of
  # {#command} (local stdio subprocess) / {#url} (remote HTTP) is
  # non-nil. Mirrors +Pikuri::Mcp::Registry+'s two entry types without
  # naming them — see the class header's "Pikuri seam" note.
  #
  # The convenience +bearer_token+ / +basic_auth+ TOML keys are not fields
  # here: {McpTable#resolve} folds them into {#headers}, so this value object
  # exposes only the single +headers+ hash that
  # +Pikuri::Mcp::Registry::HttpEntry+ consumes 1:1.
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
    # @param id [String] see {#id}
    # @param command [Array<String>, nil] see {#command}
    # @param url [String, nil] see {#url}
    # @param headers [Hash{String => String}] see {#headers}; frozen here
    # @param env [Hash{String => String}] see {#env}; frozen here
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
  # Field names match +Pikuri::Web::Search.build+'s keyword arguments
  # 1:1, and both the bins and the shells rely on that: they splat
  # +search.to_h+ straight into +build+ (and into
  # +Pikuri::Web::Search::Engines.resolve+ for the boot-time check). Keep the
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
  #     an error pikuri raises; which names exist is pikuri's to say too, so
  #     the file is checked for shape only and no engine list here can rot.
  Search = Data.define(:brave_key, :exa_key, :engines) do
    # @param brave_key [String, nil] see {#brave_key}
    # @param exa_key [String, nil] see {#exa_key}
    # @param engines [Array<String>, nil] see {#engines}; frozen here
    def initialize(brave_key: nil, exa_key: nil, engines: nil)
      super(brave_key: brave_key, exa_key: exa_key, engines: engines&.freeze)
    end
  end

  # One +[[llm]]+ table as the file writes it; {.load} resolves it into an {Llm}.
  #
  # @!attribute [r] name
  #   @return [String] see {Llm#name}
  # @!attribute [r] server
  #   @return [String] the {Server#id} this model runs on
  # @!attribute [r] model
  #   @return [String] see {Llm#model}
  # @!attribute [r] api_key
  #   @return [String, nil] never valid here: read only so {.load} can name the
  #     +[[server]]+ it belongs on, where an unknown-key error would not
  # @!attribute [r] context_window
  #   @return [Integer, nil] see {Llm#context_window}
  # @!attribute [r] params
  #   @return [Hash{String => Object}] see {Llm#params}; checked to be a table,
  #     its contents the server's business
  LlmTable = Data.define(:name, :server, :model, :api_key, :context_window, :params) do
    extend Typemap::Constrain

    constrain :name, :server, :model, not_blank: true
    constrain :context_window, in: (1..)

    # @param name [String] see {#name}
    # @param server [String] see {#server}
    # @param model [String] see {#model}
    # @param api_key [String, nil] see {#api_key}
    # @param context_window [Integer, nil] see {#context_window}
    # @param params [Hash{String => Object}] see {#params}
    def initialize(name:, server:, model:, api_key: nil, context_window: nil, params: {}) = super

    # @param raw [Hash{String => Object}] see {Server.entry_name}
    # @return [Object] its +name+
    def self.entry_name(raw) = raw['name']
  end

  # A +[[code.mcp]]+ entry's +basic_auth+ table.
  #
  # @!attribute [r] username
  #   @return [String] non-blank
  # @!attribute [r] password
  #   @return [String]
  BasicAuth = Data.define(:username, :password) do
    extend Typemap::Constrain

    constrain :username, not_blank: true

    # @return [String] the +Authorization+ value, strict (newline-free) Base64
    #   through +Array#pack+, so no +base64+ require
    def header = "Basic #{["#{username}:#{password}"].pack('m0')}"
  end

  # One +[[code.mcp]]+ table as the file writes it; {#resolve} turns it into
  # the {McpServer} the coding bin hands to pikuri-mcp.
  #
  # +bearer_token+ and +basic_auth+ are sugar for an +Authorization+ header,
  # so they exclude each other and an +Authorization+ entry in +headers+.
  #
  # @!attribute [r] id
  #   @return [String] see {McpServer#id}
  # @!attribute [r] command
  #   @return [Array<String>, nil] see {McpServer#command}
  # @!attribute [r] url
  #   @return [String, nil] see {McpServer#url}
  # @!attribute [r] bearer_token
  #   @return [String, nil] becomes +Authorization: Bearer …+
  # @!attribute [r] basic_auth
  #   @return [BasicAuth, nil] becomes +Authorization: Basic …+
  # @!attribute [r] headers
  #   @return [Hash{String => String}, nil] extra HTTP headers, sent verbatim
  # @!attribute [r] env
  #   @return [Hash{String => String}, nil] see {McpServer#env}
  McpTable = Data.define(:id, :command, :url, :bearer_token, :basic_auth, :headers, :env) do
    extend Typemap::Constrain

    constrain :id, :url, :bearer_token, not_blank: true
    constrain :command, not_empty: true

    # @param id [String] see {#id}
    # @param command [Array<String>, nil] see {#command}
    # @param url [String, nil] see {#url}
    # @param bearer_token [String, nil] see {#bearer_token}
    # @param basic_auth [BasicAuth, nil] see {#basic_auth}
    # @param headers [Hash{String => String}, nil] see {#headers}
    # @param env [Hash{String => String}, nil] see {#env}
    def initialize(id:, command: nil, url: nil, bearer_token: nil, basic_auth: nil, headers: nil, env: nil) = super

    # @param raw [Hash{String => Object}] see {Server.entry_name}
    # @return [Object] its +id+
    def self.entry_name(raw) = raw['id']

    # @return [void]
    # @raise [RuntimeError] on a stdio/HTTP mix-up, or two sources for
    #   +Authorization+
    def validate
      raise 'set exactly one of `command` (stdio) or `url` (http)' unless command.nil? ^ url.nil?

      http_only = { bearer_token:, basic_auth:, headers: }.compact.keys
      if command && !http_only.empty?
        raise "#{http_only.map { |k| "`#{k}`" }.join(', ')} apply only to HTTP servers (set `url`, not `command`)"
      end
      raise '`env` applies only to stdio servers (set `command`, not `url`)' if url && env
      raise 'set at most one of `bearer_token` or `basic_auth`' if bearer_token && basic_auth
      return unless (bearer_token || basic_auth) && headers&.keys&.any? { |k| k.casecmp?('Authorization') }

      raise '`bearer_token`/`basic_auth` conflicts with an `Authorization` entry in `headers` — set only one'
    end

    # @return [McpServer] this entry with its auth sugar folded into +headers+
    def resolve
      auth = bearer_token ? "Bearer #{bearer_token}" : basic_auth&.header
      all_headers = headers || {}
      all_headers = all_headers.merge('Authorization' => auth) if auth
      McpServer.new(id:, command:, url:, headers: all_headers, env: env || {})
    end
  end

  # The +[code]+ table.
  #
  # @!attribute [r] sandbox
  #   @return [Boolean] see {Config#sandbox}; a CLI flag outranks it
  # @!attribute [r] confirm
  #   @return [Boolean] see {Config#confirm}; a CLI flag outranks it
  # @!attribute [r] mcp
  #   @return [Array<McpTable>] the +[[code.mcp]]+ entries, ids unique
  CodeTable = Data.define(:sandbox, :confirm, :mcp) do
    extend Typemap::Constrain

    constrain :mcp, unique_by: :id

    # @param sandbox [Boolean] see {#sandbox}
    # @param confirm [Boolean] see {#confirm}
    # @param mcp [Array<McpTable>] see {#mcp}
    def initialize(sandbox: DEFAULT_SANDBOX, confirm: DEFAULT_CONFIRM, mcp: []) = super
  end

  # The +[ui]+ table (the class header has the why).
  #
  # @!attribute [r] show_thinking
  #   @return [Boolean] see {Config#show_thinking}
  # @!attribute [r] tool_lines
  #   @return [String] see {Config#tool_lines}; checked against the pane's own
  #     list rather than a copy here that could rot
  UiTable = Data.define(:show_thinking, :tool_lines) do
    extend Typemap::Constrain

    constrain :tool_lines, in: Shared::ConversationTextView::TOOL_DETAIL_MODES.map(&:to_s)

    # @param show_thinking [Boolean] see {#show_thinking}
    # @param tool_lines [String] see {#tool_lines}
    def initialize(show_thinking: DEFAULT_SHOW_THINKING, tool_lines: DEFAULT_TOOL_LINES.to_s) = super
  end

  # The whole file, every table at its default when the file leaves it out.
  #
  # @!attribute [r] server
  #   @return [Array<Server>] the +[[server]]+ entries, ids unique
  # @!attribute [r] llm
  #   @return [Array<LlmTable>] the +[[llm]]+ entries, names unique
  # @!attribute [r] search
  #   @return [Search] the +[search]+ table
  # @!attribute [r] code
  #   @return [CodeTable] the +[code]+ table
  # @!attribute [r] ui
  #   @return [UiTable] the +[ui]+ table
  # @!attribute [r] titler
  #   @return [Hash{String => Object}, nil] pikuri-web's table, checked for
  #     shape only (see the class header)
  # @!attribute [r] web
  #   @return [Hash{String => Object}, nil] pikuri-web's table, checked for
  #     shape only
  Root = Data.define(:server, :llm, :search, :code, :ui, :titler, :web) do
    extend Typemap::Constrain

    constrain :server, unique_by: :id
    constrain :llm, unique_by: :name

    # @param server [Array<Server>] see {#server}
    # @param llm [Array<LlmTable>] see {#llm}
    # @param search [Search] see {#search}
    # @param code [CodeTable] see {#code}
    # @param ui [UiTable] see {#ui}
    # @param titler [Hash{String => Object}, nil] see {#titler}
    # @param web [Hash{String => Object}, nil] see {#web}
    def initialize(server: [], llm: [], search: Search.new, code: CodeTable.new, ui: UiTable.new,
                   titler: nil, web: nil)
      super
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

  # @return [String] the config file's basename.
  FILENAME   = 'config.toml'
  # @return [String] the per-app subdirectory under each XDG config root.
  XDG_SUBDIR = 'pikuri'

  # Types come from sig/ (the YARD tags, through sord), so each is written once.
  #
  # @return [Typemap::Mapper]
  MAPPER = Typemap::Mapper.new(types: Typemap::Mapper::RBSTypes.new)
  private_constant :MAPPER

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

    root = map(merged)
    raise Error, no_connection_message(any_loaded, env) if root.llm.empty?

    log_unread_tables(root)
    by_id = root.server.to_h { |s| [s.id, s] }
    new(
      llms:          root.llm.map { |table| resolve_llm(table, by_id) },
      servers:       root.server,
      search:        root.search,
      sandbox:       overrides[:sandbox].nil? ? root.code.sandbox : overrides[:sandbox],
      confirm:       overrides[:confirm].nil? ? root.code.confirm : overrides[:confirm],
      mcp:           root.code.mcp.map(&:resolve),
      show_thinking: root.ui.show_thinking,
      tool_lines:    root.ui.tool_lines.to_sym
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
  #
  # @param env [#[]] see {.load}
  # @return [Array<String>] the file paths, lowest priority first
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
  #
  # @param path [String] the file just read
  # @param parsed [Hash{String => Object}] its raw TOML
  # @return [void]
  def self.warn_loose_perms(path, parsed)
    return unless holds_secret?(parsed)

    mode = File.stat(path).mode
    return if (mode & 0o077).zero?

    LOG.warn("#{path} holds a literal secret but is group/other-accessible " \
             "(mode #{format('%04o', mode & 0o7777)}); run `chmod 600 #{path}`.")
  rescue SystemCallError => e
    # A race or an odd filesystem: the advisory is a courtesy, never fatal.
    LOG.debug("skipped the permissions check of #{path}: #{e.message}")
  end

  # Reads +[[server]]+ for the key, not +[[llm]]+: this check runs per file
  # and pre-merge, on raw TOML, so it sees the table the key is *written* in
  # rather than the {Llm} it is later resolved into.
  #
  # @param parsed [Hash{String => Object}] one file's raw TOML
  # @return [Boolean] true when the parsed file carries any literal secret
  #   (a +[[server]]+ +api_key+, a +[search]+ +brave_key+/+exa_key+, or an
  #   +[[code.mcp]]+ +bearer_token+/+basic_auth+/+headers+/+env+).
  def self.holds_secret?(parsed)
    servers = parsed['server']
    return true if servers.is_a?(Array) && servers.any? { |e| e.is_a?(Hash) && e['api_key'] }

    search = parsed['search']
    return true if search.is_a?(Hash) && (search['brave_key'] || search['exa_key'])

    code = parsed['code']
    mcp = code['mcp'] if code.is_a?(Hash)
    mcp.is_a?(Array) && mcp.any? do |e|
      e.is_a?(Hash) && (e['bearer_token'] || e['basic_auth'] || e['headers'] || e['env'])
    end
  end

  # Parse one file, wrapping any failure (read error, TOML syntax) in
  # {Error} with the path attached — a library exception we surface at
  # boot rather than let escape as a bare backtrace.
  #
  # @param path [String] the file to read
  # @return [Hash{String => Object}] its raw TOML
  # @raise [Error] when the file can't be read or isn't valid TOML
  def self.parse_file(path)
    Tomlrb.parse(File.read(path))
  rescue StandardError => e
    raise Error, "failed to read config #{path}: #{e.class}: #{e.message}"
  end

  # Recursive merge: tables merge key-by-key; scalars and arrays take the
  # right-hand (higher-priority) value wholesale.
  #
  # @param lower [Hash{String => Object}] the farther file's tables
  # @param higher [Hash{String => Object}] the nearer file's, winning every conflict
  # @return [Hash{String => Object}] a new Hash; neither argument is modified
  def self.deep_merge(lower, higher)
    lower.merge(higher) do |_key, lo, hi|
      lo.is_a?(Hash) && hi.is_a?(Hash) ? deep_merge(lo, hi) : hi
    end
  end

  # @param merged [Hash{String => Object}] the merged TOML
  # @return [Root]
  # @raise [Error] on any schema violation, its message starting with the
  #   offending value's path
  def self.map(merged)
    MAPPER.load(Root, merged, source: :toml)
  rescue Typemap::DataError => e
    raise Error, e.message
  end

  # Log one line per table this shell parses and never acts on, so an ignored
  # table says so in the diagnostic pane instead of silently doing nothing.
  # INFO, not WARN: the file is shared, and a table written for pikuri-web is
  # doing its job there.
  #
  # @param root [Root] the mapped file
  # @return [void]
  def self.log_unread_tables(root)
    LOG.info('ignoring [titler]: pikuri-web names conversations, these shells hold one') if root.titler
    LOG.info('ignoring [web]: pikuri-web serves a port, these shells serve nobody') if root.web
  end

  # @param table [LlmTable] one +[[llm]]+ entry
  # @param by_id [Hash{String => Server}] every +[[server]]+, by id — the
  #   whole layered set, not just the file the entry was written in
  # @return [Llm]
  # @raise [Error] on a +server+ that resolves to nothing, or a stray +api_key+
  def self.resolve_llm(table, by_id)
    server = resolve_server(table.server, table.name, by_id, table.api_key)
    if table.api_key
      raise Error, "llm #{table.name.inspect}: `api_key` belongs on [[server]] #{server.id.inspect}, not here."
    end

    Llm.new(
      name:           table.name,
      server:         server.url,
      model:          table.model,
      api_key:        server.api_key, # nil when omitted → "not-needed" at the bin
      context_window: table.context_window, # nil when omitted → pikuri auto-detects
      params:         table.params
    )
  end

  # Each way a reference can fail gets its own message, since with no compat
  # path the raise *is* the whole migration. A URL in +server+ earns the most
  # effort: it parses cleanly and fails as a *lookup*, which reads like the
  # user's mistake rather than a key whose meaning changed. The entry's stray
  # +api_key+ rides along into the suggested block, so one edit fixes both
  # halves of an old file instead of two round trips.
  #
  # @param ref [String] the entry's +server+ value
  # @param name [String] the entry's +name+, for messages
  # @param by_id [Hash{String => Server}] every +[[server]]+, by id
  # @param api_key [String, nil] the entry's stray +api_key+, quoted in the migration hint
  # @return [Server] the referenced server
  # @raise [Error] when +ref+ names no server
  def self.resolve_server(ref, name, by_id, api_key)
    found = by_id[ref]
    return found if found

    raise Error, "llm #{name.inspect}: #{server_is_now_an_id(ref, api_key)}" if ref.include?('://')
    raise Error, "llm #{name.inspect}: no [[server]] is defined — add one:\n\n#{EXAMPLE_CONFIG}" if by_id.empty?

    raise Error, "llm #{name.inspect}: unknown server id #{ref.inspect}; " \
                 "known: #{by_id.keys.map(&:inspect).join(', ')}"
  end

  # @param url [String] the URL the old-format entry wrote in +server+
  # @param api_key [String, nil] the entry's stray +api_key+
  # @return [String] the error message, a paste-ready +[[server]]+ block included
  def self.server_is_now_an_id(url, api_key)
    block = +"[[server]]\nid  = \"myserver\"\nurl = #{url.inspect}\n"
    block << "api_key = #{api_key.inspect}\n" if api_key
    "`server` names a [[server]] `id` now, not a URL. Add:\n\n#{block}\n" \
      'and on this [[llm]] set `server = "myserver"`' \
      "#{api_key ? ', dropping its `api_key`.' : '.'}"
  end

  # Covers both "no config file at all" and "a file that defines no
  # connection" — the same hole with the same fix, so one message with the
  # path to write it to.
  #
  # @param any_loaded [Boolean] whether any config file was found
  # @param env [#[]] see {.load}
  # @return [String] the error message, {EXAMPLE_CONFIG} included
  def self.no_connection_message(any_loaded, env)
    opening = any_loaded ? 'no [[llm]] is defined' : 'no config file found'
    "#{opening}, and there is no built-in default connection. " \
      "Write #{candidate_paths(env).last}:\n\n#{EXAMPLE_CONFIG}"
  end

  private_class_method :candidate_paths, :warn_loose_perms, :holds_secret?, :parse_file, :deep_merge, :map,
                       :log_unread_tables, :resolve_llm, :resolve_server, :server_is_now_an_id,
                       :no_connection_message
end
