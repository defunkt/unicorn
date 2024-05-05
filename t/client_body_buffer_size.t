#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>

use v5.14; BEGIN { require './t/lib.perl' };
use autodie;
my $conf_fh = write_file '>', $u_conf, <<EOM;
client_body_buffer_size 0
EOM
$conf_fh->autoflush(1);
my $srv = tcp_server();
my $host_port = tcp_host_port($srv);
my @uarg = (qw(-E none t/client_body_buffer_size.ru -c), $u_conf);
my $ar = unicorn(@uarg, { 3 => $srv });
my ($c, $status, $hdr);
my $mem_class = 'StringIO';
my $fs_class = 'Unicorn::TmpIO';

$c = tcp_start($srv, "PUT /input_class HTTP/1.0\r\nContent-Length: 0");
($status, $hdr) = slurp_hdr($c);
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid');
is(readline($c), $mem_class, 'zero-byte file is StringIO');

$c = tcp_start($srv, "PUT /tmp_class HTTP/1.0\r\nContent-Length: 1");
print $c '.';
($status, $hdr) = slurp_hdr($c);
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid');
is(readline($c), $fs_class, '1 byte file is filesystem-backed');


my $fifo = "$tmpdir/fifo";
POSIX::mkfifo($fifo, 0600) or die "mkfifo: $!";
seek($conf_fh, 0, SEEK_SET);
truncate($conf_fh, 0);
print $conf_fh <<EOM;
after_fork { |_,_| File.open('$fifo', 'w') { |fp| fp.write "pid=#\$\$" } }
EOM
$ar->do_kill('HUP');
open my $fifo_fh, '<', $fifo;
like(my $wpid = readline($fifo_fh), qr/\Apid=\d+\z/a ,
	'reloaded w/ default client_body_buffer_size');


$c = tcp_start($srv, "PUT /tmp_class HTTP/1.0\r\nContent-Length: 1");
($status, $hdr) = slurp_hdr($c);
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid');
is(readline($c), $mem_class, 'class for a 1 byte file is memory-backed');


my $one_meg = 1024 ** 2;
$c = tcp_start($srv, "PUT /tmp_class HTTP/1.0\r\nContent-Length: $one_meg");
($status, $hdr) = slurp_hdr($c);
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid');
is(readline($c), $fs_class, '1 megabyte file is FS-backed');

# reload with bigger client_body_buffer_size
say $conf_fh "client_body_buffer_size $one_meg";
$ar->do_kill('HUP');
open $fifo_fh, '<', $fifo;
like($wpid = readline($fifo_fh), qr/\Apid=\d+\z/a ,
	'reloaded w/ bigger client_body_buffer_size');


$c = tcp_start($srv, "PUT /tmp_class HTTP/1.0\r\nContent-Length: $one_meg");
($status, $hdr) = slurp_hdr($c);
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid');
is(readline($c), $mem_class, '1 megabyte file is now memory-backed');

my $too_big = $one_meg + 1;
$c = tcp_start($srv, "PUT /tmp_class HTTP/1.0\r\nContent-Length: $too_big");
($status, $hdr) = slurp_hdr($c);
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid');
is(readline($c), $fs_class, '1 megabyte + 1 byte file is FS-backed');


undef $ar;
check_stderr;
undef $tmpdir;
done_testing;
