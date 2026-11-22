# Runs the cross-built Windows binaries under Wine with a virtual display and audio endpoint, for run-windows-wine-checks.sh.
FROM debian:trixie-slim AS wine
ENV DEBIAN_FRONTEND=noninteractive WINEDEBUG=-all WINEPREFIX=/wine
RUN apt-get update \
 && apt-get install -y --no-install-recommends wine wine64 xvfb xauth ca-certificates pulseaudio pulseaudio-utils \
      gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
 && rm -rf /var/lib/apt/lists/*

# A native QEMU avoids Rosetta's GDT fault on concurrent WinSock connections.
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS emulator
RUN apt-get update && apt-get install -y --no-install-recommends qemu-user

FROM wine AS qemu
COPY --from=emulator /usr/bin/qemu-x86_64 /usr/local/bin/quietdesk-qemu64

FROM wine AS default
