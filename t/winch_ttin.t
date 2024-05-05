#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
use v5.14; BEGIN { require './t/lib.perl' };
use autodie;
use POSIX qw(mkfifo);
my $u_sock = "$tmpdir/u.sock";
my $fifo = "$tmpdir/fifo";
mkfifo($fifo, 0666) or die "mkfifo($fifo): $!";

write_file '>', $u_conf, <<EOM;
pid "$tmpdir/pid"
listen "$u_sock"
stderr_path "$err_log"
after_fork do |server, worker|
  # test script will block while reading from $fifo,
  File.open("$fifo", "wb") { |fp| fp.syswrite worker.nr.to_s }
end
EOM

unicorn('-D', '-c', $u_conf, 't/integration.ru')->join;
is($?, 0, 'daemonized properly');
open my $fh, '<', "$tmpdir/pid";
chomp(my $pid = <$fh>);
ok(kill(0, $pid), 'daemonized PID works');
my $quit = sub { kill('QUIT', $pid) if $pid; $pid = undef };
END { $quit->() };

open $fh, '<', $fifo;
my $worker_nr = <$fh>;
close $fh;
is($worker_nr, '0', 'initial worker spawned');

my ($status, $hdr, $worker_pid) = do_req($u_sock, 'GET /pid HTTP/1.0');
like($status, qr/ 200\b/, 'got 200 response');
like($worker_pid, qr/\A[0-9]+\n\z/s, 'PID in response');
chomp $worker_pid;
ok(kill(0, $worker_pid), 'worker_pid is valid');

ok(kill('WINCH', $pid), 'SIGWINCH can be sent');

my $tries = 1000;
while (CORE::kill(0, $worker_pid) && --$tries) { sleep 0.01 }
ok(!CORE::kill(0, $worker_pid), 'worker not running');

ok(kill('TTIN', $pid), 'SIGTTIN to restart worker');

open $fh, '<', $fifo;
$worker_nr = <$fh>;
close $fh;
is($worker_nr, '0', 'worker restarted');

($status, $hdr, my $new_worker_pid) = do_req($u_sock, 'GET /pid HTTP/1.0');
like($status, qr/ 200\b/, 'got 200 response');
like($new_worker_pid, qr/\A[0-9]+\n\z/, 'got new worker PID');
chomp $new_worker_pid;
ok(kill(0, $new_worker_pid), 'got a valid worker PID');
isnt($worker_pid, $new_worker_pid, 'worker PID changed');

$quit->();

check_stderr;
undef $tmpdir;
done_testing;
