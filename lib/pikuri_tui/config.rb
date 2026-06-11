# frozen_string_literal: true

require 'tomlrb'

module PikuriTui
  # Layered TOML configuration shared by both shells.
  #
  # Hosts the resolved config values (the model connections, the
  # web-search provider keys, the coding shell's sandbox / confirm
  # switches, and its MCP server list), loads them from the XDG config
  # search path, and overlays the command-line overrides the bins pass in.
  # One {Config} is built once at boot, before the screen is up, and read
  # from there on.
  #
  # == Precedence
  #
  # Lowest to highest: built-in defaults → +/etc/xdg/pikuri/config.toml+
  # (each +$XDG_CONFIG_DIRS+ entry, earlier = higher) →
  # +$XDG_CONFIG_HOME/pikuri/config.toml+ (default +~/.config+) → CLI
  # overrides. Files merge deeply (tables key-by-key); arrays — the
  # +[[llm]]+ list and the +[[code.mcp]]+ list — replace wholesale, nearest
  # file wins. CLI overrides sit on top of all of it. The +[search]+ table
  # merges key-by-key like any table, so a system file can supply
  # +brave_key+ while the user file adds +exa_key+.
  #
  # There is deliberately no project-local layer: a config file inside the
  # repo would be git-committable and readable by the sandboxed coding
  # agent — exactly where a literal {Llm#api_key} or {Search} provider key
  # must not live.
  #
  # == The Pikuri seam
  #
  # This class is eager-loaded by BOTH shells, including the chat shell,
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
  # +progname+-tagged), which both shells load (+pikuri-core+ is in the
  # +:default+ group). +Pikuri.log_io+ defaults to +$stderr+, so these lines
  # surface immediately at boot — before any screen exists. The bins install a
  # {BufferingLogIO} as that boot sink, which tees to +$stderr+ and retains
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
  class Config
    LOG = Pikuri.logger_for('config')
    private_constant :LOG

    # Raised for any unreadable / malformed / schema-invalid config file.
    # Carries a human-readable message naming the offending key or file.
    class Error < StandardError; end

    # One model connection. Every entry becomes a +Ctrl+P+ model-picker
    # choice (the bins map each to a +ModelChoice+ + +ChatTransport+); the
    # first {Config#llms} entry is the boot connection.
    #
    # @!attribute [r] name
    #   @return [String] unique display name, e.g. +"Local Qwen 3.6"+.
    # @!attribute [r] server
    #   @return [String] LLM server base URL (no +/v1+ suffix).
    # @!attribute [r] model
    #   @return [String] model identifier passed to the transport.
    # @!attribute [r] api_key
    #   @return [String, nil] the API key/token, stored literally, or +nil+
    #     when the entry omits it (the bins then fall back to +"not-needed"+,
    #     fine for a local llama.cpp). Kept in this file rather than an env
    #     var on purpose: the environment is inherited by every subprocess
    #     pikuri spawns — sandboxed bash, stdio MCP servers — so a key there
    #     leaks to code the agent runs, whereas this file is read only by the
    #     parent and never exported. It also lives outside the workspace the
    #     coding agent can read. Both protections rely on the file sitting in
    #     the user/system config (see {.load}); project-local files are not
    #     loaded for exactly this reason.
    # @!attribute [r] context_window
    #   @return [Integer, nil] explicit context-window cap for this
    #     connection, or +nil+ to let pikuri auto-detect it (its llama.cpp
    #     +/props+ probe, which yields +nil+ for a non-llama server). Set it
    #     for a cloud model the probe can't reach — e.g. a 2M-window model on
    #     x.ai — so the footer shows a real +used/cap+. Rides the connection's
    #     +Pikuri::Agent::ChatTransport+, so it is correct per-model across a
    #     +Ctrl+P+ switch.
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

    # The web-search provider keys, shared by both shells (chat wires
    # +web_search+ as a main tool, the coding shell as a sub-agent-only
    # tool). Both fields are +nil+ when omitted; pikuri's search cascade
    # then runs DuckDuckGo-only and the paid provider simply stays out.
    #
    # These are secrets and get the same treatment as {Llm#api_key}: stored
    # literally in this parent-only file (never an env var pikuri would
    # inherit into the sandboxed bash / stdio MCP subprocesses, never a CLI
    # flag visible in +ps+), outside the workspace the coding agent reads,
    # and flagged by a logged warning when the file has loose permissions.
    # Field names match +Pikuri::Tool::WebSearch.build+'s keyword arguments
    # 1:1 — the bins pass them straight through (see the "Pikuri seam" note).
    #
    # @!attribute [r] brave_key
    #   @return [String, nil] Brave Search API key, or +nil+ when unset.
    # @!attribute [r] exa_key
    #   @return [String, nil] Exa API key, or +nil+ when unset.
    Search = Data.define(:brave_key, :exa_key)

    # @return [String] display name of the synthetic default connection.
    DEFAULT_LLM_NAME = 'Local Qwen 3.6'
    # @return [String] default LLM server base URL (local llama.cpp).
    DEFAULT_SERVER = 'http://localhost:8080'
    # @return [String] default model identifier.
    DEFAULT_MODEL = 'unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M'
    # @return [Boolean] sandbox on unless a file or +--no-sandbox+ says otherwise.
    DEFAULT_SANDBOX = true
    # @return [Boolean] confirm on unless a file or +--no-confirm+ says otherwise.
    DEFAULT_CONFIRM = true

    # Config file basename and the per-app subdirectory under each XDG
    # config root.
    FILENAME   = 'config.toml'
    XDG_SUBDIR = 'pikuri'

    # Load and resolve the layered configuration.
    #
    # @param overrides [Hash{Symbol => String, Boolean, nil}] CLI
    #   overrides; +nil+ values are ignored (treated as "flag not given").
    #   Recognized keys: +:server+, +:model+ (each overrides the field of
    #   the primary {Llm}); +:sandbox+, +:confirm+ (override the coding
    #   switches — pass +false+ for +--no-sandbox+ / +--no-confirm+ /
    #   +--yolo+). There is no key override: a secret must never travel on
    #   the command line (visible in +ps+ and shell history) — it comes
    #   only from {Llm#api_key} in this file.
    # @param env [#[]] environment consulted for +XDG_CONFIG_HOME+ /
    #   +XDG_CONFIG_DIRS+. Defaults to +ENV+; injectable for tests.
    # @return [Config] the resolved configuration.
    # @raise [Error] on an unreadable / malformed / schema-invalid file.
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
      LOG.info('no config file found; using built-in defaults') unless any_loaded
      validate_top!(merged)

      llm_tables = merged['llm'] || []
      llms = llm_tables.empty? ? [default_llm] : llm_tables.each_with_index.map { |h, i| build_llm(h, i) }
      check_unique!(llms.map(&:name), 'llm name')

      code = merged['code'] || {}
      validate_code!(code)
      mcp = (code['mcp'] || []).each_with_index.map { |h, i| build_mcp(h, i) }
      check_unique!(mcp.map(&:id), 'code.mcp id')

      new(
        llms:    apply_llm_overrides(llms, overrides),
        search:  build_search(merged['search']),
        sandbox: pick(overrides[:sandbox], code['sandbox'], DEFAULT_SANDBOX),
        confirm: pick(overrides[:confirm], code['confirm'], DEFAULT_CONFIRM),
        mcp:     mcp
      )
    end

    # @param llms [Array<Llm>] one or more model connections (never empty).
    # @param search [Search] web-search provider keys (fields may be nil).
    # @param sandbox [Boolean] resolved coding sandbox switch.
    # @param confirm [Boolean] resolved coding confirmer switch.
    # @param mcp [Array<McpServer>] coding-shell MCP servers (may be empty).
    def initialize(llms:, search:, sandbox:, confirm:, mcp:)
      @llms    = llms.freeze
      @search  = search
      @sandbox = sandbox
      @confirm = confirm
      @mcp     = mcp.freeze
      freeze
    end

    # @return [Array<Llm>] all configured connections, declaration order.
    attr_reader :llms
    # @return [Search] the web-search provider keys (fields may be nil).
    attr_reader :search
    # @return [Boolean] coding sandbox switch (flag > file > default).
    attr_reader :sandbox
    # @return [Boolean] coding confirmer switch (flag > file > default).
    attr_reader :confirm
    # @return [Array<McpServer>] coding-shell MCP servers, declaration order.
    attr_reader :mcp

    # @return [Llm] the boot connection (the first); the rest are
    #   reachable at runtime through the +Ctrl+P+ model picker.
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
    # bins' {BufferingLogIO}) carries it to the diagnostic pane once a screen
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

    # @return [Boolean] true when the parsed file carries any literal secret
    #   (an +[[llm]]+ +api_key+, a +[search]+ +brave_key+/+exa_key+, or an
    #   +[[code.mcp]]+ +bearer_token+/+basic_auth+/+headers+/+env+).
    def self.holds_secret?(parsed)
      llms = parsed['llm']
      return true if llms.is_a?(Array) && llms.any? { |e| e.is_a?(Hash) && e['api_key'] }

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
      unknown = merged.keys - %w[llm search code]
      raise Error, "unknown top-level key(s): #{unknown.join(', ')}" unless unknown.empty?
      if merged.key?('llm') && !merged['llm'].is_a?(Array)
        raise Error, '`llm` must be an array of tables (use [[llm]], not [llm])'
      end
      if merged.key?('search') && !merged['search'].is_a?(Hash)
        raise Error, '`search` must be a table ([search])'
      end
      return unless merged.key?('code') && !merged['code'].is_a?(Hash)

      raise Error, '`code` must be a table ([code])'
    end

    # Build the {Search} value object from the +[search]+ table (or +nil+
    # when the section is absent — both keys then default to +nil+). Rejects
    # unknown keys and non-string values.
    def self.build_search(table)
      table ||= {}
      unknown = table.keys - %w[brave_key exa_key]
      raise Error, "search: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
      %w[brave_key exa_key].each do |k|
        raise Error, "search.#{k} must be a string" if table[k] && !table[k].is_a?(String)
      end

      Search.new(brave_key: table['brave_key'], exa_key: table['exa_key'])
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

    def self.build_llm(hash, index)
      raise Error, "llm[#{index}] must be a table" unless hash.is_a?(Hash)

      unknown = hash.keys - %w[name server model api_key context_window]
      raise Error, "llm[#{index}]: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

      name = hash['name']
      raise Error, "llm[#{index}]: `name` is required and must be a non-empty string" unless non_empty_string?(name)

      %w[server model api_key].each do |k|
        raise Error, "llm #{name.inspect}: `#{k}` must be a string" if hash[k] && !hash[k].is_a?(String)
      end

      cw = hash['context_window']
      if cw && !(cw.is_a?(Integer) && cw.positive?)
        raise Error, "llm #{name.inspect}: `context_window` must be a positive integer"
      end

      Llm.new(
        name:           name,
        server:         hash['server'] || DEFAULT_SERVER,
        model:          hash['model'] || DEFAULT_MODEL,
        api_key:        hash['api_key'], # nil when omitted → "not-needed" at the bin
        context_window: cw # nil when omitted → pikuri auto-detects
      )
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

    # Overlay the primary-connection CLI overrides. A +nil+ override keeps
    # the loaded/default value. Only the first {Llm} is touched — it is the
    # one both shells use today.
    def self.apply_llm_overrides(llms, overrides)
      return llms unless overrides[:server] || overrides[:model]

      primary = llms.first.with(
        server: overrides[:server] || llms.first.server,
        model:  overrides[:model] || llms.first.model
      )
      [primary, *llms[1..]]
    end

    def self.default_llm
      Llm.new(name: DEFAULT_LLM_NAME, server: DEFAULT_SERVER, model: DEFAULT_MODEL, api_key: nil,
              context_window: nil)
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
                         :validate_top!, :validate_code!, :build_llm, :build_mcp, :build_mcp_headers,
                         :build_basic_auth, :build_mcp_env, :build_search, :apply_llm_overrides, :default_llm,
                         :pick, :check_unique!, :non_empty_string?
  end
end
