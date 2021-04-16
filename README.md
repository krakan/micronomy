# B3 micronomy

A middleware and alternative web GUI to access Maconomy. It is mainly
intended as a programming exercise but is actually somewhat easier to
work with than the main Maconomy GUI.

# Usage

## Connecting

Point you browser at https://micronomy.init.se/ and log in with your
B3 Maconomy credentials.

To run it locally you can either install Rakudo and the required
modules or make sure you have a working Docker installation and build
and run the Dockerfile. The browser will complain about the fake
certificate in use when running locally but that's expected. Just
running

```
./micronomy.sh docker
```

could be enough.


Technically there's nothing stopping you from connecting the micronomy
service to some other Maconomy backend but only the B3 Maconomy has
been tested.

## Hours

Time is expected to be filled in as decimal hours; eg. "an hour and a
half" should be entered as `1.5`. The sums shown beneath the time
records are read from the API; no time calculations are done in
Micronomy.

## Weeks

To directly switch to a specific week you can add `?date=YYYY-MM-DD`
in the browsers address field. Note that weeks on month borders will
be divided into `A` and `B` as in Maconomy.

## Projects

Adding or removing the projects shown currently has to be done in
Maconomy. Note though, that you can specify in Maconomy that the same
records should be shown on consecutive weeks too.

## Keyboard shortcuts

Hitting enter while entering times is equivalent to pressing the
"Spara" button; ie. it saves the entered times into the database. To
switch to next or previous week you can press the appropriate buttons
or `Ctrl-Right` or `Ctrl-Left` respectively. The arrow keys can be
used to navigate between the time fields. Hitting `Escape` will
unfocus any time field and `Ctrl-Down` will re-focus the same field.

## Submitting

When a week is completely filled in, it should be submitted by
pressing the "Avlämna" button. As in Maconomy, there's nothing
stopping you from re-submitting an already submitted week but if you
change an already billed week, the changes will probably be ignored by
the billing system. So don't do that without consulting with you
manager first.

# Contributing

If you find any bugs or even want to fix one you can go to
https://github.com/krakan/micronomy/issues/. If the bug you've found
isn't there already, please report a new issue. To contribute code
you'll have to fork the code to you own Github account and commit your
code there and then make a pull request against the main repository.

You're also welcome to add some of the missing features already
reported as issues. Follow the same procedure as for bugs.

# Server setup

Start with eg. a basic Debian and then run the following:

```
sudo apt update
sudo apt install -y libssl-dev git perl curl rsync certbot nginx tmux

curl https://rakubrew.org/install-on-perl.sh | bash
eval "$($HOME/.rakubrew/bin/rakubrew init Bash)"

rakubrew download
rakubrew build zef

zef install --serial Cro::WebApp URI::Encode Digest::MD5
```

Basing this on Debian is of course optional - any platform that can
run `rakudo` should work but then the above installation commands will
be different.

After the server is set up, clone this repo to it and run

```
export MICRONOMY_PORT=443
export MICRONOMY_HOST=0.0.0.0
perl6 -I lib service.p6
```

There is also a script `micronomy.sh` that handles Let's Encrypt renewal
and rudimentary logging. You'll most likely need to customize it before
using it.

Unfortunately, there seems to be some problem with SSL that under some
circumstances makes HTTPS connections hang indefinitely. In that case
one can use the `resources/nginx.conf` file to let Nginx handle the SSL
termination and then run Micronomy on an unprivileged port - eg.:

```
sudo sed -Ei "s:^( *ssl_certificate) .*:\1 $MICRONOMY_TLS_CERT;:" resources/nginx.conf
sudo sed -Ei "s:^( *ssl_certificate_key) .*:\1 $MICRONOMY_TLS_KEY;:" resources/nginx.conf
sudo cp resources/nginx.conf /etc/nginx/sites-enabled/default
sudo systemctl restart nginx
./micronomy.sh --port 8080
```
