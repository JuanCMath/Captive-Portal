# ===== Router (portal cautivo) =====
FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    iproute2 iptables ipset dnsmasq curl ca-certificates \
    iputils-ping \
    python3 \
    x11vnc xvfb fluxbox novnc websockify chromium \
    nginx openssl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Código de la app (backend nativo en Python)
COPY app /app/app

# Scripts
COPY entrypoint.sh /entrypoint.sh
COPY start-ui.sh /usr/local/bin/start-ui.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/start-ui.sh \
 && mkdir -p /etc/dnsmasq.d

# HTTP del portal (nginx) y HTTPS (TLS)
EXPOSE 80 443

CMD ["/entrypoint.sh"]
