#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@80x24.org>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
package UnicornTest;
use v5.14;
use parent qw(Exporter);
use autodie;
use Test::More;
use IO::Socket::INET;
use POSIX qw(dup2 _exit setpgid :signal_h SEEK_SET F_SETFD);
use File::Temp 0.19 (); # 0.19 for ->newdir
our ($tmpdir, $errfh);
our @EXPORT = qw(unicorn slurp tcp_server tcp_connect unicorn $tmpdir $errfh
	SEEK_SET tcp_host_port start_req which spawn);

my ($base) = ($0 =~ m!\b([^/]+)\.[^\.]+\z!);
$tmpdir = File::Temp->newdir("unicorn-$base-XXXX", TMPDIR => 1);
open($errfh, '>>', "$tmpdir/err.log");

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

sub tcp_connect {
	my ($dest, %opt) = @_;
	my $addr = tcp_host_port($dest);
	my $s = ref($dest)->new(
		Proto => 'tcp',
		Type => SOCK_STREAM,
		PeerAddr => $addr,
		%opt,
	) or BAIL_OUT "failed to connect to $addr: $!";
	$s->autoflush(1);
	$s;
}

sub start_req {
	my ($srv, @req) = @_;
	my $c = tcp_connect($srv);
	print $c @req, "\r\n\r\n";
	$c;
}

sub slurp {
	open my $fh, '<', $_[0];
	local $/;
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
	state $exe = File::Spec->rel2abs('bin/unicorn');
	my $pid = spawn(\%env, $ruby, '-I', $lib, '-I', $ext, $exe, @args);
	UnicornTest::AutoReap->new($pid);
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
