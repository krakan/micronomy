# syntax=docker/dockerfile:1

# Builder pinned by digest (not just the "bookworm" tag) so the exact OS +
# rakudo + bundled module set can never drift under us.
FROM rakudo-star@sha256:aa608cea2b585d57c54bd1840007eac29ceb05d76b3d5e31438ae0796246de20 AS builder

# libssl-dev is only needed so Cro::TLS's build-time native-library probe can
# find libssl.so while compiling; it is not shipped in the runtime image.
RUN apt-get update && \
    apt-get install -y --no-install-recommends libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# Every module Cro::HTTP/Cro::WebApp pull in transitively, pinned to an exact
# ver/auth/api so the build resolves the same distributions every time
# instead of tracking whatever is newest in the zef ecosystem on the day of
# the build. (Digest::MD5, also required by the app, ships as part of the
# "Digest" distribution already bundled in this pinned base image, so it
# needs no separate pin.) Versions captured from a real resolve against this
# base image on 2026-09-18.
RUN zef install --/test \
    'Cro::Core:ver<0.8.10>:auth<zef:cro>:api<0>' \
    'Cro::TLS:ver<0.8.10>:auth<zef:cro>:api<0>' \
    'Cro::HTTP:ver<0.8.13>:auth<zef:cro>:api<0>' \
    'Cro::WebApp:ver<0.10.1>:auth<zef:cro>:api<0>' \
    'URI::Encode:ver<1.0>:auth<zef:raku-community-modules>' \
    'OpenSSL:ver<0.2.9>:auth<zef:raku-community-modules>' \
    'IO::Socket::Async::SSL:ver<0.8.2>:auth<zef:raku-community-modules>' \
    'IO::Path::ChildSecure:ver<1.2>:auth<zef:raku-community-modules>' \
    'Base64:ver<0.1.0>:auth<github:ugexe>' \
    'HTTP::HPACK:ver<1.0.3>:auth<zef:raku-community-modules>' \
    'if:ver<0.1.5>:auth<zef:raku-community-modules>' \
    'Crypt::Random:ver<0.4.1>:auth<github:skinkade>' \
    'Digest::HMAC:ver<1.0.7>:auth<zef:jjmerelo>' \
    'JSON::JWT:ver<1.1.2>:auth<zef:raku-community-modules>' \
    'TinyFloats:ver<0.0.5>:auth<zef:japhb>' \
    'CBOR::Simple:ver<0.1.4>:auth<zef:japhb>' \
    'Log::Timeline:ver<0.5.2>:auth<zef:raku-community-modules>'

WORKDIR /app
COPY . /app

# Compiles and precompiles the app + its dependency closure so the runtime
# image only ever loads cached bytecode.
RUN raku -c -Ilib service.raku

# Runtime: distroless (no shell, no package manager, no apt/curl/git/python
# left over from the rakudo-star dev image) with just the raku runtime,
# the pinned module closure, OpenSSL's runtime libs, and the app itself.
FROM gcr.io/distroless/cc-debian12:nonroot@sha256:777e96cf322c46bc32aca926c263624c4dc8d7cf37e2fa65ba2c7e697318ebbb

COPY --from=builder /usr/bin/rakudo /usr/bin/rakudo
COPY --from=builder /usr/bin/raku /usr/bin/raku
COPY --from=builder /usr/lib/libmoar.so /usr/lib/libmoar.so
COPY --from=builder /usr/share/nqp /usr/share/nqp
COPY --from=builder /usr/share/perl6/core /usr/share/perl6/core
COPY --from=builder /usr/share/perl6/lib /usr/share/perl6/lib
COPY --from=builder /usr/share/perl6/runtime /usr/share/perl6/runtime
COPY --from=builder /usr/share/perl6/site /usr/share/perl6/site
COPY --from=builder /usr/share/perl6/vendor /usr/share/perl6/vendor
COPY --from=builder /usr/lib/x86_64-linux-gnu/libssl.so* /usr/lib/x86_64-linux-gnu/
COPY --from=builder /usr/lib/x86_64-linux-gnu/libcrypto.so* /usr/lib/x86_64-linux-gnu/

WORKDIR /app
COPY --from=builder --chown=nonroot:nonroot /app/lib /app/lib
COPY --from=builder --chown=nonroot:nonroot /app/resources /app/resources
COPY --from=builder --chown=nonroot:nonroot /app/service.raku /app/service.raku

ENV MICRONOMY_PORT="8080" \
    MICRONOMY_HOST="0.0.0.0"
EXPOSE 8080
ENTRYPOINT ["raku", "-Ilib", "service.raku"]
