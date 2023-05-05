#!/bin/zsh

ERL_TOP=~/proj/otp
TYPE=debug
top="$ERL_TOP/lib/mnesia"
h=`hostname`
p="-pa $top/examples -pa $top/ebin -pa $top/test -mnesia_test_verbose true"
log=test_log$$
latest=test_log_latest
args=${1+"$@"}
erlcmd="erl -sname a $p $args -mnesia_test_timeout"
erlcmd1="erl -sname a1 $p $args"
erlcmd2="erl -sname a2 $p $args"

export ERL_TOP && export TYPE && export top
cd $top && make debug && cd $top/test && \
~/proj/otp/bin/erl -make && \
~/proj/otp/bin/erl -name a@127.0.0.1 -pa '/home/vincent/proj/inet_tcp_proxy/ebin' \
-pa $top/examples -pa $top/src -pa $top/ebin $top/test -debug -proto_dist inet_tcp_proxy

