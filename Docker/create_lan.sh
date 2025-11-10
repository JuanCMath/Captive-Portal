docker network create \
  --driver bridge \
  --subnet 10.200.0.0/24 \
  --gateway 10.200.0.1 \
  lan0
