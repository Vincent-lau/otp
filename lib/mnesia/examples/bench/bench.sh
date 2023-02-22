#!/bin/sh
# Author  : Hakan Mattsson <hakan@cslab.ericsson.se>
# Purpose : Simplify benchmark execution
# Created : 21 Jun 2001 by Hakan Mattsson <hakan@cslab.ericsson.se>
######################################################################

args="-pa .. -boot start_sasl -sasl errlog_type error -sname bench +sbt db"
ERL_TOP=/home/vincent/proj/otp/bin/erl
set -x

if [ $# -eq 0 ] ; then
    
    $ERL_TOP $args

else
  while [ $# -gt 0 ]; do
    $ERL_TOP $args -s bench run $1 -s erlang halt
    shift
  done

fi

