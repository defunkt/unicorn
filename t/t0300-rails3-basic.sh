#!/bin/sh
RAILS_VERSION=${RAILS_VERSION-3.0.0.beta3}

. ./test-lib.sh

case $RUBY_VERSION in
1.8.7|1.9.2) ;;
*)
	t_info "RUBY_VERSION=$RUBY_VERSION unsupported for Rails 3"
	exit 0
	;;
esac

arch_gems=../tmp/isolate/ruby-$RUBY_VERSION/gems
rails_gems=../tmp/isolate/rails-$RAILS_VERSION/gems
rails_bin="$rails_gems/rails-$RAILS_VERSION/bin/rails"
if ! test -d "$arch_gems" || ! test -d "$rails_gems" || ! test -x "$rails_bin"
then
	( cd ../ && $RAKE isolate )
fi

for i in $arch_gems/*-* $rails_gems/*-*
do
	if test -d $i/lib
	then
		RUBYLIB=$(cd $i/lib && pwd):$RUBYLIB
	fi
done

export RUBYLIB

t_plan 3 "Rails 3 (beta) tests"

t_begin "setup and start" && {
	rails3_app=$(cd rails3-app && pwd)
	rm -rf $t_pfx.app
	mkdir $t_pfx.app
	cd $t_pfx.app
	( cd $rails3_app && tar cf - . ) | tar xf -
	$RAKE db:sessions:create
	$RAKE db:migrate
	unicorn_setup
	unicorn -D -c $unicorn_config
	unicorn_wait_start
}

# add more tests here
t_begin "hit with curl" && {
	curl -v http://$listen/ || :
}

t_begin "killing succeeds" && {
	kill $unicorn_pid
}

t_done
