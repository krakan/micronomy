FROM debian:stretch

RUN apt-get update
RUN apt-get -y install \
            build-essential \
            curl \
            gcc \
            git \
            libssl-dev \
            libssl1.0.2 \
            make

RUN curl -LJO https://rakudostar.com/latest/star/source && \
    tar zxf rakudo-star-????.??.tar.gz && \
    mv rakudo-star-????.?? rakudo && \
    cd rakudo && \
    perl Configure.pl --backend=moar --gen-moar && \
    make && \
    make install

ENV PATH=$PATH:/rakudo/install/bin:/rakudo/install/share/perl6/site/bin
RUN zef install JSON::Tiny Cro::HTTP::Client
RUN zef install --force-test Terminal::Readsecret
COPY micronomy /usr/local/bin/micronomy
