FROM debian:stable-slim

# Herramientas útiles para portal cautivo y troubleshooting
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      iproute2 iputils-ping curl ca-certificates \
      dnsutils netcat-openbsd tcpdump jq \
    && rm -rf /var/lib/apt/lists/*

# Variables ajustables
ENV ROUTER_IP=10.200.0.254 \
    DNS1=1.1.1.1 \
    DNS2=8.8.8.8

# Scripts  para detección/login de portal cautivo


COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
