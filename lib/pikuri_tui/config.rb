# frozen_string_literal: true

require 'tomlrb'

module PikuriTui
  # Layered TOML configuration shared by both shells.
  #
  # Hosts the resolved config values (the model connections, the coding
  # shell's sandbox / confirm switches, and its MCP server list), loads
  # them from the XDG config search path, and overlays the command-line
  # overrides the bins pass in. One {Config} is built once at boot, before
  # the screen is up, and read from there on.
  #
  # == Precedence
  #
  # Lowest to highest: built-in defaults → +/etc/xdg/pikuri/config.toml+
  # (each +$XDG_CONFIG_DIRS+ entry, earlier = higher) →
  # +$XDG_CONFIG_HOME/pikuri/config.toml+ (default +~/.config+) → CLI
  # overrides. Files merge deeply (tables key-by-key); arrays — the
  # +[[llm]]+ list and the +[[code.mcp]]+ list — replace wholesale, nearest
  # file wins. CLI overrides sit on top of all of it.
  #
  # There is deliberately no project-local layer: a config file inside the
  # repo would be git-committable and readable by the sandboxed coding
  # agent — exactly where a literal {Llm#api_key} must not live.
  #
  # == The Pikuri seam
  #
  # This class is eager-loaded by BOTH shells, including the chat shell,
  # whose +Bundler.setup(:default)+ never puts +pikuri-mcp+ on the load
  # path. So {Config} stays free of every +Pikuri::*+ reference: MCP
  # servers surface as plain {McpServer} value objects whose field names
  # ({McpServer#id} / +command+ / +url+) match +Pikuri::Mcp::Registry+'s
  # entries 1:1, and the coding bin does the trivial pass-through into
  # +Registry::StdioEntry+ / +Registry::HttpEntry+. Translation lives in
  # the wiring layer where +Pikuri::*+ is allowed, not here.
  #
  # == Errors
  #
  # Every load failure — unreadable file, malformed TOML, schema
  # violation — raises {Error}. Loading runs at boot before the screen is
  # up, so the bins rescue {Error} into a plain +warn+ + +exit+ rather
  # than the usual route-to-LogWindow path (there is no LogWindow yet).
  class Config
    # Raised for any unreadable / malformed / schema-invalid config file.
    # Carries a human-readable message naming the offending key or file.
    class Error < StandardError; end

    # One model connection. The TUI will switch between several by {#name}
    # in the future; for now the first {Config#llms} entry is used.
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
    Llm = Data.define(:name, :server, :model, :api_key)

    # One MCP server definition (coding shell only). Exactly one of
    # {#command} (local stdio subprocess) / {#url} (remote HTTP) is
    # non-nil. Mirrors +Pikuri::Mcp::Registry+'s two entry types without
    # naming them — see the class header's "Pikuri seam" note.
    #
    # @!attribute [r] id
    #   @return [String] unique id the LLM uses to call +mcp_connect+.
    # @!attribute [r] command
    #   @return [Array<String>, nil] full argv to spawn a stdio server
    #     (exe first), or +nil+ for an HTTP server.
    # @!attribute [r] url
    #   @return [String, nil] endpoint URL of an HTTP server, or +nil+ for
    #     a stdio server.
    McpServer = Data.define(:id, :command, :url) do
      # @return [Boolean] true for a local-subprocess (stdio) server.
      def stdio? = !command.nil?

      # @return [Boolean] true for a remote HTTP server.
      def http? = !url.nil?
    end

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
      warnings = []
      candidate_paths(env).each do |path|
        next unless File.file?(path)

        parsed = parse_file(path)
        warn_loose_perms(path, parsed, warnings)
        merged = deep_merge(merged, parsed)
      end
      validate_top!(merged)

      llm_tables = merged['llm'] || []
      llms = llm_tables.empty? ? [default_llm] : llm_tables.each_with_index.map { |h, i| build_llm(h, i) }
      check_unique!(llms.map(&:name), 'llm name')

      code = merged['code'] || {}
      validate_code!(code)
      mcp = (code['mcp'] || []).each_with_index.map { |h, i| build_mcp(h, i) }
      check_unique!(mcp.map(&:id), 'code.mcp id')

      new(
        llms:     apply_llm_overrides(llms, overrides),
        sandbox:  pick(overrides[:sandbox], code['sandbox'], DEFAULT_SANDBOX),
        confirm:  pick(overrides[:confirm], code['confirm'], DEFAULT_CONFIRM),
        mcp:      mcp,
        warnings: warnings
      )
    end

    # @param llms [Array<Llm>] one or more model connections (never empty).
    # @param sandbox [Boolean] resolved coding sandbox switch.
    # @param confirm [Boolean] resolved coding confirmer switch.
    # @param mcp [Array<McpServer>] coding-shell MCP servers (may be empty).
    # @param warnings [Array<String>] non-fatal load advisories.
    def initialize(llms:, sandbox:, confirm:, mcp:, warnings: [])
      @llms     = llms.freeze
      @sandbox  = sandbox
      @confirm  = confirm
      @mcp      = mcp.freeze
      @warnings = warnings.freeze
      freeze
    end

    # @return [Array<Llm>] all configured connections, declaration order.
    attr_reader :llms
    # @return [Boolean] coding sandbox switch (flag > file > default).
    attr_reader :sandbox
    # @return [Boolean] coding confirmer switch (flag > file > default).
    attr_reader :confirm
    # @return [Array<McpServer>] coding-shell MCP servers, declaration order.
    attr_reader :mcp

    # @return [Array<String>] non-fatal advisories raised while loading
    #   (e.g. a file holding a literal api_key with loose permissions). The
    #   bins surface these through the diagnostic log.
    attr_reader :warnings

    # @return [Llm] the connection both shells use for now (the first).
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

    # Advise (non-fatally) when a file carrying a literal api_key is
    # group/other-accessible — a plaintext secret should be +chmod 600+.
    # Only files that actually contain a secret are checked, so a
    # world-readable but secret-free /etc/xdg config raises no noise.
    def self.warn_loose_perms(path, parsed, warnings)
      llms = parsed['llm']
      return unless llms.is_a?(Array) && llms.any? { |e| e.is_a?(Hash) && e['api_key'] }

      mode = File.stat(path).mode
      return if (mode & 0o077).zero?

      warnings << "#{path} holds a literal api_key but is group/other-accessible " \
                  "(mode #{format('%04o', mode & 0o7777)}); run `chmod 600 #{path}`."
    rescue SystemCallError
      # stat failed (race, odd filesystem) — skip the advisory, never fatal.
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
      unknown = merged.keys - %w[llm code]
      raise Error, "unknown top-level key(s): #{unknown.join(', ')}" unless unknown.empty?
      if merged.key?('llm') && !merged['llm'].is_a?(Array)
        raise Error, '`llm` must be an array of tables (use [[llm]], not [llm])'
      end
      return unless merged.key?('code') && !merged['code'].is_a?(Hash)

      raise Error, '`code` must be a table ([code])'
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

      unknown = hash.keys - %w[name server model api_key]
      raise Error, "llm[#{index}]: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

      name = hash['name']
      raise Error, "llm[#{index}]: `name` is required and must be a non-empty string" unless non_empty_string?(name)

      %w[server model api_key].each do |k|
        raise Error, "llm #{name.inspect}: `#{k}` must be a string" if hash[k] && !hash[k].is_a?(String)
      end

      Llm.new(
        name:    name,
        server:  hash['server'] || DEFAULT_SERVER,
        model:   hash['model'] || DEFAULT_MODEL,
        api_key: hash['api_key'] # nil when omitted → "not-needed" at the bin
      )
    end

    def self.build_mcp(hash, index)
      raise Error, "code.mcp[#{index}] must be a table" unless hash.is_a?(Hash)

      forbidden = hash.keys & %w[headers env]
      unless forbidden.empty?
        raise Error, "code.mcp[#{index}]: `#{forbidden.join('`, `')}` is not supported in this version " \
                     '(no MCP auth headers / stdio env yet)'
      end
      unknown = hash.keys - %w[id command url]
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

      McpServer.new(id: id, command: command, url: url)
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
      Llm.new(name: DEFAULT_LLM_NAME, server: DEFAULT_SERVER, model: DEFAULT_MODEL, api_key: nil)
    end

    # First non-nil value — precedence resolution that treats +false+ as a
    # real value (so a +sandbox = false+ in a file is not skipped).
    def self.pick(*values) = values.find { |v| !v.nil? }

    def self.check_unique!(values, label)
      dups = values.tally.select { |_, n| n > 1 }.keys
      raise Error, "duplicate #{label}(s): #{dups.join(', ')}" unless dups.empty?
    end

    def self.non_empty_string?(value) = value.is_a?(String) && !value.strip.empty?

    private_class_method :candidate_paths, :warn_loose_perms, :parse_file, :deep_merge, :validate_top!,
                         :validate_code!, :build_llm, :build_mcp, :apply_llm_overrides, :default_llm, :pick,
                         :check_unique!, :non_empty_string?
  end
end
