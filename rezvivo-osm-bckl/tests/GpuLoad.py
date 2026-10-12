"""Windows per-process GPU engine counters; absence is reported, never as zero load."""
import ctypes as C
import re


class Value(C.Structure):
    _fields_ = [('status', C.c_ulong), ('value', C.c_double)]


class Item(C.Structure):
    _fields_ = [('name', C.c_wchar_p), ('value', Value)]


class GpuLoad:
    def __init__(self, counter_path=r'\GPU Engine(*)\Utilization Percentage'):
        self.error = None
        self.query = C.c_void_p()
        self.counter = C.c_void_p()
        self.pdh = C.WinDLL('pdh')
        self.pdh.PdhOpenQueryW.argtypes = [C.c_wchar_p, C.c_size_t, C.POINTER(C.c_void_p)]
        self.pdh.PdhAddEnglishCounterW.argtypes = [C.c_void_p, C.c_wchar_p, C.c_size_t, C.POINTER(C.c_void_p)]
        self.pdh.PdhCollectQueryData.argtypes = [C.c_void_p]
        self.pdh.PdhCloseQuery.argtypes = [C.c_void_p]
        self.pdh.PdhGetFormattedCounterArrayW.argtypes = [C.c_void_p, C.c_ulong,
            C.POINTER(C.c_ulong), C.POINTER(C.c_ulong), C.c_void_p]
        status = self.pdh.PdhOpenQueryW(None, 0, C.byref(self.query))
        if not status:
            status = self.pdh.PdhAddEnglishCounterW(self.query,
                counter_path, 0, C.byref(self.counter))
        if status:
            self.error = 'PDH unavailable: '+hex(status & 0xffffffff)
        else:
            self.pdh.PdhCollectQueryData(self.query)

    def sample(self, own_pid):
        if self.error:
            return {'available': False, 'error': self.error}
        status = self.pdh.PdhCollectQueryData(self.query)
        if status:
            return {'available': False, 'status': hex(status & 0xffffffff)}
        size, count = C.c_ulong(), C.c_ulong()
        self.pdh.PdhGetFormattedCounterArrayW(self.counter, 0x200,
            C.byref(size), C.byref(count), None)
        if not size.value:
            return {'available': False, 'error': 'GPU counter has no samples'}
        buf = C.create_string_buffer(size.value)
        status = self.pdh.PdhGetFormattedCounterArrayW(self.counter, 0x200,
            C.byref(size), C.byref(count), buf)
        if status:
            return {'available': False, 'status': hex(status & 0xffffffff)}
        own, others = [], []
        for item in C.cast(buf, C.POINTER(Item))[:count.value]:
            if item.value.status not in (0, 1) or item.value.value < .05:
                continue
            match = re.search(r'pid_(\d+)_', item.name)
            if not match:
                continue
            pid = int(match.group(1))
            row = dict(pid=pid, engine=item.name, percent=round(item.value.value, 2))
            (own if pid == own_pid else others).append(row)
        return {'available': True, 'own': own, 'other': others,
                'contended': any(v['percent'] > 5 for v in others)}

    def close(self):
        if self.query:
            self.pdh.PdhCloseQuery(self.query)
            self.query = None
