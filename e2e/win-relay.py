"""Windows-side stdio<->TCP relay so WSL's ssh can reach Hyper-V Default Switch VMs.
Used as: ssh -o ProxyCommand='python.exe C:\\...\\win-relay.py %h %p' ... (development only)."""
import socket
import sys
import threading

sock = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=15)
sock.settimeout(None)


def pump_in():
    stdin = sys.stdin.buffer.raw
    while True:
        data = stdin.read(65536)
        if not data:
            sock.shutdown(socket.SHUT_WR)
            return
        sock.sendall(data)


threading.Thread(target=pump_in, daemon=True).start()
out = sys.stdout.buffer
while True:
    data = sock.recv(65536)
    if not data:
        break
    out.write(data)
    out.flush()
