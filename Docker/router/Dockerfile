FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 iptables iputils-ping curl dnsutils ca-certificates \
    xvfb x11vnc fluxbox novnc websockify chromium \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY start-ui.sh /usr/local/bin/start-ui.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/start-ui.sh

ENV DISPLAY=:0 VNC_PORT=5900 NOVNC_PORT=6081 VNC_PW=routerpass \
    BROWSER_URL=https://example.com SCREEN_GEOMETRY=1280x800x24

ENTRYPOINT ["/entrypoint.sh"]
