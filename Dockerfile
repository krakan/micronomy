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

RUN zef install JSON::Tiny Cro::HTTP::Client Terminal::Readsecret
COPY micronomy /usr/local/bin/micronomy
ENTRYPOINT /usr/local/bin/micronomy
