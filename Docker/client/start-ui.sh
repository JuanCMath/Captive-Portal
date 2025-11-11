#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=:1
XVFB_W=1366
XVFB_H=768
XVFB_D=24

# Xvfb
if ! pgrep -x Xvfb >/dev/null; then
  Xvfb :1 -screen 0 ${XVFB_W}x${XVFB_H}x${XVFB_D} &
fi

# WM mínimo
if ! pgrep -x fluxbox >/dev/null 2>&1; then
  fluxbox >/tmp/fluxbox.log 2>&1 &
fi

# noVNC / websockify en 6081 → VNC :5900
if ! pgrep -f websockify >/dev/null; then
  websockify --web=/usr/share/novnc/ 6081 localhost:5900 >/tmp/novnc.log 2>&1 &
fi

# VNC server
if ! pgrep -x x11vnc >/dev/null; then
  x11vnc -display :1 -nopw -forever >/tmp/x11vnc.log 2>&1 &
fi

# Lanzar navegador si hay URL
if [[ -n "${BROWSER_URL:-}" ]]; then
  ( sleep 2; command -v chromium >/dev/null && chromium --no-sandbox "$BROWSER_URL" || true ) &
fi

# Mantener el proceso vivo
tail -f /tmp/novnc.log /tmp/x11vnc.log /tmp/fluxbox.log /tmp/dnsmasq.log 2>/dev/null || tail -f /tmp/novnc.log
