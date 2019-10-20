#!/bin/bash

# run as root to allow port 443
id -u | grep -qx 0 || exec sudo -E $0

# stop old processes
pgrep 'micronomy|moar' | grep -v $$ | xargs -r kill

cd /home/debian/micronomy
# keep going
while true
do
    # setup nginx redirect
    cp resources/index.html /var/www/html/index.html
    sed -Ei 's:^([ \t]*try_files) .*:\1 $uri /index.html =405;:' /etc/nginx/sites-enabled/default

    # update certificate if needed
    certbot renew

    # set parameters
    export MICRONOMY_PORT=443
    export MICRONOMY_HOST=0.0.0.0
    export MICRONOMY_TLS_CERT=/etc/letsencrypt/live/micronomy.jonaseel.se/fullchain.pem
    export MICRONOMY_TLS_KEY=/etc/letsencrypt/live/micronomy.jonaseel.se/privkey.pem

    # start service
    script -c "perl6 -I lib service.p6" /var/log/micronomy-$(date +%Y%m%d%H%M%S).log 2>&1
done
