#!/usr/bin/env bash
set -euo pipefail

# Poner el default route al router del laboratorio (requiere NET_ADMIN en docker run)
ip route del default 2>/dev/null || true
ip route add default via "${ROUTER_IP}"

# DNS mínimos
printf "nameserver %s\n" "${DNS1}" > /etc/resolv.conf
[ -n "${DNS2}" ] && printf "nameserver %s\n" "${DNS2}" >> /etc/resolv.conf

exec "$@"
