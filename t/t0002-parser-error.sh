#!/bin/sh
. ./test-lib.sh
t_plan 5 "parser error test"

t_begin "setup and startup" && {
	unicorn_setup
	unicorn -D env.ru -c $unicorn_config
	unicorn_wait_start
}

t_begin "send a bad request" && {
	(
		printf 'GET / HTTP/1/1\r\nHost: example.com\r\n\r\n'
		cat $fifo > $tmp &
		wait
		echo ok > $ok
	) | socat - TCP:$listen > $fifo
	test xok = x$(cat $ok)
}

dbgcat tmp

t_begin "response should be a 400" && {
	grep -F 'HTTP/1.1 400 Bad Request' $tmp
}

t_begin "server stderr should be clean" && check_stderr

t_begin "term signal sent" && kill $unicorn_pid

t_done
