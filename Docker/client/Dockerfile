FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Paquetes de red y UI
RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 iputils-ping curl dnsutils ca-certificates \
    xvfb x11vnc fluxbox novnc websockify chromium \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Archivos del proyecto
COPY entrypoint.sh /entrypoint.sh
COPY start-ui.sh /usr/local/bin/start-ui.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/start-ui.sh

# Variables por defecto para la UI
ENV DISPLAY=:0 VNC_PORT=5900 NOVNC_PORT=6081 VNC_PW=clientpass \
    BROWSER_URL=https://example.com SCREEN_GEOMETRY=1280x800x24

# Mantenemos tu entrypoint original para configurar routing/DNS, etc.
ENTRYPOINT ["/entrypoint.sh"]
# No definimos CMD para permitir lanzar UI desde el run-script
