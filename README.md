# micronomy

An alternative client to access Maconomy.

## Requirements

Either install Rakudo and the required modules (see Dockerfile) and run
micronomy locally or use the provided Dockerfile to build a docker image to run
in. In the latter case a working docker installation is required.

### Build and use the docker image

    docker build --pull -t micronomy .
    alias micronomy="docker run -u $(id -u) -it --rm -v $HOME:/work -e HOME=/work micronomy micronomy"

## Example workflow

    micronomy login
    micronomy get
    micronomy set --row 0 --day 1 --hours 8.5
    micronomy set --row 0 --day 2 --hours 7.5
    micronomy set --row 0 --day 3 --hours 7
    micronomy set --row 0 --day 4 --hours 9
    micronomy set --row Semester --day fredag --hours 8
    micronomy approve

## Usage message

    micronomy --help
    Usage:
      micronomy login [-u|--user=<Str>] [-p|--pass=<Str>] [-s|--server=<Str>]
      micronomy logout [-s|--server=<Str>]
      micronomy get [-s|--server=<Str>] [-w|--week=<Str>] [-f|--file=<Str>] [-j|--json]
      micronomy set -r|--row=<Str> -d|--day=<Str> -h|--hours=<Str> [-s|--server=<Str>] [-w|--week=<Str>] [-j|--json]
      micronomy approve [-s|--server=<Str>] [-w|--week=<Str>] [-r|--reason=<Str>] [-j|--json]

### Input formats

#### User

The `--user` option can be used to provide the user name when logging in. The
default is to prompt for it.

#### Password

It is possible to provide the password on the command line but the default is to
prompt for it during login.

#### Weeks

The `--week` option can be either a two digit week number, an eight digit date
or an increment or decrement indicated by a leading `+` or `-` character.

The week number may be prefixed with a four digit year and suffixed with the
characters `A` or `B`. The suffix may be needed when the week falls on a month
boundary and indicates the first or second part of the week respectively.

If the week number isn't prefixed with the year it may exclude a leading zero.

Providing a date will result in the week that the specified date occurs in.

Separators are optional.

Default week is current week except on Mondays before noon when the default is
last week.

#### Hours

The `--hours` option should be given as a decimal hour.

#### Day

The `--day` option can be week day number from 1 to 7 or a unique part of a day
name in either Swedish or English. It is currently no possible to set more than
on day per command.

#### Row

The `--row` option can be a row number (starting from `0`) or a unique part of
the row title. Adding rows to the time sheet isn't implemented (yet?).

#### Server

The `--server` option should be `<protocol>://<server>`. It is intended for
development with a dummy server. The default server is
`https://b3iaccess.deltekenterprise.com`. It may be possible to use another
iAccess server but that has not been tested.

#### Examples

    micronomy login --server=http://localhost --user=sven.uthorn@b3.se
    micronomy get --week=30
    micronomy get -w=201952
    micronomy get -w=2019-12-24
    micronomy get --week=-1
    micronomy set --day=3 --row=1 --hours=7.25
    for week in 1 2 3 4
    do
      for day in M Ti O To F
      do
        micronomy set --week=+$week --day=$day -r=Semester -h=8
      done
      micronomy --week=+$week approve
    done

## Sessions

A session token is retrieved on login and cached in `$HOME/.micronomy/session`.
It will be invalidated and removed on logout. The session timeout is currently
unknown but it's more than a couple of hours and less than a day.

If the session has timed out, any command except `login` will return a `401
Unauthorized` exception.

It is possible to re-login without logging out first. That would replace but not
invalidate the old session token which means it would still be valid until it
was timed out.

## TODO

* complete Dockerfile - Done
* write usage instructions - Done
* start writing Cro service
