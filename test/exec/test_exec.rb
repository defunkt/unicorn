# Copyright (c) 2009 Eric Wong
STDIN.sync = STDOUT.sync = STDERR.sync = true
require 'test/test_helper'
require 'pathname'
require 'tempfile'
require 'fileutils'

do_test = true
DEFAULT_TRIES = 1000
DEFAULT_RES = 0.2

$unicorn_bin = ENV['UNICORN_TEST_BIN'] || "unicorn"
redirect_test_io do
  do_test = system($unicorn_bin, '-v')
end

unless do_test
  STDERR.puts "#{$unicorn_bin} not found in PATH=#{ENV['PATH']}, " \
              "skipping this test"
end

begin
  require 'rack'
rescue LoadError
  STDERR.puts "Unable to load Rack, skipping this test"
  do_test = false
end

class ExecTest < Test::Unit::TestCase
  trap(:QUIT, 'IGNORE')

  HI = <<-EOS
use Rack::ContentLength
run proc { |env| [ 200, { 'Content-Type' => 'text/plain' }, [ "HI\\n" ] ] }
  EOS

  HELLO = <<-EOS
class Hello
  def call(env)
    [ 200, { 'Content-Type' => 'text/plain' }, [ "HI\\n" ] ]
  end
end
  EOS

  COMMON_TMP = Tempfile.new('unicorn_tmp') unless defined?(COMMON_TMP)

  HEAVY_CFG = <<-EOS
worker_processes 4
timeout 30
logger Logger.new('#{COMMON_TMP.path}')
before_fork do |server, worker_nr|
  server.logger.info "before_fork: worker=\#{worker_nr}"
end
  EOS

  def setup
    @pwd = Dir.pwd
    @tmpfile = Tempfile.new('unicorn_exec_test')
    @tmpdir = @tmpfile.path
    @tmpfile.close!
    Dir.mkdir(@tmpdir)
    Dir.chdir(@tmpdir)
    @addr = ENV['UNICORN_TEST_ADDR'] || '127.0.0.1'
    @port = unused_port(@addr)
    @sockets = []
    @start_pid = $$
  end

  def teardown
    return if @start_pid != $$
    Dir.chdir(@pwd)
    FileUtils.rmtree(@tmpdir)
    @sockets.each { |path| File.unlink(path) rescue nil }
    loop do
      Process.kill('-QUIT', 0)
      begin
        Process.waitpid(-1, Process::WNOHANG) or break
      rescue Errno::ECHILD
        break
      end
    end
  end

  def test_basic
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = fork do
      redirect_test_io { exec($unicorn_bin, "-l", "#{@addr}:#{@port}") }
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_help
    redirect_test_io do
      assert(system($unicorn_bin, "-h"), "help text returns true")
    end
    assert_equal 0, File.stat("test_stderr.#$$.log").size
    assert_not_equal 0, File.stat("test_stdout.#$$.log").size
    lines = File.readlines("test_stdout.#$$.log")

    # Be considerate of the on-call technician working from their
    # mobile phone or netbook on a slow connection :)
    assert lines.size <= 24, "help height fits in an ANSI terminal window"
    lines.each do |line|
      assert line.size <= 80, "help width fits in an ANSI terminal window"
    end
  end

  def test_broken_reexec_config
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid_file = "#{@tmpdir}/test.pid"
    old_file = "#{pid_file}.oldbin"
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen %(#@addr:#@port)\n")
    ucfg.syswrite("pid %(#{pid_file})\n")
    ucfg.syswrite("logger Logger.new(%(#{@tmpdir}/log))\n")
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-D", "-l#{@addr}:#{@port}", "-c#{ucfg.path}")
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class

    wait_for_file(pid_file)
    Process.waitpid(pid)
    Process.kill(:USR2, File.read(pid_file).to_i)
    wait_for_file(old_file)
    wait_for_file(pid_file)
    old_pid = File.read(old_file).to_i
    Process.kill(:QUIT, old_pid)
    wait_for_death(old_pid)

    ucfg.syswrite("timeout %(#{pid_file})\n") # introduce a bug
    current_pid = File.read(pid_file).to_i
    Process.kill(:USR2, current_pid)

    # wait for pid_file to restore itself
    tries = DEFAULT_TRIES
    begin
      while current_pid != File.read(pid_file).to_i
        sleep(DEFAULT_RES) and (tries -= 1) > 0
      end
    rescue Errno::ENOENT
      (sleep(DEFAULT_RES) and (tries -= 1) > 0) and retry
    end
    assert_equal current_pid, File.read(pid_file).to_i

    tries = DEFAULT_TRIES
    while File.exist?(old_file)
      (sleep(DEFAULT_RES) and (tries -= 1) > 0) or break
    end
    assert ! File.exist?(old_file), "oldbin=#{old_file} gone"
    port2 = unused_port(@addr)

    # fix the bug
    ucfg.sysseek(0)
    ucfg.truncate(0)
    ucfg.syswrite("listen %(#@addr:#@port)\n")
    ucfg.syswrite("listen %(#@addr:#{port2})\n")
    ucfg.syswrite("pid %(#{pid_file})\n")
    assert_nothing_raised { Process.kill(:USR2, current_pid) }

    wait_for_file(old_file)
    wait_for_file(pid_file)
    new_pid = File.read(pid_file).to_i
    assert_not_equal current_pid, new_pid
    assert_equal current_pid, File.read(old_file).to_i
    results = retry_hit(["http://#{@addr}:#{@port}/",
                         "http://#{@addr}:#{port2}/"])
    assert_equal String, results[0].class
    assert_equal String, results[1].class

    assert_nothing_raised do
      Process.kill(:QUIT, current_pid)
      Process.kill(:QUIT, new_pid)
    end
  end

  def test_broken_reexec_ru
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid_file = "#{@tmpdir}/test.pid"
    old_file = "#{pid_file}.oldbin"
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("pid %(#{pid_file})\n")
    ucfg.syswrite("logger Logger.new(%(#{@tmpdir}/log))\n")
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-D", "-l#{@addr}:#{@port}", "-c#{ucfg.path}")
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class

    wait_for_file(pid_file)
    Process.waitpid(pid)
    Process.kill(:USR2, File.read(pid_file).to_i)
    wait_for_file(old_file)
    wait_for_file(pid_file)
    old_pid = File.read(old_file).to_i
    Process.kill(:QUIT, old_pid)
    wait_for_death(old_pid)

    File.unlink("config.ru") # break reloading
    current_pid = File.read(pid_file).to_i
    Process.kill(:USR2, current_pid)

    # wait for pid_file to restore itself
    tries = DEFAULT_TRIES
    begin
      while current_pid != File.read(pid_file).to_i
        sleep(DEFAULT_RES) and (tries -= 1) > 0
      end
    rescue Errno::ENOENT
      (sleep(DEFAULT_RES) and (tries -= 1) > 0) and retry
    end
    assert_equal current_pid, File.read(pid_file).to_i

    tries = DEFAULT_TRIES
    while File.exist?(old_file)
      (sleep(DEFAULT_RES) and (tries -= 1) > 0) or break
    end
    assert ! File.exist?(old_file), "oldbin=#{old_file} gone"

    # fix the bug
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    assert_nothing_raised { Process.kill(:USR2, current_pid) }
    wait_for_file(old_file)
    wait_for_file(pid_file)
    new_pid = File.read(pid_file).to_i
    assert_not_equal current_pid, new_pid
    assert_equal current_pid, File.read(old_file).to_i
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class

    assert_nothing_raised do
      Process.kill(:QUIT, current_pid)
      Process.kill(:QUIT, new_pid)
    end
  end

  def test_unicorn_config_listen_with_options
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen '#{@addr}:#{@port}', :backlog => 512,\n")
    ucfg.syswrite("                            :rcvbuf => 4096,\n")
    ucfg.syswrite("                            :sndbuf => 4096\n")
    pid = xfork do
      redirect_test_io { exec($unicorn_bin, "-c#{ucfg.path}") }
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_unicorn_config_listen_augments_cli
    port2 = unused_port(@addr)
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen '#{@addr}:#{@port}'\n")
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-c#{ucfg.path}", "-l#{@addr}:#{port2}")
      end
    end
    uris = [@port, port2].map { |i| "http://#{@addr}:#{i}/" }
    results = retry_hit(uris)
    assert_equal results.size, uris.size
    assert_equal String, results[0].class
    assert_equal String, results[1].class
    assert_shutdown(pid)
  end

  def test_weird_config_settings
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite(HEAVY_CFG)
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-c#{ucfg.path}", "-l#{@addr}:#{@port}")
      end
    end

    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    wait_master_ready(COMMON_TMP.path)
    wait_workers_ready(COMMON_TMP.path, 4)
    bf = File.readlines(COMMON_TMP.path).grep(/\bbefore_fork: worker=/)
    assert_equal 4, bf.size
    rotate = Tempfile.new('unicorn_rotate')
    assert_nothing_raised do
      File.rename(COMMON_TMP.path, rotate.path)
      Process.kill(:USR1, pid)
    end
    wait_for_file(COMMON_TMP.path)
    assert File.exist?(COMMON_TMP.path), "#{COMMON_TMP.path} exists"
    # USR1 should've been passed to all workers
    tries = DEFAULT_TRIES
    log = File.readlines(rotate.path)
    while (tries -= 1) > 0 &&
          log.grep(/rotating logs\.\.\./).size < 5
      sleep DEFAULT_RES
      log = File.readlines(rotate.path)
    end
    assert_equal 5, log.grep(/rotating logs\.\.\./).size
    assert_equal 0, log.grep(/done rotating logs/).size

    tries = DEFAULT_TRIES
    log = File.readlines(COMMON_TMP.path)
    while (tries -= 1) > 0 && log.grep(/done rotating logs/).size < 5
      sleep DEFAULT_RES
      log = File.readlines(COMMON_TMP.path)
    end
    assert_equal 5, log.grep(/done rotating logs/).size
    assert_equal 0, log.grep(/rotating logs\.\.\./).size
    assert_nothing_raised { Process.kill(:QUIT, pid) }
    status = nil
    assert_nothing_raised { pid, status = Process.waitpid2(pid) }
    assert status.success?, "exited successfully"
  end

  def test_read_embedded_cli_switches
    File.open("config.ru", "wb") do |fp|
      fp.syswrite("#\\ -p #{@port} -o #{@addr}\n")
      fp.syswrite(HI)
    end
    pid = fork { redirect_test_io { exec($unicorn_bin) } }
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_config_ru_alt_path
    config_path = "#{@tmpdir}/foo.ru"
    File.open(config_path, "wb") { |fp| fp.syswrite(HI) }
    pid = fork do
      redirect_test_io do
        Dir.chdir("/")
        exec($unicorn_bin, "-l#{@addr}:#{@port}", config_path)
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_load_module
    libdir = "#{@tmpdir}/lib"
    FileUtils.mkpath([ libdir ])
    config_path = "#{libdir}/hello.rb"
    File.open(config_path, "wb") { |fp| fp.syswrite(HELLO) }
    pid = fork do
      redirect_test_io do
        Dir.chdir("/")
        exec($unicorn_bin, "-l#{@addr}:#{@port}", config_path)
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_reexec
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid_file = "#{@tmpdir}/test.pid"
    pid = fork do
      redirect_test_io do
        exec($unicorn_bin, "-l#{@addr}:#{@port}", "-P#{pid_file}")
      end
    end
    reexec_basic_test(pid, pid_file)
  end

  def test_reexec_alt_config
    config_file = "#{@tmpdir}/foo.ru"
    File.open(config_file, "wb") { |fp| fp.syswrite(HI) }
    pid_file = "#{@tmpdir}/test.pid"
    pid = fork do
      redirect_test_io do
        exec($unicorn_bin, "-l#{@addr}:#{@port}", "-P#{pid_file}", config_file)
      end
    end
    reexec_basic_test(pid, pid_file)
  end

  def test_unicorn_config_file
    pid_file = "#{@tmpdir}/test.pid"
    sock = Tempfile.new('unicorn_test_sock')
    sock_path = sock.path
    sock.close!
    @sockets << sock_path

    log = Tempfile.new('unicorn_test_log')
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen \"#{sock_path}\"\n")
    ucfg.syswrite("pid \"#{pid_file}\"\n")
    ucfg.syswrite("logger Logger.new('#{log.path}')\n")
    ucfg.close

    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-l#{@addr}:#{@port}",
             "-P#{pid_file}", "-c#{ucfg.path}")
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    wait_master_ready(log.path)
    assert File.exist?(pid_file), "pid_file created"
    assert_equal pid, File.read(pid_file).to_i
    assert File.socket?(sock_path), "socket created"
    assert_nothing_raised do
      sock = UNIXSocket.new(sock_path)
      sock.syswrite("GET / HTTP/1.0\r\n\r\n")
      results = sock.sysread(4096)
    end
    assert_equal String, results.class

    # try reloading the config
    sock = Tempfile.new('unicorn_test_sock')
    new_sock_path = sock.path
    @sockets << new_sock_path
    sock.close!
    new_log = Tempfile.new('unicorn_test_log')
    new_log.sync = true
    assert_equal 0, new_log.size

    assert_nothing_raised do
      ucfg = File.open(ucfg.path, "wb")
      ucfg.syswrite("listen \"#{new_sock_path}\"\n")
      ucfg.syswrite("pid \"#{pid_file}\"\n")
      ucfg.syswrite("logger Logger.new('#{new_log.path}')\n")
      ucfg.close
      Process.kill(:HUP, pid)
    end

    wait_for_file(new_sock_path)
    assert File.socket?(new_sock_path), "socket exists"
    @sockets.each do |path|
      assert_nothing_raised do
        sock = UNIXSocket.new(path)
        sock.syswrite("GET / HTTP/1.0\r\n\r\n")
        results = sock.sysread(4096)
      end
      assert_equal String, results.class
    end

    assert_not_equal 0, new_log.size
    reexec_usr2_quit_test(pid, pid_file)
  end

  def test_daemonize_reexec
    pid_file = "#{@tmpdir}/test.pid"
    log = Tempfile.new('unicorn_test_log')
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("pid \"#{pid_file}\"\n")
    ucfg.syswrite("logger Logger.new('#{log.path}')\n")
    ucfg.close

    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-D", "-l#{@addr}:#{@port}", "-c#{ucfg.path}")
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    wait_for_file(pid_file)
    new_pid = File.read(pid_file).to_i
    assert_not_equal pid, new_pid
    pid, status = Process.waitpid2(pid)
    assert status.success?, "original process exited successfully"
    assert_nothing_raised { Process.kill(0, new_pid) }
    reexec_usr2_quit_test(new_pid, pid_file)
  end

  private

    # sometimes the server may not come up right away
    def retry_hit(uris = [])
      tries = DEFAULT_TRIES
      begin
        hit(uris)
      rescue Errno::ECONNREFUSED => err
        if (tries -= 1) > 0
          sleep DEFAULT_RES
          retry
        end
        raise err
      end
    end

    def assert_shutdown(pid)
      wait_master_ready("#{@tmpdir}/test_stderr.#{pid}.log")
      assert_nothing_raised { Process.kill(:QUIT, pid) }
      status = nil
      assert_nothing_raised { pid, status = Process.waitpid2(pid) }
      assert status.success?, "exited successfully"
    end

    def wait_workers_ready(path, nr_workers)
      tries = DEFAULT_TRIES
      lines = []
      while (tries -= 1) > 0
        begin
          lines = File.readlines(path).grep(/worker=\d+ ready/)
          lines.size == nr_workers and return
        rescue Errno::ENOENT
        end
        sleep DEFAULT_RES
      end
      raise "#{nr_workers} workers never became ready:" \
            "\n\t#{lines.join("\n\t")}\n"
    end

    def wait_master_ready(master_log)
      tries = DEFAULT_TRIES
      while (tries -= 1) > 0
        begin
          File.readlines(master_log).grep(/master process ready/)[0] and return
        rescue Errno::ENOENT
        end
        sleep DEFAULT_RES
      end
      raise "master process never became ready"
    end

    def reexec_usr2_quit_test(pid, pid_file)
      assert File.exist?(pid_file), "pid file OK"
      assert ! File.exist?("#{pid_file}.oldbin"), "oldbin pid file"
      assert_nothing_raised { Process.kill(:USR2, pid) }
      assert_nothing_raised { retry_hit(["http://#{@addr}:#{@port}/"]) }
      wait_for_file("#{pid_file}.oldbin")
      wait_for_file(pid_file)

      old_pid = File.read("#{pid_file}.oldbin").to_i
      new_pid = File.read(pid_file).to_i

      # kill old master process
      assert_not_equal pid, new_pid
      assert_equal pid, old_pid
      assert_nothing_raised { Process.kill(:QUIT, old_pid) }
      assert_nothing_raised { retry_hit(["http://#{@addr}:#{@port}/"]) }
      wait_for_death(old_pid)
      assert_equal new_pid, File.read(pid_file).to_i
      assert_nothing_raised { retry_hit(["http://#{@addr}:#{@port}/"]) }
      assert_nothing_raised { Process.kill(:QUIT, new_pid) }
    end

    def reexec_basic_test(pid, pid_file)
      results = retry_hit(["http://#{@addr}:#{@port}/"])
      assert_equal String, results[0].class
      assert_nothing_raised { Process.kill(0, pid) }
      master_log = "#{@tmpdir}/test_stderr.#{pid}.log"
      wait_master_ready(master_log)
      File.truncate(master_log, 0)
      nr = 50
      kill_point = 2
      assert_nothing_raised do
        nr.times do |i|
          hit(["http://#{@addr}:#{@port}/#{i}"])
          i == kill_point and Process.kill(:HUP, pid)
        end
      end
      wait_master_ready(master_log)
      assert File.exist?(pid_file), "pid=#{pid_file} exists"
      new_pid = File.read(pid_file).to_i
      assert_not_equal pid, new_pid
      assert_nothing_raised { Process.kill(0, new_pid) }
      assert_nothing_raised { Process.kill(:QUIT, new_pid) }
    end

    def wait_for_file(path)
      tries = DEFAULT_TRIES
      while (tries -= 1) > 0 && ! File.exist?(path)
        sleep DEFAULT_RES
      end
      assert File.exist?(path), "path=#{path} exists #{caller.inspect}"
    end

    def xfork(&block)
      fork do
        ObjectSpace.each_object(Tempfile) do |tmp|
          ObjectSpace.undefine_finalizer(tmp)
        end
        yield
      end
    end

    # can't waitpid on detached processes
    def wait_for_death(pid)
      tries = DEFAULT_TRIES
      while (tries -= 1) > 0
        begin
          Process.kill(0, pid)
          begin
            Process.waitpid(pid, Process::WNOHANG)
          rescue Errno::ECHILD
          end
          sleep(DEFAULT_RES)
        rescue Errno::ESRCH
          return
        end
      end
      raise "PID:#{pid} never died!"
    end

end if do_test
