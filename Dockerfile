FROM croservices/cro-http:0.8.1
RUN zef install Cro::WebApp URI::Encode

RUN mkdir /app
COPY . /app
WORKDIR /app

RUN perl6 -c -Ilib service.p6
ENV MICRONOMY_PORT="443" MICRONOMY_HOST="0.0.0.0"
EXPOSE 443
CMD perl6 -Ilib service.p6
