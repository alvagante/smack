"""Read CPU, wakeup and footprint counters without polling the measured process."""
import ctypes
import ctypes.util
import json
import sys
import time

class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in [
        'user_ns', 'system_ns', 'package_idle_wakeups', 'interrupt_wakeups', 'pageins', 'wired_bytes',
        'resident_bytes', 'footprint_bytes', 'start_abstime', 'exit_abstime']]
lib = ctypes.CDLL(ctypes.util.find_library('proc'), use_errno=True)
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
def read(pid):
    value = Usage()
    if lib.proc_pid_rusage(pid, 0, ctypes.byref(value)) != 0:
        return {'error': ctypes.get_errno()}
    return {name: getattr(value, name) for name, _ in Usage._fields_ if name != 'uuid'}
pids = [int(value) for value in sys.argv[2:]]
before = {pid: read(pid) for pid in pids}
started = time.monotonic()
time.sleep(float(sys.argv[1]))
after = {pid: read(pid) for pid in pids}
print(json.dumps({'elapsed_s': time.monotonic() - started, 'before': before, 'after': after}, sort_keys=True))
