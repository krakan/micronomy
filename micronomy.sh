#!/bin/bash
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
    echo "or:    $0 [--debug] [--host <address>] [--port <int>] [--certdir <path>] [--standalone] [run]"
    exit 1
}

scriptdir=$(readlink -f $(dirname $0))
target=run
port=
xtrace=
cert=/etc/letsencrypt/live/micronomy.jonaseel.se
sudo test -d $cert || cert=$scriptdir/resources/fake-tls
standalone=
beta=
while test $# -gt 0
do
    case $1 in
        -p|--port) port=$2; shift;;
        -h|--host) export MICRONOMY_HOST=$2; shift;;
        -c|--cert*) cert=$2; shift;;
        -s|--standalone) standalone=1;;
        -b|--beta) beta=1;;
        -x|--debug) xtrace=on; set -x;;
        -*) usage "unknown option '$1'";;
        *) target=$1;;
    esac
    shift
done

# set home dir
test $target = run || cd $scriptdir

# do your thing
case $target in
    docker)
        exist=$(docker images -q micronomy:latest)
        if test -z $exist || {
                touch --date=$(docker inspect micronomy:latest | jq -r .[].Created) Dockerfile &&
                    find . -newer Dockerfile -type f | \
                        grep -E '^./((lib|resources)/|^service.p6)' | grep -v ./lib/.precomp;
            }
        then
            docker build -t micronomy .
        fi
        docker run -it --rm -p 443:443 micronomy
        ;;

    local) MICRONOMY_PORT=4443 MICRONOMY_HOST=0.0.0.0 perl6 -I lib service.p6;;

    deploy)
        if rsync -zva --exclude .precomp . micronomy:micronomy/ | tee /dev/tty |
                grep -Eq '^(lib|resources)/|^service.p6'
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
            id -u | grep -qx 0 || exec sudo -E PATH=$PATH $0 --cert $cert ${standalone:+--standalone} ${port:+--port $port} ${xtrace:+--debug}
        fi
        cd $scriptdir

        type perl6 >/dev/null 2>&1 || usage "perl6 command not found"

        # twiddle nginx reverse proxy
        if grep -q 'server_name micronomy.jonaseel.se' /etc/nginx/sites-enabled/reverse-proxy
        then
            if test "$port" = 8080 && ! netstat -ln | grep -w LISTEN | grep -q :8081
            then
                # let nginx proxy both sites to the same port
                sudo sed -Ei 's/(proxy_pass.*):8081/\1:8080/' /etc/nginx/sites-enabled/reverse-proxy
                sudo systemctl reload nginx
            elif test "$port" = 8081 && ! grep -q 'proxy_pass http://localhost:8081' /etc/nginx/sites-enabled/reverse-proxy
            then
                # let nginx proxy the beta site to the separate port
                sudo sed -Ei '/server_name micronomy.jonaseel.se;/,/^}/{s/(proxy_pass.*):8080/\1:8081/}' \
                     /etc/nginx/sites-enabled/reverse-proxy
                sudo systemctl reload nginx
            fi
        fi

        # keep going
        while true
        do
            # update certificate if needed
            if echo "$cert" | grep -q letsencrypt
            then
                valid=$(sudo certbot certificates 2>/dev/null | grep -o 'VALID.*' | cut -d' ' -f2)
                if test ${valid:-90} -le 30
                then
                    sudo systemctl stop nginx
                    sudo certbot renew
                    sudo systemctl restart nginx
                fi
            fi
            if test $standalone
            then
                export MICRONOMY_TLS_CERT=$cert/fullchain.pem
                export MICRONOMY_TLS_KEY=$cert/privkey.pem
            fi

            if test $beta
            then
                test -f $scriptdir/resources/b3-orig.svg ||
                    cp $scriptdir/resources/b3.svg $scriptdir/resources/b3-orig.svg
                cp $scriptdir/resources/beta3.svg $scriptdir/resources/b3.svg
                sed -i 's/@ B3/@ β3/' $scriptdir/resources/templates/common.html.tmpl
            elif test -f $scriptdir/resources/b3-orig.svg
            then
                cp $scriptdir/resources/b3-orig.svg $scriptdir/resources/b3.svg
                sed -i 's/@ β3/@ B3/' $scriptdir/resources/templates/common.html.tmpl
            fi

            # start service
            echo Starting ...
            test $port && export MICRONOMY_PORT=$port
            test $TMUX && tmux rename-window micronomy
            if id -u | grep -qx 0
            then
                script -c "perl6 -I lib service.p6" -f /var/log/micronomy-$(date +%Y%m%d%H%M%S).log 2>&1
            else
                mkdir -p $scriptdir/log
                script -c "perl6 -I lib service.p6" -f $scriptdir/log/micronomy-$(date +%Y%m%d%H%M%S).log 2>&1
            fi
            test $TMUX && tmux set automatic-rename
            # wait for optional extra CTRL-C
            sleep 1
        done
        ;;
    *)
        usage "unknown target '$target'"
esac
