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

RUN curl https://rakudostar.com/latest/star/source/ | tar zx && \
    cd rakudo-star-????.?? && \
    perl Configure.pl --backend=moar --gen-moar && \
    make && \
    make install

ENV PATH=$PATH:/rakudo/install/bin:/rakudo/install/share/raku/site/bin
RUN ln -s /rakudo-star-????.?? /rakudo
RUN zef install JSON::Tiny Cro::HTTP::Client
RUN zef install --force-test Terminal::Readsecret
COPY micronomy /usr/local/bin/micronomy
