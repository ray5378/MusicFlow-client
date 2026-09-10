"""精确偏移分析: 高频采样平台线程, 记录 flutter_windows.dll 内命中的
精确偏移, 并打印符号+位移, 验证热点函数身份。

用法: python precise_sampler.py <pid> <tid> [次数]
"""
import ctypes
import ctypes.wintypes as wt
import sys
from collections import Counter

kernel32 = ctypes.WinDLL("kernel32")
psapi = ctypes.WinDLL("psapi")
dbghelp = ctypes.WinDLL("dbghelp")

PROCESS_ALL = 0x1F0FFF
THREAD_ALL = 0x1FFFFF
CONTEXT_AMD64 = 0x00100B

pid = int(sys.argv[1])
tid = int(sys.argv[2])
N = int(sys.argv[3]) if len(sys.argv) > 3 else 3000

hproc = kernel32.OpenProcess(PROCESS_ALL, False, pid)
hth = kernel32.OpenThread(THREAD_ALL, False, tid)
dbghelp.SymSetOptions(0x10 | 0x4)
dbghelp.SymInitializeW(hproc, None, True)

class CONTEXT(ctypes.Structure):
    _fields_ = [
        ("P1Home", ctypes.c_uint64 * 6),
        ("ContextFlags", ctypes.c_uint32), ("MxCsr", ctypes.c_uint32),
        ("SegCs", ctypes.c_uint16), ("SegDs", ctypes.c_uint16),
        ("SegEs", ctypes.c_uint16), ("SegFs", ctypes.c_uint16),
        ("SegGs", ctypes.c_uint16), ("SegSs", ctypes.c_uint16),
        ("EFlags", ctypes.c_uint32),
        ("Dr0", ctypes.c_uint64), ("Dr1", ctypes.c_uint64),
        ("Dr2", ctypes.c_uint64), ("Dr3", ctypes.c_uint64),
        ("Dr6", ctypes.c_uint64), ("Dr7", ctypes.c_uint64),
        ("Rax", ctypes.c_uint64), ("Rcx", ctypes.c_uint64),
        ("Rdx", ctypes.c_uint64), ("Rbx", ctypes.c_uint64),
        ("Rsp", ctypes.c_uint64), ("Rbp", ctypes.c_uint64),
        ("Rsi", ctypes.c_uint64), ("Rdi", ctypes.c_uint64),
        ("R8", ctypes.c_uint64), ("R9", ctypes.c_uint64),
        ("R10", ctypes.c_uint64), ("R11", ctypes.c_uint64),
        ("R12", ctypes.c_uint64), ("R13", ctypes.c_uint64),
        ("R14", ctypes.c_uint64), ("R15", ctypes.c_uint64),
        ("Rip", ctypes.c_uint64),
        ("FltSave", ctypes.c_byte * 512),
        ("VectorRegister", ctypes.c_byte * 416),
        ("VectorControl", ctypes.c_uint64),
        ("DebugControl", ctypes.c_uint64),
        ("LastBranchToRip", ctypes.c_uint64),
        ("LastBranchFromRip", ctypes.c_uint64),
        ("LastExceptionToRip", ctypes.c_uint64),
        ("LastExceptionFromRip", ctypes.c_uint64),
    ]

class MODULEINFO(ctypes.Structure):
    _fields_ = [("lpBaseOfDll", ctypes.c_void_p),
                ("SizeOfImage", ctypes.c_uint32),
                ("EntryPoint", ctypes.c_void_p)]

def find_module(hproc, name):
    hmods = (ctypes.c_void_p * 512)()
    needed = ctypes.c_uint32()
    if psapi.EnumProcessModulesEx(hproc, hmods, ctypes.sizeof(hmods),
                                  ctypes.byref(needed), 0x03):
        count = needed.value // ctypes.sizeof(ctypes.c_void_p)
        for i in range(count):
            mi = MODULEINFO()
            if psapi.GetModuleInformation(hproc, ctypes.c_void_p(hmods[i]),
                                          ctypes.byref(mi), ctypes.sizeof(mi)):
                buf = ctypes.create_unicode_buffer(512)
                psapi.GetModuleFileNameExW(hproc, ctypes.c_void_p(hmods[i]),
                                           buf, 512)
                if buf.value.lower().endswith(name):
                    return mi.lpBaseOfDll, mi.SizeOfImage
    return None, None

def sym_at(addr):
    class SYMBOL_INFO(ctypes.Structure):
        _fields_ = [
            ("SizeOfStruct", ctypes.c_uint32), ("TypeIndex", ctypes.c_uint32),
            ("Reserved", ctypes.c_uint64 * 2), ("Index", ctypes.c_uint32),
            ("Size", ctypes.c_uint32), ("ModBase", ctypes.c_uint64),
            ("Flags", ctypes.c_uint32), ("Value", ctypes.c_uint64),
            ("Address", ctypes.c_uint64), ("Register", ctypes.c_uint32),
            ("Scope", ctypes.c_uint32), ("Tag", ctypes.c_uint32),
            ("NameLen", ctypes.c_uint32), ("MaxNameLen", ctypes.c_uint32),
            ("Name", ctypes.c_char * 512),
        ]
    si = SYMBOL_INFO()
    si.SizeOfStruct = 88
    si.MaxNameLen = 512
    disp = ctypes.c_uint64()
    if dbghelp.SymFromAddr(hproc, ctypes.c_uint64(addr),
                           ctypes.byref(disp), ctypes.byref(si)):
        return si.Name.decode("utf-8", "replace"), disp.value
    return None, None

fbase, fsize = find_module(hproc, "flutter_windows.dll")
print(f"flutter_windows.dll base={hex(fbase)} size={hex(fsize)}")

ctx = CONTEXT()
offsets = Counter()
for i in range(N):
    kernel32.SuspendThread(hth)
    ctx.ContextFlags = CONTEXT_AMD64
    if kernel32.GetThreadContext(hth, ctypes.byref(ctx)):
        if fbase <= ctx.Rip < fbase + fsize:
            offsets[ctx.Rip - fbase] += 1
    kernel32.ResumeThread(hth)

print(f"\nflutter_windows.dll 内命中 {sum(offsets.values())}/{N}:")
for off, cnt in offsets.most_common(20):
    name, disp = sym_at(fbase + off)
    print(f"  +{hex(off)} x{cnt}  {name or '?'} +{disp}")
