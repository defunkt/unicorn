#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>

use v5.14; BEGIN { require './t/lib.perl' };
my $srv = tcp_server();
my $host_port = tcp_host_port($srv);
my $t0 = time;
my $ar = unicorn(qw(-E none t/integration.ru), { 3 => $srv });

sub slurp_hdr {
	my ($c) = @_;
	local $/ = "\r\n\r\n"; # affects both readline+chomp
	chomp(my $hdr = readline($c));
	my ($status, @hdr) = split(/\r\n/, $hdr);
	diag explain([ $status, \@hdr ]) if $ENV{V};
	($status, \@hdr);
}

my ($c, $status, $hdr);

# response header tests
$c = tcp_connect($srv);
print $c "GET /rack-2-newline-headers HTTP/1.0\r\n\r\n" or die $!;
($status, $hdr) = slurp_hdr($c);
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid');
my $orig_200_status = $status;
is_deeply([ grep(/^X-R2: /, @$hdr) ],
	[ 'X-R2: a', 'X-R2: b', 'X-R2: c' ],
	'rack 2 LF-delimited headers supported') or diag(explain($hdr));

SKIP: { # Date header check
	my @d = grep(/^Date: /i, @$hdr);
	is(scalar(@d), 1, 'got one date header') or diag(explain(\@d));
	eval { require HTTP::Date } or skip "HTTP::Date missing: $@", 1;
	$d[0] =~ s/^Date: //i or die 'BUG: did not strip date: prefix';
	my $t = HTTP::Date::str2time($d[0]);
	ok($t >= $t0 && $t > 0 && $t <= time, 'valid date') or
		diag(explain([$t, $!, \@d]));
};


$c = tcp_connect($srv);
print $c "GET /rack-3-array-headers HTTP/1.0\r\n\r\n" or die $!;
($status, $hdr) = slurp_hdr($c);
is_deeply([ grep(/^x-r3: /, @$hdr) ],
	[ 'x-r3: a', 'x-r3: b', 'x-r3: c' ],
	'rack 3 array headers supported') or diag(explain($hdr));


# cf. <CAO47=rJa=zRcLn_Xm4v2cHPr6c0UswaFC_omYFEH+baSxHOWKQ@mail.gmail.com>
$c = tcp_connect($srv);
print $c "GET /nil-header-value HTTP/1.0\r\n\r\n" or die $!;
($status, $hdr) = slurp_hdr($c);
is_deeply([grep(/^X-Nil:/, @$hdr)], ['X-Nil: '],
	'nil header value accepted for broken apps') or diag(explain($hdr));

if ('TODO: ensure Rack::Utils::HTTP_STATUS_CODES is available') {
	$c = tcp_connect($srv);
	print $c "POST /tweak-status-code HTTP/1.0\r\n\r\n" or die $!;
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 200 HI\b!, 'status tweaked');

	$c = tcp_connect($srv);
	print $c "POST /restore-status-code HTTP/1.0\r\n\r\n" or die $!;
	($status, $hdr) = slurp_hdr($c);
	is($status, $orig_200_status, 'original status restored');
}

SKIP: {
	eval { require HTTP::Tiny } or skip "HTTP::Tiny missing: $@", 1;
	my $ht = HTTP::Tiny->new;
	my $res = $ht->get("http://$host_port/write_on_close");
	is($res->{content}, 'Goodbye', 'write-on-close body read');
}

# ... more stuff here
undef $ar;
my @log = slurp("$tmpdir/err.log");
diag("@log") if $ENV{V};
my @err = grep(!/NameError.*Unicorn::Waiter/, grep(/error/i, @log));
is_deeply(\@err, [], 'no unexpected errors in stderr');
is_deeply([grep(/SIGKILL/, @log)], [], 'no SIGKILL in stderr');

done_testing;
