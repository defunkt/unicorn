#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
use v5.14; BEGIN { require './t/lib.perl' };
use autodie;
my $srv = tcp_server();
my $host_port = tcp_host_port($srv);
my $ru = "$tmpdir/config.ru";
my $u_conf = "$tmpdir/u.conf.rb";

open my $fh, '>', $ru;
print $fh <<'EOM';
use Rack::ContentLength
use Rack::ContentType, 'text/plain'
config = ru = "hello world\n" # check for config variable conflicts, too
run lambda { |env| [ 200, {}, [ ru.to_s ] ] }
EOM
close $fh;

open $fh, '>', $u_conf;
print $fh <<EOM;
preload_app true
stderr_path "$err_log"
EOM
close $fh;

my $ar = unicorn(qw(-E none -c), $u_conf, $ru, { 3 => $srv });
my ($status, $hdr, $bdy) = do_req($srv, 'GET / HTTP/1.0');
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid at start');
is($bdy, "hello world\n", 'body matches expected');

open $fh, '>>', $ru;
say $fh '....this better be a syntax error in any version of ruby...';
close $fh;

$ar->do_kill('HUP'); # reload
my @l;
for (1..1000) {
	@l = grep(/(?:done|error) reloading/, slurp($err_log)) and
		last;
	select undef, undef, undef, 0.011;
}
diag slurp($err_log) if $ENV{V};
ok(grep(/error reloading/, @l), 'got error reloading');
open $fh, '>', $err_log;
close $fh;

($status, $hdr, $bdy) = do_req($srv, 'GET / HTTP/1.0');
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid afte reload');
is($bdy, "hello world\n", 'body matches expected after reload');

check_stderr;
undef $tmpdir; # quiet t/lib.perl END{}
done_testing;
