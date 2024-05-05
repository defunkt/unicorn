#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
use v5.14; BEGIN { require './t/lib.perl' };
use autodie;
my $srv = tcp_server();
my $out_log = "$tmpdir/out.log";
write_file '>', $u_conf, <<EOM;
stderr_path "$err_log"
stdout_path "$out_log"
EOM

my $auto_reap = unicorn('-c', $u_conf, 't/reopen-logs.ru', { 3 => $srv } );
my ($status, $hdr, $bdy) = do_req($srv, 'GET / HTTP/1.0');
is($bdy, "true\n", 'logs opened');

rename($err_log, "$err_log.rot");
rename($out_log, "$out_log.rot");

$auto_reap->do_kill('USR1');

my $tries = 1000;
while (!-f $err_log && --$tries) { sleep 0.01 };
while (!-f $out_log && --$tries) { sleep 0.01 };

ok(-f $out_log, 'stdout_path recreated after USR1');
ok(-f $err_log, 'stderr_path recreated after USR1');

($status, $hdr, $bdy) = do_req($srv, 'GET / HTTP/1.0');
is($bdy, "true\n", 'logs reopened with sync==true');

$auto_reap->join('QUIT');
is($?, 0, 'no error on exit');
check_stderr;
undef $tmpdir;
done_testing;
