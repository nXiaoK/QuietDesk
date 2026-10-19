# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod *.go ./
COPY cmd/ ./cmd/
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -buildvcs=false -o /quietdesk-relay ./cmd/quietdesk-relay

FROM alpine:3.23
RUN apk add --no-cache openssl \
    && addgroup -S -g 65532 relay \
    && adduser -S -D -H -u 65532 -G relay relay \
    && mkdir -p /var/lib/quietdesk-relay /etc/quietdesk-relay \
    && chown relay:relay /var/lib/quietdesk-relay /etc/quietdesk-relay \
    && chmod 700 /var/lib/quietdesk-relay /etc/quietdesk-relay
COPY --from=build /quietdesk-relay /usr/local/bin/quietdesk-relay
COPY --chmod=755 docker/provision.sh /usr/local/bin/provision-relay
USER 65532:65532
EXPOSE 7443/tcp 7443/udp
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -T 3 -O /dev/null http://127.0.0.1:9091/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/quietdesk-relay"]
CMD ["--listen", ":7443", "--cert", "/etc/quietdesk-relay/fullchain.pem", "--key", "/etc/quietdesk-relay/privkey.pem", "--access-key-file", "/var/lib/quietdesk-relay/access.key", "--state", "/var/lib/quietdesk-relay/devices.json"]
