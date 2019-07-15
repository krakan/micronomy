# micronomy

An alternative client to access Maconomy.

## Requirements

Either install Rakudo and the required modules (see Dockerfile) and run
micronomy locally or use the provided Dockerfile to build a docker image to run
in. In the latter case a working docker installation is required.

### Build and use the docker image

    docker build -t micronomy .
    alias micronomy='docker run -u $(id -u) -it --rm -v $HOME:/work -e HOME=/work micronomy micronomy'

### Example workflow

    micronomy login
    micronomy get
    micronomy set --row 0 --day 1 --hours 8
    micronomy set --row 0 --day 2 --hours 8
    micronomy set --row 0 --day 3 --hours 8
    micronomy set --row 0 --day 4 --hours 8
    micronomy set --row 0 --day 5 --hours 8
    micronomy approve

### Usage message

    micronomy --help
    Usage:
      micronomy login [-u|--user=<Str>] [-p|--pass=<Str>] [-s|--server=<Str>]
      micronomy logout [-s|--server=<Str>]
      micronomy get [-s|--server=<Str>] [-w|--week=<Str>] [-f|--file=<Str>] [-j|--json]
      micronomy set -r|--row=<Int> -d|--day=<Int> -h|--hours=<Str> [-s|--server=<Str>] [-w|--week=<Str>] [-j|--json]
      micronomy approve [-s|--server=<Str>] [-w|--week=<Str>] [-r|--reason=<Str>] [-j|--json]

## TODO

* complete Dockerfile - Done
* write usage instructions - Done
* start writing Cro service
