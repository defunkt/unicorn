#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>

# This is the main integration test for fast-ish things to minimize
# Ruby startup time penalties.

use v5.14; BEGIN { require './t/lib.perl' };
use autodie;
use Socket qw(SOL_SOCKET SO_KEEPALIVE SHUT_WR);
our $srv = tcp_server();
our $host_port = tcp_host_port($srv);

if ('ensure Perl does not set SO_KEEPALIVE by default') {
	my $val = getsockopt($srv, SOL_SOCKET, SO_KEEPALIVE);
	unpack('i', $val) == 0 or
		setsockopt($srv, SOL_SOCKET, SO_KEEPALIVE, pack('i', 0));
	$val = getsockopt($srv, SOL_SOCKET, SO_KEEPALIVE);
}
my $t0 = time;
my $u1 = "$tmpdir/u1";
my $conf_fh = write_file '>', $u_conf, <<EOM;
early_hints true
listen "$u1"
EOM
$conf_fh->autoflush(1);
my $ar = unicorn(qw(-E none t/integration.ru -c), $u_conf, { 3 => $srv });
my $curl = which('curl');
local $ENV{NO_PROXY} = '*'; # for curl
my $fifo = "$tmpdir/fifo";
POSIX::mkfifo($fifo, 0600) or die "mkfifo: $!";
my %PUT = (
	chunked_md5 => sub {
		my ($in, $out, $path, %opt) = @_;
		my $dig = Digest::MD5->new;
		print $out <<EOM;
PUT $path HTTP/1.1\r
Transfer-Encoding: chunked\r
Trailer: Content-MD5\r
\r
EOM
		my ($buf, $r);
		while (1) {
			$r = read($in, $buf, 999 + int(rand(0xffff)));
			last if $r == 0;
			printf $out "%x\r\n", length($buf);
			print $out $buf, "\r\n";
			$dig->add($buf);
		}
		print $out "0\r\nContent-MD5: ", $dig->b64digest, "\r\n\r\n";
	},
	identity => sub {
		my ($in, $out, $path, %opt) = @_;
		my $clen = $opt{-s} // -s $in;
		print $out <<EOM;
PUT $path HTTP/1.0\r
Content-Length: $clen\r
\r
EOM
		my ($buf, $r, $len, $bs);
		while ($clen) {
			$bs = 999 + int(rand(0xffff));
			$len = $clen > $bs ? $bs : $clen;
			$r = read($in, $buf, $len);
			die 'premature EOF' if $r == 0;
			print $out $buf;
			$clen -= $r;
		}
	},
);

my ($c, $status, $hdr, $bdy);

# response header tests
($status, $hdr) = do_req($srv, 'GET /rack-2-newline-headers HTTP/1.0');
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid');
my $orig_200_status = $status;
is_deeply([ grep(/^X-R2: /, @$hdr) ],
	[ 'X-R2: a', 'X-R2: b', 'X-R2: c' ],
	'rack 2 LF-delimited headers supported') or diag(explain($hdr));

{
	my $val = getsockopt($srv, SOL_SOCKET, SO_KEEPALIVE);
	is(unpack('i', $val), 1, 'SO_KEEPALIVE set on inherited socket');
}

SKIP: { # Date header check
	my @d = grep(/^Date: /i, @$hdr);
	is(scalar(@d), 1, 'got one date header') or diag(explain(\@d));
	eval { require HTTP::Date } or skip "HTTP::Date missing: $@", 1;
	$d[0] =~ s/^Date: //i or die 'BUG: did not strip date: prefix';
	my $t = HTTP::Date::str2time($d[0]);
	my $now = time;
	ok($t >= ($t0 - 1) && $t > 0 && $t <= ($now + 1), 'valid date') or
		diag(explain(["t=$t t0=$t0 now=$now", $!, \@d]));
};


($status, $hdr) = do_req($srv, 'GET /rack-3-array-headers HTTP/1.0');
is_deeply([ grep(/^x-r3: /, @$hdr) ],
	[ 'x-r3: a', 'x-r3: b', 'x-r3: c' ],
	'rack 3 array headers supported') or diag(explain($hdr));

my $JSON_PP;
SKIP: {
	eval { require JSON::PP } or skip "JSON::PP missing: $@", 1;
	$JSON_PP = JSON::PP->new;
	my $get_json = sub {
		my (@req) = @_;
		my @r = do_req $srv, @req;
		my $env = eval { $JSON_PP->decode($r[2]) };
		diag "$@ (r[2]=$r[2])" if $@;
		is ref($env), 'HASH', "@req response body is JSON";
		(@r, $env)
	};
	($status, $hdr, my $json, my $env) = $get_json->('GET /env_dump');
	is($status, undef, 'no status for HTTP/0.9');
	is($hdr, undef, 'no header for HTTP/0.9');
	unlike($json, qr/^Connection: /smi, 'no connection header for 0.9');
	unlike($json, qr!\AHTTP/!s, 'no HTTP/1.x prefix for 0.9');
	is($env->{SERVER_PROTOCOL}, 'HTTP/0.9', 'SERVER_PROTOCOL is 0.9');
	is $env->{'rack.url_scheme'}, 'http', 'rack.url_scheme default';
	is $env->{'rack.input'}, 'StringIO', 'StringIO for no content';

	my $req = 'OPTIONS *';
	($status, $hdr, $json, $env) = $get_json->("$req HTTP/1.0");
	is $env->{REQUEST_PATH}, '', "$req => REQUEST_PATH";
	is $env->{PATH_INFO}, '', "$req => PATH_INFO";
	is $env->{REQUEST_URI}, '*', "$req => REQUEST_URI";

	$req = 'GET http://e:3/env_dump?y=z';
	($status, $hdr, $json, $env) = $get_json->("$req HTTP/1.0");
	is $env->{REQUEST_PATH}, '/env_dump', "$req => REQUEST_PATH";
	is $env->{PATH_INFO}, '/env_dump', "$req => PATH_INFO";
	is $env->{QUERY_STRING}, 'y=z', "$req => QUERY_STRING";

	$req = 'GET http://e:3/env_dump#frag';
	($status, $hdr, $json, $env) = $get_json->("$req HTTP/1.0");
	is $env->{REQUEST_PATH}, '/env_dump', "$req => REQUEST_PATH";
	is $env->{PATH_INFO}, '/env_dump', "$req => PATH_INFO";
	is $env->{QUERY_STRING}, '', "$req => QUERY_STRING";
	is $env->{FRAGMENT}, 'frag', "$req => FRAGMENT";

	$req = 'GET http://e:3/env_dump?a=b#frag';
	($status, $hdr, $json, $env) = $get_json->("$req HTTP/1.0");
	is $env->{REQUEST_PATH}, '/env_dump', "$req => REQUEST_PATH";
	is $env->{PATH_INFO}, '/env_dump', "$req => PATH_INFO";
	is $env->{QUERY_STRING}, 'a=b', "$req => QUERY_STRING";
	is $env->{FRAGMENT}, 'frag', "$req => FRAGMENT";

	for my $proto (qw(https http)) {
		$req = "X-Forwarded-Proto: $proto";
		($status, $hdr, $json, $env) = $get_json->(
						"GET /env_dump HTTP/1.0\r\n".
						"X-Forwarded-Proto: $proto");
		is $env->{REQUEST_PATH}, '/env_dump', "$req => REQUEST_PATH";
		is $env->{PATH_INFO}, '/env_dump', "$req => PATH_INFO";
		is $env->{'rack.url_scheme'}, $proto, "$req => rack.url_scheme";
	}

	$req = 'X-Forwarded-Proto: ftp'; # invalid proto
	($status, $hdr, $json, $env) = $get_json->(
					"GET /env_dump HTTP/1.0\r\n".
					"X-Forwarded-Proto: ftp");
	is $env->{REQUEST_PATH}, '/env_dump', "$req => REQUEST_PATH";
	is $env->{PATH_INFO}, '/env_dump', "$req => PATH_INFO";
	is $env->{'rack.url_scheme'}, 'http', "$req => rack.url_scheme";

	($status, $hdr, $json, $env) = $get_json->("PUT /env_dump HTTP/1.0\r\n".
						'Content-Length: 0');
	is $env->{'rack.input'}, 'StringIO', 'content-length: 0 uses StringIO';

	($status, $hdr, $json, $env) = $get_json->("PUT /env_dump HTTP/1.0\r\n".
						'Content-Length: 1');
	is $env->{'rack.input'}, 'Unicorn::TeeInput',
		'content-length: 1 uses TeeInput';
}

# cf. <CAO47=rJa=zRcLn_Xm4v2cHPr6c0UswaFC_omYFEH+baSxHOWKQ@mail.gmail.com>
($status, $hdr) = do_req($srv, 'GET /nil-header-value HTTP/1.0');
is_deeply([grep(/^X-Nil:/, @$hdr)], ['X-Nil: '],
	'nil header value accepted for broken apps') or diag(explain($hdr));

check_stderr;
($status, $hdr, $bdy) = do_req($srv, 'GET /broken_app HTTP/1.0');
like($status, qr!\AHTTP/1\.[0-1] 500\b!, 'got 500 error on broken endpoint');
is($bdy, undef, 'no response body after exception');
seek $errfh, 0, SEEK_SET;
{
	my $nxt;
	while (!defined($nxt) && defined($_ = <$errfh>)) {
		$nxt = <$errfh> if /app error/;
	}
	ok $nxt, 'got app error' and
		like $nxt, qr/\bintegration\.ru/, 'got backtrace';
}
seek $errfh, 0, SEEK_SET;
truncate $errfh, 0;

($status, $hdr, $bdy) = do_req($srv, 'GET /nil HTTP/1.0');
like($status, qr!\AHTTP/1\.[0-1] 500\b!, 'got 500 error on nil endpoint');
like slurp($err_log), qr/app error/, 'exception logged for nil';
seek $errfh, 0, SEEK_SET;
truncate $errfh, 0;

my $ck_early_hints = sub {
	my ($note) = @_;
	$c = unix_start($u1, 'GET /early_hints_rack2 HTTP/1.0');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 103\b!, 'got 103 for rack 2 value');
	is_deeply(['link: r', 'link: 2'], $hdr, 'rack 2 hints match '.$note);
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 200\b!, 'got 200 afterwards');
	is(readline($c), 'String', 'early hints used a String for rack 2');

	$c = unix_start($u1, 'GET /early_hints_rack3 HTTP/1.0');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 103\b!, 'got 103 for rack 3');
	is_deeply(['link: r', 'link: 3'], $hdr, 'rack 3 hints match '.$note);
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 200\b!, 'got 200 afterwards');
	is(readline($c), 'Array', 'early hints used a String for rack 3');
};
$ck_early_hints->('ccc off'); # we'll retest later

if ('TODO: ensure Rack::Utils::HTTP_STATUS_CODES is available') {
	($status, $hdr) = do_req $srv, 'POST /tweak-status-code HTTP/1.0';
	like($status, qr!\AHTTP/1\.[01] 200 HI\b!, 'status tweaked');

	($status, $hdr) = do_req $srv, 'POST /restore-status-code HTTP/1.0';
	is($status, $orig_200_status, 'original status restored');
}

SKIP: {
	eval { require HTTP::Tiny } or skip "HTTP::Tiny missing: $@", 1;
	my $ht = HTTP::Tiny->new;
	my $res = $ht->get("http://$host_port/write_on_close");
	is($res->{content}, 'Goodbye', 'write-on-close body read');
}

if ('bad requests') {
	($status, $hdr) = do_req $srv, 'GET /env_dump HTTP/1/1';
	like($status, qr!\AHTTP/1\.[01] 400 \b!, 'got 400 on bad request');

	for my $abs_uri (qw(ssh+http://e/ ftp://e/x http+ssh://e/x)) {
		($status, $hdr) = do_req $srv, "GET $abs_uri HTTP/1.0";
		like $status, qr!\AHTTP/1\.[01] 400 \b!, "400 on $abs_uri";
	}

	$c = tcp_start($srv);
	print $c 'GET /';
	my $buf = join('', (0..9), 'ab');
	for (0..1023) { print $c $buf }
	print $c " HTTP/1.0\r\n\r\n";
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!,
		'414 on REQUEST_PATH > (12 * 1024)');

	$c = tcp_start($srv);
	print $c 'GET /hello-world?a';
	$buf = join('', (0..9));
	for (0..1023) { print $c $buf }
	print $c " HTTP/1.0\r\n\r\n";
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!,
		'414 on QUERY_STRING > (10 * 1024)');

	$c = tcp_start($srv);
	print $c 'GET /hello-world#a';
	$buf = join('', (0..9), 'a'..'f');
	for (0..63) { print $c $buf }
	print $c " HTTP/1.0\r\n\r\n";
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!, '414 on FRAGMENT > (1024)');
}

# input tests
my ($blob_size, $blob_hash);
SKIP: {
	skip 'SKIP_EXPENSIVE on', 1 if $ENV{SKIP_EXPENSIVE};
	CORE::open(my $rh, '<', 't/random_blob') or
		skip "t/random_blob not generated $!", 1;
	$blob_size = -s $rh;
	require Digest::MD5;
	$blob_hash = Digest::MD5->new->addfile($rh)->hexdigest;

	my $ck_hash = sub {
		my ($sub, $path, %opt) = @_;
		seek($rh, 0, SEEK_SET);
		$c = tcp_start($srv);
		$c->autoflush($opt{sync} // 0);
		$PUT{$sub}->($rh, $c, $path, %opt);
		defined($opt{overwrite}) and
			print { $c } ('x' x $opt{overwrite});
		$c->flush or die $!;
		shutdown($c, SHUT_WR);
		($status, $hdr) = slurp_hdr($c);
		is(readline($c), $blob_hash, "$sub $path");
	};
	$ck_hash->('identity', '/rack_input', -s => $blob_size);
	$ck_hash->('chunked_md5', '/rack_input');
	$ck_hash->('identity', '/rack_input/size_first', -s => $blob_size);
	$ck_hash->('identity', '/rack_input/rewind_first', -s => $blob_size);
	$ck_hash->('chunked_md5', '/rack_input/size_first');
	$ck_hash->('chunked_md5', '/rack_input/rewind_first');

	$ck_hash->('identity', '/rack_input', -s => $blob_size, sync => 1);
	$ck_hash->('chunked_md5', '/rack_input', sync => 1);

	# ensure small overwrites don't get checksummed
	$ck_hash->('identity', '/rack_input', -s => $blob_size,
			overwrite => 1); # one extra byte
	unlike(slurp($err_log), qr/ClientShutdown/,
		'no overreads after client SHUT_WR');

	# excessive overwrite truncated
	$c = tcp_start($srv);
	$c->autoflush(0);
	print $c "PUT /rack_input HTTP/1.0\r\nContent-Length: 1\r\n\r\n";
	if (1) {
		local $SIG{PIPE} = 'IGNORE';
		my $buf = "\0" x 8192;
		my $n = 0;
		my $end = time + 5;
		$! = 0;
		while (print $c $buf and time < $end) { ++$n }
		ok($!, 'overwrite truncated') or diag "n=$n err=$! ".time;
		undef $c;
	}

	# client shutdown early
	$c = tcp_start($srv);
	$c->autoflush(0);
	print $c "PUT /rack_input HTTP/1.0\r\nContent-Length: 16384\r\n\r\n";
	if (1) {
		local $SIG{PIPE} = 'IGNORE';
		print $c 'too short body';
		shutdown($c, SHUT_WR);
		vec(my $rvec = '', fileno($c), 1) = 1;
		select($rvec, undef, undef, 10) or BAIL_OUT "timed out";
		my $buf = <$c>;
		is($buf, undef, 'server aborted after client SHUT_WR');
		undef $c;
	}

	$curl // skip 'no curl found in PATH', 1;

	my ($copt, $cout);
	my $url = "http://$host_port/rack_input";
	my $do_curl = sub {
		my (@arg) = @_;
		pipe(my $cout, $copt->{1});
		open $copt->{2}, '>', "$tmpdir/curl.err";
		my $cpid = spawn($curl, '-sSf', @arg, $url, $copt);
		close(delete $copt->{1});
		is(readline($cout), $blob_hash, "curl @arg response");
		is(waitpid($cpid, 0), $cpid, "curl @arg exited");
		is($?, 0, "no error from curl @arg");
		is(slurp("$tmpdir/curl.err"), '', "no stderr from curl @arg");
	};

	$do_curl->(qw(-T t/random_blob));

	seek($rh, 0, SEEK_SET);
	$copt->{0} = $rh;
	$do_curl->('-T-');

	diag 'testing Unicorn::PrereadInput...';
	local $srv = tcp_server();
	local $host_port = tcp_host_port($srv);
	check_stderr;
	truncate($errfh, 0);

	my $pri = unicorn(qw(-E none t/preread_input.ru), { 3 => $srv });
	$url = "http://$host_port/";

	$do_curl->(qw(-T t/random_blob));
	seek($rh, 0, SEEK_SET);
	$copt->{0} = $rh;
	$do_curl->('-T-');

	my @pr_err = slurp("$tmpdir/err.log");
	is(scalar(grep(/app dispatch:/, @pr_err)), 2, 'app dispatched twice');

	# abort a chunked request by blocking curl on a FIFO:
	$c = tcp_start($srv, "PUT / HTTP/1.1\r\nTransfer-Encoding: chunked");
	close $c;
	@pr_err = slurp("$tmpdir/err.log");
	is(scalar(grep(/app dispatch:/, @pr_err)), 2,
			'app did not dispatch on aborted request');
	undef $pri;
	check_stderr;
	diag 'Unicorn::PrereadInput middleware tests done';
}

# disallow /content_length/i and /transfer_encoding/i due to confusion+
# smuggling attacks
# cf. <CAB6pCSb=vE1My6pHcwO672JNeeDaOYNJ4ykkB_vq9LCqR7pYFw@mail.gmail.com>
SKIP: {
	$JSON_PP or skip "JSON::PP missing: $@", 1;
	my $body = "1\r\nZ\r\n0\r\n\r\n";
	my $blen = length $body;
	my $post = "POST /env_dump HTTP/1.0\r\n";

	for my $x (["Content-Length: $blen", $body],
			[ "Transfer-Encoding: chunked", 'Z']) {
		($status, $hdr, $bdy) = do_req $srv, $post,
					$x->[0], "\r\n\r\n", $body;
		like $status, qr!\AHTTP/1\.[01] 200!, 'Content-Length POST';
		my $env = $JSON_PP->decode($bdy);
		is $env->{'unicorn_test.body'}, $x->[1], "$x->[0]-only";
	}

	for my $cl (qw(Content-Length Content_Length)) {
		for my $te (qw(Transfer-Encoding Transfer_Encoding)) {
			($status, $hdr, $bdy) = do_req $srv, $post,
				"$te: chunked\r\n",
				"$cl: $blen\r\n", "\r\n", $body;
			if ("$cl$te" =~ /_/) {
				like $status, qr!\AHTTP/1\.[01] 400 \b!,
					"got 400 on bad request w/ $cl + $te";
			} else { # RFC 7230 favors Transfer-Encoding :<
				like $status, qr!\AHTTP/1\.[01] 200 \b!,
					"got 200 w/ both $cl + $te";
				my $env = $JSON_PP->decode($bdy);
				is $env->{'unicorn_test.body'}, 'Z',
'Transfer-Encoding favored over Content-Length (RFC 7230 3.3.3#3)';
			}
		}
	}
}

# ... more stuff here

# SIGHUP-able stuff goes here

if ('check_client_connection') {
	print $conf_fh <<EOM; # appending to existing
check_client_connection true
after_fork { |_,_| File.open('$fifo', 'w') { |fp| fp.write "pid=#\$\$" } }
EOM
	$ar->do_kill('HUP');
	open my $fifo_fh, '<', $fifo;
	my $wpid = readline($fifo_fh);
	like($wpid, qr/\Apid=\d+\z/a , 'new worker ready');
	$ck_early_hints->('ccc on');

	$c = tcp_start $srv, 'GET /env_dump HTTP/1.0';
	vec(my $rvec = '', fileno($c), 1) = 1;
	select($rvec, undef, undef, 10) or BAIL_OUT 'timed out env_dump';
	($status, $hdr) = slurp_hdr($c);
	like $status, qr!\AHTTP/1\.[01] 200!, 'got part of first response';
	ok $hdr, 'got all headers';

	# start a slow TCP request
	my $rfifo = "$tmpdir/rfifo";
	mkfifo_die $rfifo;
	$c = tcp_start $srv, "GET /read_fifo HTTP/1.0\r\nRead-FIFO: $rfifo";
	tcp_start $srv, 'GET /aborted HTTP/1.0' for (1..100);
	write_file '>', $rfifo, 'TFIN';
	($status, $hdr) = slurp_hdr($c);
	like $status, qr!\AHTTP/1\.[01] 200!, 'got part of first response';
	$bdy = <$c>;
	is $bdy, 'TFIN', 'got slow response from TCP socket';

	# slow Unix socket request
	$c = unix_start $u1, "GET /read_fifo HTTP/1.0\r\nRead-FIFO: $rfifo";
	vec($rvec = '', fileno($c), 1) = 1;
	unix_start $u1, 'GET /aborted HTTP/1.0' for (1..100);
	write_file '>', $rfifo, 'UFIN';
	($status, $hdr) = slurp_hdr($c);
	like $status, qr!\AHTTP/1\.[01] 200!, 'got part of first response';
	$bdy = <$c>;
	is $bdy, 'UFIN', 'got slow response from Unix socket';

	($status, $hdr, $bdy) = do_req $srv, 'GET /nr_aborts HTTP/1.0';
	like "@$hdr", qr/nr-aborts: 0\b/,
		'aborted connections unseen by Rack app';
}

if ('max_header_len internal API') {
	undef $c;
	my $req = 'GET / HTTP/1.0';
	my $len = length($req."\r\n\r\n");
	print $conf_fh <<EOM; # appending to existing
Unicorn::HttpParser.max_header_len = $len
EOM
	$ar->do_kill('HUP');
	open my $fifo_fh, '<', $fifo;
	my $wpid = readline($fifo_fh);
	like($wpid, qr/\Apid=\d+\z/a , 'new worker ready');
	close $fifo_fh;
	$wpid =~ s/\Apid=// or die;
	ok(CORE::kill(0, $wpid), 'worker PID retrieved');

	($status, $hdr) = do_req($srv, $req);
	like($status, qr!\AHTTP/1\.[01] 200\b!, 'minimal request succeeds');

	($status, $hdr) = do_req($srv, 'GET /xxxxxx HTTP/1.0');
	like($status, qr!\AHTTP/1\.[01] 413\b!, 'big request fails');
}


undef $ar;

check_stderr;

undef $tmpdir;
done_testing;
