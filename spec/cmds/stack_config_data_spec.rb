# frozen_string_literal: true

require 'spec_helper'

# The CLI owns the boundary mapping: --stack-config= names a path, the
# stack's :config collection expects data. Resolution is a selector over
# atomic documents: the flag asserts and never falls back; the convention
# layers are standing lookups where absence means the next layer; one
# source wins whole — layers never contribute keys to one another.
RSpec.describe 'stack_config_data' do
  let(:cmd) { Class.new { include Matsuri::Cmd }.new }

  def stack_config_data(opt, name = nil)
    cmd.send(:stack_config_data, opt, name)
  end

  it 'answers the empty value when no flag was given and no convention is declared' do
    expect(stack_config_data({})).to be_nil
  end

  it 'loads the artifact whole, with indifferent access' do
    data = stack_config_data(stack_config: File.join(FIXTURE_ROOT, 'stack-config.yaml'))

    expect(data[:name]).to eq 'app-feat-checkout'
    expect(data[:log_level]).to eq 'debug'
    expect(data[:expires_at]).to eq '2026-11-15'
  end

  it 'fails loudly on a bad path' do
    expect { stack_config_data(stack_config: 'no-such-file.yaml') }
      .to raise_error(SystemExit).and output(/stack-config not found/).to_stdout
  end

  context 'with a convention root declared on the environment' do
    before do
      @saved_env = Matsuri::Platform.dev
      Matsuri::Platform.dev = Map.new(namespace: 'specs', stack_config_root: 'stack-configs')
    end

    after do
      Matsuri::Platform.dev = @saved_env
    end

    it 'resolves the pair document, <root>/<environment>/<stack>.yaml' do
      data = stack_config_data({}, 'app-with-config')

      expect(data[:source]).to eq 'pair-document'
    end

    it 'selects, never merges: the winning document is the whole answer' do
      data = stack_config_data({}, 'app-with-config')

      expect(data[:contact]).to be_nil
    end

    it 'falls to the environment document when the stack has no pair document' do
      data = stack_config_data({}, 'app-without-config')

      expect(data[:source]).to eq 'environment-document'
    end

    it 'skips the pair probe when no stack name was given' do
      data = stack_config_data({}, :not_specified)

      expect(data[:source]).to eq 'environment-document'
    end

    it 'lets the flag assert over the convention' do
      data = stack_config_data({ stack_config: File.join(FIXTURE_ROOT, 'stack-config.yaml') }, 'app-with-config')

      expect(data[:name]).to eq 'app-feat-checkout'
    end

    it 'fails loudly on a bad flag path even when the convention could resolve' do
      expect { stack_config_data({ stack_config: 'no-such-file.yaml' }, 'app-with-config') }
        .to raise_error(SystemExit).and output(/stack-config not found/).to_stdout
    end

    it 'answers the empty value when the chain exhausts' do
      Matsuri::Platform.dev = Map.new(namespace: 'specs', stack_config_root: 'no-such-dir')

      expect(stack_config_data({}, 'app-with-config')).to be_nil
    end
  end
end
