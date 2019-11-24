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
    echo "usage: $0 [-x] [docker|local|debug|deploy|tmux|run]"
    exit 1
}

target=run
port=443
xtrace=
while test $# -gt 0
do
    case $1 in
        -p|--port) port=$2; shift;;
        -x|--debug) xtrace=on; set -x;;
        -*) usage "unknown option '$1'";;
        *) target=$1;;
    esac
    shift
done

# set home dir
cd $(dirname $0)

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

    debug)
	rsync -zva --exclude .precomp --exclude .git . micronomy:micronomy2/
	ssh -t micronomy.jonaseel.se "cd micronomy2 && MICRONOMY_PORT=4443 MICRONOMY_HOST=0.0.0.0 perl6 -I lib service.p6"
        ;;

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
        # run as root to allow port 443
        id -u | grep -qx 0 || exec sudo -E $0 --port $port ${xtrace:+--debug}

        # stop old processes
        pgrep 'micronomy|moar' | grep -v $$ | xargs -r kill

        # keep going
        while true
        do
            # setup nginx redirect
            cp resources/index.html /var/www/html/index.html
            sed -Ei 's:^([ \t]*try_files) .*:\1 $uri /index.html =405;:' /etc/nginx/sites-enabled/default

            # update certificate if needed
            certbot renew

            # set parameters
            export MICRONOMY_PORT=$port
            export MICRONOMY_HOST=0.0.0.0
            export MICRONOMY_TLS_CERT=/etc/letsencrypt/live/micronomy.jonaseel.se/fullchain.pem
            export MICRONOMY_TLS_KEY=/etc/letsencrypt/live/micronomy.jonaseel.se/privkey.pem

            # start service
            script -c "perl6 -I lib service.p6" /var/log/micronomy-$(date +%Y%m%d%H%M%S).log 2>&1
        done
        ;;
    *)
        usage "unknown target '$target'"
esac
