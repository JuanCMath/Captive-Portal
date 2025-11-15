# ===== Router (portal cautivo) =====
FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    iproute2 iptables ipset dnsmasq curl ca-certificates \
    iputils-ping \
    python3 python3-venv python3-pip \
    x11vnc xvfb fluxbox novnc websockify chromium \
  && rm -rf /var/lib/apt/lists/*



# --- Crear y activar venv ---
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# Dependencias Python (sin [standard] para evitar compilación)
WORKDIR /app
COPY app /app/app
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir fastapi uvicorn jinja2 python-multipart

# Scripts
COPY entrypoint.sh /entrypoint.sh
COPY start-ui.sh /usr/local/bin/start-ui.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/start-ui.sh \
 && mkdir -p /etc/dnsmasq.d

EXPOSE 80 6081
CMD ["/entrypoint.sh"]
