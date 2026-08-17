# frozen_string_literal: true

require 'tmpdir'

RSpec.describe Shared::FileCommands do
  # A real Registry over real files: the mapping's whole job is faithfully
  # relaying what pikuri scanned (refusals, argument hints, expansion), so
  # stubbing the registry would test nothing.
  around do |example|
    Dir.mktmpdir('pikuri-file-commands') do |dir|
      @base = dir
      example.run
    end
  end

  before { fake_screen }
  after  { Tuile::Screen.close }

  let(:expanded) { [] }
  let(:warnings) { [] }
  let(:logger)   { Class.new { define_method(:warn) { |m| @sink << m } }.new }

  def write(name, body, frontmatter: nil)
    path = File.join(@base, '.claude/commands', "#{name}.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, frontmatter ? "---\n#{frontmatter}\n---\n#{body}" : body)
  end

  def build(reserved: [])
    logger.instance_variable_set(:@sink, warnings)
    described_class.build(
      registry: Pikuri::Command::Registry.new(search_bases: [@base]),
      reserved: reserved, screen: Tuile::Screen.instance, logger: logger,
      on_expand: ->(text) { expanded << text }
    )
  end

  it 'names a command by its path and takes the description as the palette hint' do
    write('wh', 'Weekly log.', frontmatter: 'description: weekly work log')
    command = build.first
    assert_equal '/wh', command.name
    assert_equal 'weekly work log', command.description
  end

  it 'leads the hint with the argument hint, so you can see what to type next' do
    write('wh', 'Weekly log.', frontmatter: "description: weekly work log\nargument-hint: <label>")
    assert_equal '<label> — weekly work log', build.first.description
  end

  it 'addresses a nested command by its path, colon-joined' do
    FileUtils.mkdir_p(File.join(@base, '.claude/commands/frontend'))
    File.write(File.join(@base, '.claude/commands/frontend/deploy.md'), 'Ship it.')
    assert_equal ['/frontend:deploy'], build.map(&:name)
  end

  it 'expands the template against the rest of the line and drives it as a user turn' do
    write('wh', 'Weekly log for $ARGUMENTS, Monday through today.')
    assert_nil build.first.callback.call('swingai') # no echo; the turn is the record
    assert_equal ['Weekly log for swingai, Monday through today.'], expanded
  end

  it 'appends the arguments when the body references no placeholder' do
    write('wh', 'Weekly log.')
    build.first.callback.call('swingai')
    assert_includes expanded.first, 'ARGUMENTS: swingai'
  end

  describe 'a command pikuri refuses' do
    before { write('deploy', 'Ship it.', frontmatter: 'allowed-tools: Bash') }

    it 'stays listed, marked unavailable' do
      assert_equal ['/deploy'], build.map(&:name)
      assert_includes build.first.description, '(unavailable)'
    end

    it 'answers with the reason instead of running' do
      outcome = build.first.callback.call('')
      assert_includes outcome, 'allowed-tools'
      assert_empty expanded
    end
  end

  describe 'a name a built-in already took' do
    before { write('plan', 'Definitely not the read-only toggle.') }

    it 'is dropped, so a cloned repo cannot capture a safety verb' do
      assert_empty build(reserved: ['/plan'])
    end

    it 'says so in the diagnostic log' do
      build(reserved: ['/plan'])
      assert_equal 1, warnings.size
      assert_includes warnings.first, 'shadows a built-in'
    end
  end
end
