#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@80x24.org>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
package UnicornTest;
use v5.14;
use parent qw(Exporter);
use autodie;
use Test::More;
use Socket qw(SOMAXCONN);
use Time::HiRes qw(sleep time);
use IO::Socket::INET;
use IO::Socket::UNIX;
use Carp qw(croak);
use POSIX qw(dup2 _exit setpgid :signal_h SEEK_SET F_SETFD);
use File::Temp 0.19 (); # 0.19 for ->newdir
our ($tmpdir, $errfh, $err_log, $u_sock, $u_conf, $daemon_pid,
	$pid_file, $wtest_sock, $fifo);
our @EXPORT = qw(unicorn slurp tcp_server tcp_start unicorn
	$tmpdir $errfh $err_log $u_sock $u_conf $daemon_pid $pid_file
	$wtest_sock $fifo
	SEEK_SET tcp_host_port which spawn check_stderr unix_start slurp_hdr
	do_req stop_daemon sleep time mkfifo_die kill_until_dead write_file);

my ($base) = ($0 =~ m!\b([^/]+)\.[^\.]+\z!);
$tmpdir = File::Temp->newdir("unicorn-$base-XXXX", TMPDIR => 1);

$wtest_sock = "$tmpdir/wtest.sock";
$err_log = "$tmpdir/err.log";
$pid_file = "$tmpdir/pid";
$fifo = "$tmpdir/fifo";
$u_sock = "$tmpdir/u.sock";
$u_conf = "$tmpdir/u.conf.rb";
open($errfh, '+>>', $err_log);

if (my $t = $ENV{TAIL}) {
	my @tail = $t =~ /tail/ ? split(/\s+/, $t) : (qw(tail -F));
	push @tail, $err_log;
	my $pid = fork;
	if ($pid == 0) {
		open STDOUT, '>&', \*STDERR;
		exec @tail;
		die "exec(@tail): $!";
	}
	say "# @tail";
	sleep 0.2;
	UnicornTest::AutoReap->new($pid);
}

sub kill_until_dead ($;%) {
	my ($pid, %opt) = @_;
	my $tries = $opt{tries} // 1000;
	my $sig = $opt{sig} // 0;
	while (CORE::kill($sig, $pid) && --$tries) { sleep(0.01) }
	$tries or croak "PID: $pid died after signal ($sig)";
}

sub stop_daemon (;$) {
	my ($is_END) = @_;
	kill('TERM', $daemon_pid);
	kill_until_dead $daemon_pid;
	if ($is_END && CORE::kill(0, $daemon_pid)) { # after done_testing
		CORE::kill('KILL', $daemon_pid);
		die "daemon_pid=$daemon_pid did not die";
	} else {
		ok(!CORE::kill(0, $daemon_pid), 'daemonized unicorn gone');
		undef $daemon_pid;
	}
};

END {
	diag slurp($err_log) if $tmpdir;
	stop_daemon(1) if defined $daemon_pid;
};

sub check_stderr (@) {
	my @log = @_;
	slurp($err_log) if !@log;
	diag("@log") if $ENV{V};
	my @err = grep(!/NameError.*Unicorn::Waiter/, grep(/error/i, @log));
	@err = grep(!/failed to set accept_filter=/, @err);
	@err = grep(!/perhaps accf_.*? needs to be loaded/, @err);
	is_deeply(\@err, [], 'no unexpected errors in stderr');
	is_deeply([grep(/SIGKILL/, @log)], [], 'no SIGKILL in stderr');
}

sub slurp_hdr {
	my ($c) = @_;
	local $/ = "\r\n\r\n"; # affects both readline+chomp
	chomp(my $hdr = readline($c));
	my ($status, @hdr) = split(/\r\n/, $hdr);
	diag explain([ $status, \@hdr ]) if $ENV{V};
	($status, \@hdr);
}

sub unix_server (;$@) {
	my $l = shift // $u_sock;
	IO::Socket::UNIX->new(Listen => SOMAXCONN, Local => $l, Blocking => 0,
				Type => SOCK_STREAM, @_);
}

sub unix_connect ($) {
	IO::Socket::UNIX->new(Peer => $_[0], Type => SOCK_STREAM);
}

sub tcp_server {
	my %opt = (
		ReuseAddr => 1,
		Proto => 'tcp',
		Type => SOCK_STREAM,
		Listen => SOMAXCONN,
		Blocking => 0,
		@_,
	);
	eval {
		die 'IPv4-only' if $ENV{TEST_IPV4_ONLY};
		require IO::Socket::INET6;
		IO::Socket::INET6->new(%opt, LocalAddr => '[::1]')
	} || eval {
		die 'IPv6-only' if $ENV{TEST_IPV6_ONLY};
		IO::Socket::INET->new(%opt, LocalAddr => '127.0.0.1')
	} || BAIL_OUT "failed to create TCP server: $! ($@)";
}

sub tcp_host_port {
	my ($s) = @_;
	my ($h, $p) = ($s->sockhost, $s->sockport);
	my $ipv4 = $s->sockdomain == AF_INET;
	if (wantarray) {
		$ipv4 ? ($h, $p) : ("[$h]", $p);
	} else {
		$ipv4 ? "$h:$p" : "[$h]:$p";
	}
}

sub unix_start ($@) {
	my ($dst, @req) = @_;
	my $s = unix_connect($dst) or BAIL_OUT "unix connect $dst: $!";
	$s->autoflush(1);
	print $s @req, "\r\n\r\n" if @req;
	$s;
}

sub tcp_start ($@) {
	my ($dst, @req) = @_;
	my $addr = tcp_host_port($dst);
	my $s = ref($dst)->new(
		Proto => 'tcp',
		Type => SOCK_STREAM,
		PeerAddr => $addr,
	) or BAIL_OUT "failed to connect to $addr: $!";
	$s->autoflush(1);
	print $s @req, "\r\n\r\n" if @req;
	$s;
}

sub slurp {
	open my $fh, '<', $_[0];
	local $/ if !wantarray;
	readline($fh);
}

sub spawn {
	my $env = ref($_[0]) eq 'HASH' ? shift : undef;
	my $opt = ref($_[-1]) eq 'HASH' ? pop : {};
	my @cmd = @_;
	my $old = POSIX::SigSet->new;
	my $set = POSIX::SigSet->new;
	$set->fillset or die "sigfillset: $!";
	sigprocmask(SIG_SETMASK, $set, $old) or die "SIG_SETMASK: $!";
	pipe(my $r, my $w);
	my $pid = fork;
	if ($pid == 0) {
		close $r;
		$SIG{__DIE__} = sub {
			warn(@_);
			syswrite($w, my $num = $! + 0);
			_exit(1);
		};

		# pretend to be systemd (cf. sd_listen_fds(3))
		my $cfd;
		for ($cfd = 0; ($cfd < 3) || defined($opt->{$cfd}); $cfd++) {
			my $io = $opt->{$cfd} // next;
			my $pfd = fileno($io);
			if ($pfd == $cfd) {
				fcntl($io, F_SETFD, 0);
			} else {
				dup2($pfd, $cfd) // die "dup2($pfd, $cfd): $!";
			}
		}
		if (($cfd - 3) > 0) {
			$env->{LISTEN_PID} = $$;
			$env->{LISTEN_FDS} = $cfd - 3;
		}

		if (defined(my $pgid = $opt->{pgid})) {
			setpgid(0, $pgid) // die "setpgid(0, $pgid): $!";
		}
		$SIG{$_} = 'DEFAULT' for grep(!/^__/, keys %SIG);
		if (defined(my $cd = $opt->{-C})) { chdir $cd }
		$old->delset(POSIX::SIGCHLD) or die "sigdelset CHLD: $!";
		sigprocmask(SIG_SETMASK, $old) or die "SIG_SETMASK: ~CHLD: $!";
		@ENV{keys %$env} = values(%$env) if $env;
		exec { $cmd[0] } @cmd;
		die "exec @cmd: $!";
	}
	close $w;
	sigprocmask(SIG_SETMASK, $old) or die "SIG_SETMASK(old): $!";
	if (my $cerrnum = do { local $/, <$r> }) {
		$! = $cerrnum;
		die "@cmd PID=$pid died: $!";
	}
	$pid;
}

sub which {
	my ($file) = @_;
	return $file if index($file, '/') >= 0;
	for my $p (split(/:/, $ENV{PATH})) {
		$p .= "/$file";
		return $p if -x $p;
	}
	undef;
}

# returns an AutoReap object
sub unicorn {
	my %env;
	if (ref($_[0]) eq 'HASH') {
		my $e = shift;
		%env = %$e;
	}
	my @args = @_;
	push(@args, {}) if ref($args[-1]) ne 'HASH';
	$args[-1]->{2} //= $errfh; # stderr default

	state $ruby = which($ENV{RUBY} // 'ruby');
	state $lib = File::Spec->rel2abs('lib');
	state $ver = $ENV{TEST_RUBY_VERSION} // `$ruby -e 'print RUBY_VERSION'`;
	state $eng = $ENV{TEST_RUBY_ENGINE} // `$ruby -e 'print RUBY_ENGINE'`;
	state $ext = File::Spec->rel2abs("test/$eng-$ver/ext/unicorn_http");
	state $exe = File::Spec->rel2abs("test/$eng-$ver/bin/unicorn");
	state $rl = $ENV{RUBYLIB} ? "$lib:$ext:$ENV{RUBYLIB}" : "$lib:$ext";
	$env{RUBYLIB} = $rl;
	my $pid = spawn(\%env, $ruby, $exe, @args);
	UnicornTest::AutoReap->new($pid);
}

sub do_req ($@) {
	my ($dst, @req) = @_;
	my $c = ref($dst) ? tcp_start($dst, @req) : unix_start($dst, @req);
	return $c if !wantarray;
	my ($status, $hdr);
	# read headers iff HTTP/1.x request, HTTP/0.9 remains supported
	my ($first) = (join('', @req) =~ m!\A([^\r\n]+)!);
	($status, $hdr) = slurp_hdr($c) if $first =~ m{\s*HTTP/\S+$};
	my $bdy = do { local $/; <$c> };
	close $c;
	($status, $hdr, $bdy);
}

sub mkfifo_die ($;$) {
	POSIX::mkfifo($_[0], $_[1] // 0600) or croak "mkfifo: $!";
}

sub write_file ($$@) { # mode, filename, LIST (for print)
	open(my $fh, shift, shift);
	print $fh @_;
	# return $fh for futher writes if user wants it:
	defined(wantarray) && !wantarray ? $fh : close $fh;
}

# automatically kill + reap children when this goes out-of-scope
package UnicornTest::AutoReap;
use v5.14;
use autodie;

sub new {
	my (undef, $pid) = @_;
	bless { pid => $pid, owner => $$ }, __PACKAGE__
}

sub do_kill {
	my ($self, $sig) = @_;
	kill($sig // 'TERM', $self->{pid});
}

sub join {
	my ($self, $sig) = @_;
	my $pid = delete $self->{pid} or return;
	kill($sig, $pid) if defined $sig;
	my $ret = waitpid($pid, 0);
	$ret == $pid or die "BUG: waitpid($pid) != $ret";
}

sub DESTROY {
	my ($self) = @_;
	return if $self->{owner} != $$;
	$self->join('TERM');
}

package main; # inject ourselves into the t/*.t script
UnicornTest->import;
Test::More->import;
# try to ensure ->DESTROY fires:
$SIG{TERM} = sub { exit(15 + 128) };
$SIG{INT} = sub { exit(2 + 128) };
$SIG{PIPE} = sub { exit(13 + 128) };
1;
