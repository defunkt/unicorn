#!/bin/sh
. ./test-lib.sh
t_plan 7 "simple HTTPS connection tests"

t_begin "setup and start" && {
	rtmpfiles curl_err
	unicorn_setup
cat > $unicorn_config <<EOF
ssl do
  listen "$listen"
  ssl_certificate "server.crt"
  ssl_certificate_key "server.key"
end
pid "$pid"
stderr_path "$r_err"
stdout_path "$r_out"
EOF
	unicorn -D -c $unicorn_config env.ru
	unicorn_wait_start
}

t_begin "single request" && {
	curl -sSfv --cacert ca.crt https://$listen/
}

t_begin "check stderr has no errors" && {
	check_stderr
}

t_begin "multiple requests" && {
	curl -sSfv --no-keepalive --cacert ca.crt \
		https://$listen/ https://$listen/ 2>> $curl_err >> $tmp
		dbgcat curl_err
}

t_begin "check stderr has no errors" && {
	check_stderr
}

t_begin "killing succeeds" && {
	kill $unicorn_pid
}

t_begin "check stderr has no errors" && {
	check_stderr
}

t_done
