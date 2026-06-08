# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

# Specs for the layered TOML config loader. Each example drives
# PikuriTui::Config.load with an injected env (so XDG vars never touch the
# host) and temp dirs for the file layers — the same seams the loader
# exposes for exactly this.
describe PikuriTui::Config do
  # Run the block with two empty temp dirs (an XDG_CONFIG_HOME and a
  # project dir), and a writer that drops TOML into either one.
  def with_dirs
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |proj|
        yield(home, proj)
      end
    end
  end

  def write_toml(dir, subdir, body)
    FileUtils.mkdir_p(File.join(dir, subdir))
    File.write(File.join(dir, subdir, described_class::FILENAME), body)
  end

  # Load with no files present and the given overrides.
  def load_bare(**overrides)
    described_class.load(overrides: overrides, env: {}, project_dir: '/nonexistent')
  end

  describe 'defaults (no files)' do
    it 'synthesizes the default Local Qwen connection' do
      c = load_bare
      assert_equal 1, c.llms.size
      assert_equal described_class::DEFAULT_LLM_NAME, c.primary_llm.name
      assert_equal described_class::DEFAULT_SERVER, c.primary_llm.server
      assert_equal described_class::DEFAULT_MODEL, c.primary_llm.model
      assert_equal described_class::DEFAULT_API_KEY_ENV, c.primary_llm.api_key_env
    end

    it 'defaults the coding switches on and the mcp list empty' do
      c = load_bare
      assert c.sandbox
      assert c.confirm
      assert_empty c.mcp
    end
  end

  describe 'CLI overrides (highest precedence)' do
    it 'overrides the primary connection fields, leaving others intact' do
      c = load_bare(server: 'http://host:9', model: 'm2')
      assert_equal 'http://host:9', c.primary_llm.server
      assert_equal 'm2', c.primary_llm.model
      # untouched fields keep their resolved values
      assert_equal described_class::DEFAULT_API_KEY_ENV, c.primary_llm.api_key_env
    end

    it 'treats false sandbox/confirm overrides as real values (not "absent")' do
      c = load_bare(sandbox: false, confirm: false)
      refute c.sandbox
      refute c.confirm
    end

    it 'wins over a file value' do
      with_dirs do |home, _proj|
        write_toml(home, 'pikuri', "[code]\nsandbox = true\n")
        c = described_class.load(overrides: { sandbox: false }, env: { 'XDG_CONFIG_HOME' => home },
                                 project_dir: '/nonexistent')
        refute c.sandbox
      end
    end
  end

  describe 'file loading' do
    it 'reads [[llm]] entries and an absent api_key_env resolves to nil' do
      with_dirs do |home, _proj|
        write_toml(home, 'pikuri', <<~TOML)
          [[llm]]
          name = "Remote"
          server = "https://api.example.com"
          model = "big"
        TOML
        c = described_class.load(env: { 'XDG_CONFIG_HOME' => home }, project_dir: '/nonexistent')
        assert_equal 'Remote', c.primary_llm.name
        assert_nil c.primary_llm.api_key_env
      end
    end

    it 'builds stdio and http MCP servers' do
      with_dirs do |home, _proj|
        write_toml(home, 'pikuri', <<~TOML)
          [[code.mcp]]
          id = "playwright"
          command = ["npx", "@playwright/mcp@latest"]

          [[code.mcp]]
          id = "remote"
          url = "https://mcp.example.com/v1"
        TOML
        c = described_class.load(env: { 'XDG_CONFIG_HOME' => home }, project_dir: '/nonexistent')
        assert_equal 2, c.mcp.size
        assert c.mcp[0].stdio?
        assert_equal %w[npx @playwright/mcp@latest], c.mcp[0].command
        assert c.mcp[1].http?
        assert_equal 'https://mcp.example.com/v1', c.mcp[1].url
      end
    end
  end

  describe 'layering' do
    it 'deep-merges tables so a project file adding mcp keeps the user file sandbox' do
      with_dirs do |home, proj|
        write_toml(home, 'pikuri', "[code]\nsandbox = false\n")
        write_toml(proj, '.pikuri', "[[code.mcp]]\nid = \"x\"\nurl = \"u\"\n")
        c = described_class.load(env: { 'XDG_CONFIG_HOME' => home }, project_dir: proj)
        refute c.sandbox            # survives from the user file
        assert_equal 1, c.mcp.size  # added by the project file
      end
    end

    it 'lets the project file override a scalar from the user file' do
      with_dirs do |home, proj|
        write_toml(home, 'pikuri', "[code]\nconfirm = true\n")
        write_toml(proj, '.pikuri', "[code]\nconfirm = false\n")
        c = described_class.load(env: { 'XDG_CONFIG_HOME' => home }, project_dir: proj)
        refute c.confirm
      end
    end
  end

  describe 'validation' do
    def expect_error(body)
      with_dirs do |home, _proj|
        write_toml(home, 'pikuri', body)
        assert_raises(described_class::Error) do
          described_class.load(env: { 'XDG_CONFIG_HOME' => home }, project_dir: '/nonexistent')
        end
      end
    end

    it 'rejects unsupported MCP auth headers' do
      e = expect_error("[[code.mcp]]\nid = \"x\"\nurl = \"u\"\nheaders = { a = \"b\" }")
      assert_includes e.message, 'not supported'
    end

    it 'rejects an MCP entry with both command and url' do
      e = expect_error("[[code.mcp]]\nid = \"x\"\ncommand = [\"a\"]\nurl = \"u\"")
      assert_includes e.message, 'exactly one'
    end

    it 'rejects an MCP entry with neither command nor url' do
      e = expect_error("[[code.mcp]]\nid = \"x\"")
      assert_includes e.message, 'exactly one'
    end

    it 'rejects duplicate llm names' do
      e = expect_error("[[llm]]\nname = \"a\"\n[[llm]]\nname = \"a\"")
      assert_includes e.message, 'duplicate'
    end

    it 'rejects duplicate mcp ids' do
      e = expect_error("[[code.mcp]]\nid = \"a\"\nurl = \"u\"\n[[code.mcp]]\nid = \"a\"\nurl = \"u2\"")
      assert_includes e.message, 'duplicate'
    end

    it 'rejects an unknown top-level key' do
      e = expect_error("foo = 1")
      assert_includes e.message, 'unknown top-level'
    end

    it 'rejects an llm entry without a name' do
      e = expect_error("[[llm]]\nserver = \"s\"")
      assert_includes e.message, '`name` is required'
    end

    it 'rejects a non-boolean sandbox' do
      e = expect_error("[code]\nsandbox = \"yes\"")
      assert_includes e.message, 'true or false'
    end

    it 'wraps malformed TOML in Config::Error' do
      e = expect_error("this is = = not toml")
      assert_includes e.message, 'failed to read'
    end
  end
end
