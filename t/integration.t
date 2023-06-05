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

SKIP: {
	eval { require JSON::PP } or skip "JSON::PP missing: $@", 1;
	$c = tcp_connect($srv);
	print $c "GET /env_dump\r\n" or die $!;
	my $json = do { local $/; readline($c) };
	unlike($json, qr/^Connection: /smi, 'no connection header for 0.9');
	unlike($json, qr!\AHTTP/!s, 'no HTTP/1.x prefix for 0.9');
	my $env = JSON::PP->new->decode($json);
	is(ref($env), 'HASH', 'JSON decoded body to hashref');
	is($env->{SERVER_PROTOCOL}, 'HTTP/0.9', 'SERVER_PROTOCOL is 0.9');
}

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

if ('bad requests') {
	$c = start_req($srv, 'GET /env_dump HTTP/1/1');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 400 \b!, 'got 400 on bad request');

	$c = tcp_connect($srv);
	print $c 'GET /' or die $!;
	my $buf = join('', (0..9), 'ab');
	for (0..1023) { print $c $buf or die $! }
	print $c " HTTP/1.0\r\n\r\n" or die $!;
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!,
		'414 on REQUEST_PATH > (12 * 1024)');

	$c = tcp_connect($srv);
	print $c 'GET /hello-world?a' or die $!;
	$buf = join('', (0..9));
	for (0..1023) { print $c $buf or die $! }
	print $c " HTTP/1.0\r\n\r\n" or die $!;
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!,
		'414 on QUERY_STRING > (10 * 1024)');

	$c = tcp_connect($srv);
	print $c 'GET /hello-world#a' or die $!;
	$buf = join('', (0..9), 'a'..'f');
	for (0..63) { print $c $buf or die $! }
	print $c " HTTP/1.0\r\n\r\n" or die $!;
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!, '414 on FRAGMENT > (1024)');
}


# ... more stuff here
undef $ar;
my @log = slurp("$tmpdir/err.log");
diag("@log") if $ENV{V};
my @err = grep(!/NameError.*Unicorn::Waiter/, grep(/error/i, @log));
is_deeply(\@err, [], 'no unexpected errors in stderr');
is_deeply([grep(/SIGKILL/, @log)], [], 'no SIGKILL in stderr');

done_testing;
