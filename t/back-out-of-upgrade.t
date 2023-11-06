#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
# test backing out of USR2 upgrade
use v5.14; BEGIN { require './t/lib.perl' };
use autodie;
my $srv = tcp_server();
mkfifo_die $fifo;
write_file '>', $u_conf, <<EOM;
preload_app true
stderr_path "$err_log"
pid "$pid_file"
after_fork { |s,w| File.open('$fifo', 'w') { |fp| fp.write "pid=#\$\$" } }
EOM
my $ar = unicorn(qw(-E none t/pid.ru -c), $u_conf, { 3 => $srv });

like(my $wpid_orig_1 = slurp($fifo), qr/\Apid=\d+\z/a, 'got worker pid');

ok $ar->do_kill('USR2'), 'USR2 to start upgrade';
ok $ar->do_kill('WINCH'), 'drop old worker';

like(my $wpid_new = slurp($fifo), qr/\Apid=\d+\z/a, 'got pid from new master');
chomp(my $new_pid = slurp($pid_file));
isnt $new_pid, $ar->{pid}, 'PID file changed';
chomp(my $pid_oldbin = slurp("$pid_file.oldbin"));
is $pid_oldbin, $ar->{pid}, '.oldbin PID valid';

ok $ar->do_kill('HUP'), 'HUP old master';
like(my $wpid_orig_2 = slurp($fifo), qr/\Apid=\d+\z/a, 'got worker new pid');
ok kill('QUIT', $new_pid), 'abort old master';
kill_until_dead $new_pid;

my ($st, $hdr, $req_pid) = do_req $srv, 'GET /';
chomp $req_pid;
is $wpid_orig_2, "pid=$req_pid", 'new worker on old worker serves';

ok !-f "$pid_file.oldbin", '.oldbin PID file gone';
chomp(my $old_pid = slurp($pid_file));
is $old_pid, $ar->{pid}, 'PID file restored';

my @log = grep !/ERROR -- : reaped .*? exec\(\)-ed/, slurp($err_log);
check_stderr @log;
undef $tmpdir;
done_testing;
