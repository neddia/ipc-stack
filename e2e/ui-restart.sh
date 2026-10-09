#!/usr/bin/env bash
# Restart the e2e browser (fresh profile and cache): stop whatever holds the port.
pid=$(ss -ltnp 2>/dev/null | sed -n 's/.*127.0.0.1:9333 .*pid=\([0-9]*\).*/\1/p' | head -1)
[ -n "$pid" ] && { kill "$pid" 2>/dev/null; sleep 3; kill -9 "$pid" 2>/dev/null; }
for _ in $(seq 1 20); do ss -ltn 2>/dev/null | grep -q '127.0.0.1:9333 ' || break; sleep 0.5; done
cd "$(dirname "$0")" && (setsid nohup node ui-driver.cjs > "$HOME/.cache/toops-e2e/run/ui-driver.log" 2>&1 &)
for _ in $(seq 1 30); do grep -q 'ui-driver on' "$HOME/.cache/toops-e2e/run/ui-driver.log" 2>/dev/null && break; sleep 0.5; done
cat "$HOME/.cache/toops-e2e/run/ui-driver.log"
