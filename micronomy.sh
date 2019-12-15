#!/bin/bash -e
#
# Helper script for micronomy
# targets 'debug', 'deploy' and 'tmux' require access to the server
# targets 'local' and 'run' require Rakudo and some modules
# target 'run' alo requires certbot and nginx
#

usage() {
    exec >&2
    test "$*" && echo -e "ERROR: $*\n"
    echo "usage: $0 [--debug] docker|local|deploy|tmux"
    echo "or:    $0 [--debug] [--port <int>] [--certdir <path>] [run]"
    exit 1
}

target=run
port=
xtrace=
cert=/etc/letsencrypt/live/micronomy.jonaseel.se
while test $# -gt 0
do
    case $1 in
        -p|--port) port=$2; shift;;
        -c|--cert*) cert=$2; shift;;
        -x|--debug) xtrace=on; set -x;;
        -*) usage "unknown option '$1'";;
        *) target=$1;;
    esac
    shift
done

# set home dir
test $target = run || cd $(dirname $0)

# do your thing
case $target in
    docker)
        exist=$(docker images -q micronomy:latest)
        if test -z $exist || {
                touch --date=$(docker inspect micronomy:latest | jq -r .[].Created) Dockerfile &&
	            find . -newer Dockerfile -type f | \
	                egrep '^./((lib|resources)/|^service.p6)' | grep -v ./lib/.precomp;
            }
        then
            docker build -t micronomy .
        fi
        docker run -it --rm -p 4443:443 micronomy
        ;;

    local) MICRONOMY_PORT=4443 MICRONOMY_HOST=0.0.0.0 perl6 -I lib service.p6;;

    deploy)
	if rsync -zva --exclude .precomp . micronomy:micronomy/ | tee /dev/tty |
                egrep -q '^(lib|resources)/|^service.p6'
	then
            echo "INFO: restarting micronomy"
            ssh -t micronomy.jonaseel.se sudo pkill moar
	else
            echo "INFO: no changes uploaded"
        fi
        ;;

    tmux) ssh -t micronomy.jonaseel.se tmux attach;;

    run)
        # run as root to allow low port
        if test ${port:-0} -lt 1024
        then
            id -u | grep -qx 0 || exec sudo -E PATH=$PATH $0 --cert $cert ${port:+--port $port} ${xtrace:+--debug}
        fi
        cd $(dirname $0)

        type perl6 >/dev/null 2>&1 || usage "perl6 command not found"

        # stop old processes
        pgrep 'micronomy|moar' | grep -v $$ | xargs -r kill

        # keep going
        while true
        do
            # setup nginx redirect
            if test -d /var/www/html
            then
                cp resources/index.html /var/www/html/index.html
                sed -Ei 's:^([ \t]*try_files) .*:\1 $uri /index.html =405;:' /etc/nginx/sites-enabled/default
            fi

            # update certificate if needed
            if test -d $cert
            then
                certbot renew
                export MICRONOMY_TLS_CERT=$cert/fullchain.pem
                export MICRONOMY_TLS_KEY=$cert/privkey.pem
            fi

            # start service
            test $port && export MICRONOMY_PORT=$port
            if id -u | grep -qx 0
            then
                script -c "perl6 -I lib service.p6" /var/log/micronomy-$(date +%Y%m%d%H%M%S).log 2>&1
            else
                perl6 -I lib service.p6
            fi
        done
        ;;
    *)
        usage "unknown target '$target'"
esac
