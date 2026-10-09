#!/usr/bin/env bash
# Test IPC only: a dummy "equipment LAN" carrying the plant's device addresses.
set -euo pipefail
ip link show plant0 >/dev/null 2>&1 || ip link add plant0 type dummy
ip link set plant0 up
for a in 10.77.0.11 10.77.0.12 10.77.0.21 10.77.0.22 10.77.0.31 $(seq -f '10.77.1.%g' 1 24); do
  ip addr show dev plant0 | grep -q " $a/" || ip addr add "$a/32" dev plant0
done
ip route show 10.77.0.0/16 | grep -q plant0 || ip route add 10.77.0.0/16 dev plant0 2>/dev/null || true
