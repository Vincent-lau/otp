#!/bin/sh
# Author  : Hakan Mattsson <hakan@cslab.ericsson.se>
# Purpose : Simplify benchmark execution
# Created : 21 Jun 2001 by Hakan Mattsson <hakan@cslab.ericsson.se>
######################################################################

QE_PATH=~/proj/quantile_estimator/ebin
PROXY_PATH=~/proj/inet_tcp_proxy/ebin
args="-pa .. -pa $QE_PATH -pa $PROXY_PATH  -boot start_sasl \
-sasl errlog_type error -sname bench1 +sbt db"

# -proto_dist inet_tcp_proxy"

ERL_TOP=~/proj/otp
cd $ERL_TOP && make mnesia && \
cd $ERL_TOP/lib/mnesia/examples/bench && make && \
if [ $# -eq 0 ] ; then
    $ERL_TOP/bin/erl $args
else
  while [ $# -gt 0 ]; do
    $ERL_TOP/bin/erl $args -s bench run $1 -s erlang halt
    shift
  done
fi

