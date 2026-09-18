FROM rakudo-star:bookworm
ENV PATH $PATH:/root/.raku/bin

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get auto-remove -y && \
    apt-get install -y libssl-dev && \
    apt-get clean

RUN zef install Cro::HTTP Cro::WebApp URI::Encode Digest::MD5

RUN mkdir /app
COPY . /app
WORKDIR /app

RUN raku -c -Ilib service.raku
ENV MICRONOMY_PORT="8080" \
    MICRONOMY_HOST="0.0.0.0"
EXPOSE 8080
CMD ["raku", "-Ilib", "service.raku"]
