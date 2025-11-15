# ===== Cliente (navegador + noVNC) =====
FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

# Solo lo necesario para UI y pruebas de conectividad
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    curl ca-certificates iproute2 \
    iputils-ping \
    x11vnc xvfb fluxbox novnc websockify chromium \
 && rm -rf /var/lib/apt/lists/*


# Scripts del cliente
COPY entrypoint.sh /entrypoint.sh
COPY start-ui.sh /usr/local/bin/start-ui.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/start-ui.sh

# noVNC
EXPOSE 6081

CMD ["/entrypoint.sh"]
