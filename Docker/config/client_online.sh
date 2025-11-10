docker run -d --name c1 --network lan0 --ip 10.200.0.11 \
  --cap-add=NET_ADMIN \
  -e ROUTER_IP=10.200.0.254 \
  -e DNS1=1.1.1.1 \
  -e DNS2=8.8.8.8 \
  client:latest

docker run -d --name c2 --network lan0 --ip 10.200.0.12 \
  --cap-add=NET_ADMIN \
  -e ROUTER_IP=10.200.0.254 \
  client:latest

docker run -d --name c3 --network lan0 --ip 10.200.0.13 \
  --cap-add=NET_ADMIN \
  -e ROUTER_IP=10.200.0.254 \
  client:latest
