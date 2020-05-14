FROM croservices/cro-http:0.8.2
RUN zef install Cro::WebApp URI::Encode Digest::MD5

RUN apt-get update && \
        apt-get upgrade -y && \
        apt-get auto-remove && \
        apt-get clean

RUN mkdir /app
COPY . /app
WORKDIR /app

RUN perl6 -c -Ilib service.p6
ENV MICRONOMY_PORT="443" \
        MICRONOMY_HOST="0.0.0.0" \
        MICRONOMY_TLS_CERT=/app/resources/fake-tls/server-crt.pem \
        MICRONOMY_TLS_KEY=/app/resources/fake-tls/server-key.pem
EXPOSE 4443
CMD perl6 -Ilib service.p6
