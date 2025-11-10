FROM debian:stable-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        iproute2 iputils-ping iptables curl ca-certificates procps && \
    rm -rf /var/lib/apt/lists/*

# Habilitar el forwarding de forma persistente
RUN echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

ENV LAN_CIDR=10.200.0.0/24 \
    UPLINK_IF=eth0 \
    LAN_IF=eth1

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
