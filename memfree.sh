#!/bin/bash

while memf=$(grep MemF /proc/meminfo | tr -s ' ' '\t' | cut -f2)
do
    date "+%FT%T $memf"
    if test $memf -lt 100000
    then
        # Restart the wait-for-restart service
        sudo systemctl restart wait-for-restart
        for i in $(seq 10)
        do
            sudo netstat -pln | grep ':8888 .* LISTEN' && break
            sleep 0.5
        done

        # Kill the micronomy process to let it restart
        pkill -fx 'raku -I lib service.raku'
    fi
    sleep 60
done
