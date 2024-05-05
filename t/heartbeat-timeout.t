#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
use v5.14; BEGIN { require './t/lib.perl' };
use autodie;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
mkdir "$tmpdir/alt";
my $srv = tcp_server();
write_file '>', $u_conf, <<EOM;
pid "$tmpdir/pid"
preload_app true
stderr_path "$err_log"
timeout 3 # WORST FEATURE EVER
EOM

my $ar = unicorn(qw(-E none t/heartbeat-timeout.ru -c), $u_conf, { 3 => $srv });

my ($status, $hdr, $wpid) = do_req($srv, 'GET /pid HTTP/1.0');
like($status, qr!\AHTTP/1\.[01] 200\b!, 'PID request succeeds');
like($wpid, qr/\A[0-9]+\z/, 'worker is running');

my $t0 = clock_gettime(CLOCK_MONOTONIC);
my $c = tcp_start($srv, 'GET /block-forever HTTP/1.0');
vec(my $rvec = '', fileno($c), 1) = 1;
is(select($rvec, undef, undef, 6), 1, 'got readiness');
$c->blocking(0);
is(sysread($c, my $buf, 128), 0, 'got EOF response');
my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
ok($elapsed > 3, 'timeout took >3s');

my @timeout_err = slurp($err_log);
truncate($err_log, 0);
is(grep(/timeout \(\d+s > 3s\), killing/, @timeout_err), 1,
    'noted timeout error') or diag explain(\@timeout_err);

# did it respawn?
($status, $hdr, my $new_pid) = do_req($srv, 'GET /pid HTTP/1.0');
like($status, qr!\AHTTP/1\.[01] 200\b!, 'PID request succeeds');
isnt($new_pid, $wpid, 'spawned new worker');

diag 'SIGSTOP for 4 seconds...';
$ar->do_kill('STOP');
sleep 4;
$ar->do_kill('CONT');
for my $i (1..2) {
	($status, $hdr, my $spid) = do_req($srv, 'GET /pid HTTP/1.0');
	like($status, qr!\AHTTP/1\.[01] 200\b!,
		"PID request succeeds #$i after STOP+CONT");
	is($new_pid, $spid, "worker pid unchanged after STOP+CONT #$i");
	if ($i == 1) {
		diag 'sleeping 2s to ensure timeout is not delayed';
		sleep 2;
	}
}

$ar->join('TERM');
check_stderr;
undef $tmpdir;

done_testing;
