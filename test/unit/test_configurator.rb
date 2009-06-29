require 'test/unit'
require 'tempfile'
require 'unicorn'

class TestConfigurator < Test::Unit::TestCase

  def test_config_init
    assert_nothing_raised { Unicorn::Configurator.new {} }
  end

  def test_expand_addr
    meth = Unicorn::Configurator.new.method(:expand_addr)

    assert_equal "/var/run/unicorn.sock", meth.call("/var/run/unicorn.sock")
    assert_equal "#{Dir.pwd}/foo/bar.sock", meth.call("unix:foo/bar.sock")

    path = meth.call("~/foo/bar.sock")
    assert_equal "/", path[0..0]
    assert_match %r{/foo/bar\.sock\z}, path

    path = meth.call("~root/foo/bar.sock")
    assert_equal "/", path[0..0]
    assert_match %r{/foo/bar\.sock\z}, path

    assert_equal "1.2.3.4:2007", meth.call('1.2.3.4:2007')
    assert_equal "0.0.0.0:2007", meth.call('0.0.0.0:2007')
    assert_equal "0.0.0.0:2007", meth.call(':2007')
    assert_equal "0.0.0.0:2007", meth.call('*:2007')
    assert_equal "0.0.0.0:2007", meth.call('2007')
    assert_equal "0.0.0.0:2007", meth.call(2007)
    assert_match %r{\A\d+\.\d+\.\d+\.\d+:2007\z}, meth.call('1:2007')
    assert_match %r{\A\d+\.\d+\.\d+\.\d+:2007\z}, meth.call('2:2007')
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
      next if key == :stream_input
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
      next if key == :stream_input
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

  def test_after_fork_proc
    [ proc { |a,b| }, Proc.new { |a,b| }, lambda { |a,b| } ].each do |my_proc|
      Unicorn::Configurator.new(:after_fork => my_proc).commit!(self)
      assert_equal my_proc, @after_fork
    end
  end

  def test_after_fork_wrong_arity
    [ proc { |a| }, Proc.new { }, lambda { |a,b,c| } ].each do |my_proc|
      assert_raises(ArgumentError) do
        Unicorn::Configurator.new(:after_fork => my_proc)
      end
    end
  end

end
