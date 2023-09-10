#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
use v5.14; BEGIN { require './t/lib.perl' };
use autodie;
mkdir "$tmpdir/alt";
my $u_sock = "$tmpdir/u.sock";
my $ru = "$tmpdir/alt/config.ru";
my $u_conf = "$tmpdir/u.conf.rb";
open my $fh, '>', $u_conf;
print $fh <<EOM;
pid "$tmpdir/pid"
preload_app true
stderr_path "$err_log"
working_directory "$tmpdir/alt" # the whole point of this test
before_fork { |_,_| \$master_ppid = Process.ppid }
EOM
close $fh;

my $common_ru = <<'EOM';
use Rack::ContentLength
use Rack::ContentType, 'text/plain'
run lambda { |env| [ 200, {}, [ "#{$master_ppid}\n" ] ] }
EOM

open $fh, '>', $ru;
print $fh <<EOM;
#\\--daemonize --listen $u_sock
$common_ru
EOM
close $fh;

my $pid;
my $stop_daemon = sub {
	my ($is_END) = @_;
	kill('TERM', $pid);
	my $tries = 1000;
	while (CORE::kill(0, $pid) && --$tries) {
		select undef, undef, undef, 0.01;
	}
	if ($is_END && CORE::kill(0, $pid)) {
		CORE::kill('KILL', $pid);
		die "daemonized PID=$pid did not die";
	} else {
		ok(!CORE::kill(0, $pid), 'daemonized unicorn gone');
		undef $pid;
	}
};

END { $stop_daemon->(1) if defined $pid };

unicorn('-c', $u_conf)->join; # will daemonize
chomp($pid = slurp("$tmpdir/pid"));

my ($status, $hdr, $bdy) = do_req($u_sock, 'GET / HTTP/1.0');
is($bdy, "1\n", 'got expected $master_ppid');

$stop_daemon->();
check_stderr;

if ('test without CLI switches in config.ru') {
	truncate $err_log, 0;
	open $fh, '>', $ru;
	print $fh $common_ru;
	close $fh;

	unicorn('-D', '-l', $u_sock, '-c', $u_conf)->join; # will daemonize
	chomp($pid = slurp("$tmpdir/pid"));

	($status, $hdr, $bdy) = do_req($u_sock, 'GET / HTTP/1.0');
	is($bdy, "1\n", 'got expected $master_ppid');

	$stop_daemon->();
	check_stderr;
}

if ('ensures broken working_directory (missing config.ru) is OK') {
	truncate $err_log, 0;
	unlink $ru;

	my $auto_reap = unicorn('-c', $u_conf);
	$auto_reap->join;
	isnt($?, 0, 'exited with error due to missing config.ru');

	like(slurp($err_log), qr/rackup file \Q(config.ru)\E not readable/,
		'noted unreadability of config.ru in stderr');
}

if ('fooapp.rb (not config.ru) works with working_directory') {
	truncate $err_log, 0;
	my $fooapp = "$tmpdir/alt/fooapp.rb";
	open $fh, '>', $fooapp;
	print $fh <<EOM;
class Fooapp
  def self.call(env)
    b = "dir=#{Dir.pwd}"
    h = { 'content-type' => 'text/plain', 'content-length' => b.bytesize.to_s }
    [ 200, h, [ b ] ]
  end
end
EOM
	close $fh;
	my $srv = tcp_server;
	my $auto_reap = unicorn(qw(-c), $u_conf, qw(-I. fooapp.rb),
				{ -C => '/', 3 => $srv });
	($status, $hdr, $bdy) = do_req($srv, 'GET / HTTP/1.0');
	is($bdy, "dir=$tmpdir/alt",
		'fooapp.rb (w/o config.ru) w/ working_directory');
	$auto_reap->join('TERM');
	is($?, 0, 'fooapp.rb process exited');
	check_stderr;
}

undef $tmpdir;
done_testing;
