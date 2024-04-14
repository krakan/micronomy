#!/bin/bash

while memf=$(grep MemF /proc/meminfo | tr -s ' ' '\t' | cut -f2)
do
    date "+%FT%T $memf"
    test $memf -lt 100000 && pkill raku
    sleep 60
done
