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

end
