require 'test/unit'
require 'tempfile'
require 'unicorn/configurator'

class TestConfigurator < Test::Unit::TestCase

  def test_config_defaults
    assert_nothing_raised { Unicorn::Configurator.new {} }
  end

  def test_config_invalid
    tmp = Tempfile.new('unicorn_config')
    tmp.syswrite(%q(asdfasdf "hello-world"))
    assert_raises(NoMethodError) do
      Unicorn::Configurator.new(:config_file => tmp.path)
    end
  end

  def test_config_non_existent
    tmp = Tempfile.new('unicorn_config')
    path = tmp.path
    tmp.close!
    assert_raises(Errno::ENOENT) do
      Unicorn::Configurator.new(:config_file => path)
    end
  end

  def test_config_defaults
    cfg = Unicorn::Configurator.new(:use_defaults => true)
    assert_nothing_raised { cfg.commit!(self) }
    Unicorn::Configurator::DEFAULTS.each do |key,value|
      assert_equal value, instance_variable_get("@#{key.to_s}")
    end
  end

  def test_config_defaults_skip
    cfg = Unicorn::Configurator.new(:use_defaults => true)
    skip = [ :logger ]
    assert_nothing_raised { cfg.commit!(self, :skip => skip) }
    @logger = nil
    Unicorn::Configurator::DEFAULTS.each do |key,value|
      next if skip.include?(key)
      assert_equal value, instance_variable_get("@#{key.to_s}")
    end
    assert_nil @logger
  end

  def test_listen_options
    tmp = Tempfile.new('unicorn_config')
    expect = { :sndbuf => 1, :rcvbuf => 2, :backlog => 10 }.freeze
    listener = "127.0.0.1:12345"
    tmp.syswrite("listen '#{listener}', #{expect.inspect}\n")
    cfg = nil
    assert_nothing_raised do
      cfg = Unicorn::Configurator.new(:config_file => tmp.path)
    end
    assert_nothing_raised { cfg.commit!(self) }
    assert(listener_opts = instance_variable_get("@listener_opts"))
    assert_equal expect, listener_opts[listener]
  end

  def test_listen_option_bad
    tmp = Tempfile.new('unicorn_config')
    expect = { :sndbuf => "five" }
    listener = "127.0.0.1:12345"
    tmp.syswrite("listen '#{listener}', #{expect.inspect}\n")
    assert_raises(ArgumentError) do
      Unicorn::Configurator.new(:config_file => tmp.path)
    end
  end

end
