# Runs the cross-built Windows binaries under Wine with a virtual display, for run-windows-wine-checks.sh.
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive WINEDEBUG=-all WINEPREFIX=/wine
RUN apt-get update \
 && apt-get install -y --no-install-recommends wine wine64 xvfb xauth ca-certificates \
      gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
 && rm -rf /var/lib/apt/lists/*
