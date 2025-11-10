docker rm -f router 2>/dev/null || true
docker run -d --name router \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  -e UPLINK_IF=eth0 -e LAN_IF=eth1 -e LAN_CIDR=10.200.0.0/24 \
  router:latest

# Conectar la segunda interfaz después (el script ya la espera)
docker network connect --ip 10.200.0.254 lan0 router
