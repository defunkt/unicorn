#!/bin/sh
. ./test-rails3.sh

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
	unicorn_rails -D -c $unicorn_config
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
