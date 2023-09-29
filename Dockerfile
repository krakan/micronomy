FROM croservices/cro-http:0.8.9
ENV PATH $PATH:/root/.raku/bin
RUN zef install Cro::WebApp URI::Encode Digest::MD5

RUN sed -Ei 's/kinetic/mantic/' /etc/apt/sources.list /etc/apt/sources.list.d/* && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get auto-remove -y && \
    apt-get clean

RUN mkdir /app
COPY . /app
WORKDIR /app

RUN raku -c -Ilib service.raku
ENV MICRONOMY_PORT="8080" \
        MICRONOMY_HOST="0.0.0.0"
EXPOSE 8080
CMD raku -Ilib service.raku
