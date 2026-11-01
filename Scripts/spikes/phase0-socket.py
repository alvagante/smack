"""Primitive socket probes only; no production server and no privileged peer."""
import ctypes
import errno
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import time

root = Path(sys.argv[1]) / 'socket'
root.mkdir(mode=0o700)
libc = ctypes.CDLL(None, use_errno=True)
libc.getpeereid.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
path = root / 'control.sock'
listener = socket.socket(socket.AF_UNIX)
listener.bind(str(path))
path.chmod(0o600)
listener.listen(1)
child = subprocess.Popen([sys.executable, '-c', 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"probe"); time.sleep(.2)', str(path)])
peer, _ = listener.accept()
uid, gid = ctypes.c_uint(), ctypes.c_uint()
assert libc.getpeereid(peer.fileno(), ctypes.byref(uid), ctypes.byref(gid)) == 0
assert uid.value == os.geteuid()
assert peer.recv(5) == b'probe'
peer.close()
child.wait()
listener.close()
stale = socket.socket(socket.AF_UNIX)
try:
    stale.connect(str(path))
    raise AssertionError('closed listener connected')
except OSError as error:
    assert error.errno == errno.ECONNREFUSED
stale.close()
results = {'getpeereid_uid_matches': uid.value == os.geteuid(), 'getpeereid_gid_matches': gid.value == os.getegid(),
           'directory_mode': oct(stat.S_IMODE(root.stat().st_mode)), 'socket_mode': oct(stat.S_IMODE(path.stat().st_mode)),
           'stale_connect': 'ECONNREFUSED', 'stale_owner_matches': path.stat().st_uid == os.geteuid(), 'cross_uid': 'not tested'}
length_results = {}
for size in [103, 104, 110, 160]:
    # Exact UTF-8 byte lengths, not character counts; all names here are ASCII.
    probe = str(root) + '/' + 'x' * (size - len(str(root)) - 1)
    client = socket.socket(socket.AF_UNIX)
    try:
        client.bind(probe)
        length_results[str(size)] = 'bound'
    except OSError as error:
        length_results[str(size)] = str(error)
    finally:
        client.close()
results['path_bytes'] = length_results
# Keep each run isolated while exercising the same per-user temporary fallback layout.
fallback = root / ('smack-' + str(os.geteuid()))
fallback.mkdir(mode=0o700)
fallback_path = fallback / 'control.sock'
assert len(os.fsencode(fallback_path)) <= 103
server = socket.socket(socket.AF_UNIX)
server.bind(str(fallback_path)); fallback_path.chmod(0o600); server.listen(1)
client = socket.socket(socket.AF_UNIX); client.connect(str(fallback_path))
accepted, _ = server.accept()
client.sendall(b'fallback'); assert accepted.recv(8) == b'fallback'
accepted.close(); client.close(); server.close()
results['fallback_roundtrip'] = True
results['fallback_path_bytes'] = len(os.fsencode(fallback_path))
print(json.dumps(results, sort_keys=True))
