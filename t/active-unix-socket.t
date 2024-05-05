#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>

use v5.14; BEGIN { require './t/lib.perl' };
use IO::Socket::UNIX;
use autodie;
no autodie 'kill';
my %to_kill;
END { kill('TERM', values(%to_kill)) if keys %to_kill }
my $u1 = "$tmpdir/u1.sock";
my $u2 = "$tmpdir/u2.sock";
{
	write_file '>', "$tmpdir/u1.conf.rb", <<EOM;
pid "$tmpdir/u.pid"
listen "$u1"
stderr_path "$err_log"
EOM
	write_file '>', "$tmpdir/u2.conf.rb", <<EOM;
pid "$tmpdir/u.pid"
listen "$u2"
stderr_path "$tmpdir/err2.log"
EOM

	write_file '>', "$tmpdir/u3.conf.rb", <<EOM;
pid "$tmpdir/u3.pid"
listen "$u1"
stderr_path "$tmpdir/err3.log"
EOM
}

my @uarg = qw(-D -E none t/integration.ru);

# this pipe will be used to notify us when all daemons die:
pipe(my $p0, my $p1);
fcntl($p1, POSIX::F_SETFD, 0);

# start the first instance
unicorn('-c', "$tmpdir/u1.conf.rb", @uarg)->join;
is($?, 0, 'daemonized 1st process');
chomp($to_kill{u1} = slurp("$tmpdir/u.pid"));
like($to_kill{u1}, qr/\A\d+\z/s, 'read pid file');

chomp(my $worker_pid = readline(unix_start($u1, 'GET /pid')));
like($worker_pid, qr/\A\d+\z/s, 'captured worker pid');
ok(kill(0, $worker_pid), 'worker is kill-able');


# 2nd process conflicts on PID
unicorn('-c', "$tmpdir/u2.conf.rb", @uarg)->join;
isnt($?, 0, 'conflicting PID file fails to start');

chomp(my $pidf = slurp("$tmpdir/u.pid"));
is($pidf, $to_kill{u1}, 'pid file contents unchanged after start failure');

chomp(my $pid2 = readline(unix_start($u1, 'GET /pid')));
is($worker_pid, $pid2, 'worker PID unchanged');


# 3rd process conflicts on socket
unicorn('-c', "$tmpdir/u3.conf.rb", @uarg)->join;
isnt($?, 0, 'conflicting UNIX socket fails to start');

chomp($pid2 = readline(unix_start($u1, 'GET /pid')));
is($worker_pid, $pid2, 'worker PID still unchanged');

chomp($pidf = slurp("$tmpdir/u.pid"));
is($pidf, $to_kill{u1}, 'pid file contents unchanged after 2nd start failure');

{ # teardown initial process via SIGKILL
	ok(kill('KILL', delete $to_kill{u1}), 'SIGKILL initial daemon');
	close $p1;
	vec(my $rvec = '', fileno($p0), 1) = 1;
	is(select($rvec, undef, undef, 5), 1, 'timeout for pipe HUP');
	is(my $undef = <$p0>, undef, 'process closed pipe writer at exit');
	ok(-f "$tmpdir/u.pid", 'pid file stayed after SIGKILL');
	ok(-S $u1, 'socket stayed after SIGKILL');
	is(IO::Socket::UNIX->new(Peer => $u1, Type => SOCK_STREAM), undef,
		'fail to connect to u1');
	for (1..50) { # wait for init process to reap worker
		kill(0, $worker_pid) or last;
		sleep 0.011;
	}
	ok(!kill(0, $worker_pid), 'worker gone after parent dies');
}

# restart the first instance
{
	pipe($p0, $p1);
	fcntl($p1, POSIX::F_SETFD, 0);
	unicorn('-c', "$tmpdir/u1.conf.rb", @uarg)->join;
	is($?, 0, 'daemonized 1st process');
	chomp($to_kill{u1} = slurp("$tmpdir/u.pid"));
	like($to_kill{u1}, qr/\A\d+\z/s, 'read pid file');

	chomp($pid2 = readline(unix_start($u1, 'GET /pid')));
	like($pid2, qr/\A\d+\z/, 'worker running');

	ok(kill('TERM', delete $to_kill{u1}), 'SIGTERM restarted daemon');
	close $p1;
	vec(my $rvec = '', fileno($p0), 1) = 1;
	is(select($rvec, undef, undef, 5), 1, 'timeout for pipe HUP');
	is(my $undef = <$p0>, undef, 'process closed pipe writer at exit');
	ok(!-f "$tmpdir/u.pid", 'pid file gone after SIGTERM');
	ok(-S $u1, 'socket stays after SIGTERM');
}

check_stderr;
undef $tmpdir;
done_testing;
