#!/bin/bash

while memf=$(grep MemF /proc/meminfo | tr -s ' ' '\t' | cut -f2)
do
    date "+%FT%T $memf"
    if test $memf -lt 100000
    then
        # Try garbage collection
        raku -e 'VM.request-garbage-collection'
        sleep 1

        # Kill all raku processes to force garbage collection
        memf=$(grep MemF /proc/meminfo | tr -s ' ' '\t' | cut -f2)
        test $memf -lt 100000 && pkill raku
    fi
    sleep 60
done
