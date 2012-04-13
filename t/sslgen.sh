#!/bin/sh
set -e

lock=$0.lock
while ! mkdir $lock 2>/dev/null
do
	echo >&2 "PID=$$ waiting for $lock"
	sleep 1
done
pid=$$
trap 'if test $$ -eq $pid; then rmdir $lock; fi' EXIT

certinfo() {
	echo US
	echo Hell
	echo A Very Special Place
	echo Monkeys
	echo Poo-Flingers
	echo 127.0.0.1
	echo kgio@bogomips.org
}

certinfo2() {
	certinfo
	echo
	echo
}

ca_certinfo () {
	echo US
	echo Hell
	echo An Even More Special Place
	echo Deranged Monkeys
	echo Poo-Hurlers
	echo 127.6.6.6
	echo unicorn@bogomips.org
}

openssl genrsa -out ca.key 1024
ca_certinfo | openssl req -new -x509 -days 666 -key ca.key -out ca.crt

openssl genrsa -out bad-ca.key 1024
ca_certinfo | openssl req -new -x509 -days 666 -key bad-ca.key -out bad-ca.crt

openssl genrsa -out server.key 1024
certinfo2 | openssl req -new -key server.key -out server.csr

openssl x509 -req -days 666 \
	-in server.csr -CA ca.crt -CAkey ca.key -set_serial 1 -out server.crt
n=2
mk_client_cert () {
	CLIENT=$1
	openssl genrsa -out $CLIENT.key 1024
	certinfo2 | openssl req -new -key $CLIENT.key -out $CLIENT.csr

	openssl x509 -req -days 666 \
		-in $CLIENT.csr -CA $CA.crt -CAkey $CA.key -set_serial $n \
		-out $CLIENT.crt
	rm -f $CLIENT.csr
	n=$(($n + 1))
}

CA=ca
mk_client_cert client1
mk_client_cert client2

CA=bad-ca mk_client_cert bad-client

rm -f server.csr

echo OK
