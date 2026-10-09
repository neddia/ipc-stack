#!/usr/bin/env bash
# ui.sh '<json commands>'  -> prints results compactly (e2e ui-driver client)
curl -s 127.0.0.1:9333 -d "$1" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in d.get("results",[d]):
    if "text" in r: print(r["text"][:int(sys.argv[1])])
    elif "value" in r: print(r["value"] if isinstance(r["value"],str) else json.dumps(r["value"])[:4000])
    else: print(json.dumps(r)[:600])
if d.get("console"): print("CONSOLE:", d["console"])
' "${2:-4000}"
