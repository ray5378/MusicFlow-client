"""采样目标进程最忙线程的 RIP 落点，定位单核吃满的根因模块。

用法: python thread_stack_sampler.py <pid> [采样次数] [间隔ms]
对 CPU 时间最高的 3 个线程各采样 N 次,输出 RIP 所在模块与最近符号的直方图。
"""
import ctypes
import ctypes.wintypes as wt
import sys
import time

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)
dbghelp = ctypes.WinDLL("dbghelp", use_last_error=True)

PROCESS_ALL = 0x1F0FFF
THREAD_ALL = 0x1FFFFF
CONTEXT_AMD64 = 0x00100B
IMAGE_FILE_MACHINE_AMD64 = 0x8664

class CONTEXT(ctypes.Structure):
    _fields_ = [
        ("P1Home", ctypes.c_uint64), ("P2Home", ctypes.c_uint64),
        ("P3Home", ctypes.c_uint64), ("P4Home", ctypes.c_uint64),
        ("P5Home", ctypes.c_uint64), ("P6Home", ctypes.c_uint64),
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
        # 浮点区(够用即可,后面用占位)
        ("FltSave", ctypes.c_byte * 512),
        ("VectorRegister", ctypes.c_byte * 416),
        ("VectorControl", ctypes.c_uint64),
        ("DebugControl", ctypes.c_uint64),
        ("LastBranchToRip", ctypes.c_uint64),
        ("LastBranchFromRip", ctypes.c_uint64),
        ("LastExceptionToRip", ctypes.c_uint64),
        ("LastExceptionFromRip", ctypes.c_uint64),
    ]

class THREADENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", ctypes.c_uint32),
        ("cntUsage", ctypes.c_uint32),
        ("th32ThreadID", ctypes.c_uint32),
        ("dwOwnerProcessID", ctypes.c_uint32),
        ("tpBasePri", ctypes.c_long),
        ("tpDeltaPri", ctypes.c_long),
        ("dwFlags", ctypes.c_uint32),
    ]

class SYMBOL_INFO(ctypes.Structure):
    _fields_ = [
        ("SizeOfStruct", ctypes.c_uint32),
        ("TypeIndex", ctypes.c_uint32),
        ("Reserved", ctypes.c_uint64 * 2),
        ("Index", ctypes.c_uint32),
        ("Size", ctypes.c_uint32),
        ("ModBase", ctypes.c_uint64),
        ("Flags", ctypes.c_uint32),
        ("Value", ctypes.c_uint64),
        ("Address", ctypes.c_uint64),
        ("Register", ctypes.c_uint32),
        ("Scope", ctypes.c_uint32),
        ("Tag", ctypes.c_uint32),
        ("NameLen", ctypes.c_uint32),
        ("MaxNameLen", ctypes.c_uint32),
        ("Name", ctypes.c_char * 256),
    ]

class MODULEINFO(ctypes.Structure):
    _fields_ = [("lpBaseOfDll", ctypes.c_void_p),
                ("SizeOfImage", ctypes.c_uint32),
                ("EntryPoint", ctypes.c_void_p)]

def module_list(hproc):
    hmods = (ctypes.c_void_p * 512)()
    needed = ctypes.c_uint32()
    mods = []
    if psapi.EnumProcessModulesEx(hproc, hmods, ctypes.sizeof(hmods),
                                  ctypes.byref(needed), 0x03):
        count = min(needed.value // ctypes.sizeof(ctypes.c_void_p), 512)
        for i in range(count):
            mi = MODULEINFO()
            if psapi.GetModuleInformation(hproc, ctypes.c_void_p(hmods[i]),
                                          ctypes.byref(mi), ctypes.sizeof(mi)):
                name = ctypes.create_unicode_buffer(512)
                psapi.GetModuleFileNameExW(hproc, ctypes.c_void_p(hmods[i]),
                                           name, 512)
                base = mi.lpBaseOfDll or 0
                mods.append((base, base + mi.SizeOfImage, name.value))
    mods.sort()
    return mods

def addr_to_module(mods, addr):
    for base, end, name in mods:
        if base <= addr < end:
            return name.replace("\\", "/").split("/")[-1], addr - base
    return None, None

def main():
    pid = int(sys.argv[1])
    samples = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    interval_ms = int(sys.argv[3]) if len(sys.argv) > 3 else 50

    hproc = kernel32.OpenProcess(PROCESS_ALL, False, pid)
    if not hproc:
        print(f"OpenProcess({pid}) 失败 err={ctypes.get_last_error()}")
        return

    # 拿线程 CPU 时间排名
    snap = kernel32.CreateToolhelp32Snapshot(0x4, 0)  # TH32CS_SNAPTHREAD
    te = THREADENTRY32()
    te.dwSize = ctypes.sizeof(te)
    threads = []
    if kernel32.Thread32First(snap, ctypes.byref(te)):
        while True:
            if te.dwOwnerProcessID == pid:
                h = kernel32.OpenThread(THREAD_ALL, False, te.th32ThreadID)
                if h:
                    ft0 = wt.FILETIME(); ft1 = wt.FILETIME()
                    if kernel32.GetThreadTimes(h, ctypes.byref(ft0),
                                               ctypes.byref(ft0),
                                               ctypes.byref(ft1),
                                               ctypes.byref(ft1)):
                        cpu = (ft1.dwHighDateTime << 32 | ft1.dwLowDateTime)
                        threads.append((cpu, te.th32ThreadID))
                    kernel32.CloseHandle(h)
            if not kernel32.Thread32Next(snap, ctypes.byref(te)):
                break
    kernel32.CloseHandle(snap)
    threads.sort(reverse=True)
    top = threads[:3]
    print(f"Top 线程(100ns 单位): {[(t//10_000_000, tid) for t, tid in top]}")

    mods = module_list(hproc)
    hist = {}
    for _, tid in top:
        hth = kernel32.OpenThread(THREAD_ALL, False, tid)
        if not hth:
            continue
        for i in range(samples):
            kernel32.SuspendThread(hth)
            ctx = CONTEXT()
            ctx.ContextFlags = CONTEXT_AMD64
            ok = False
            if kernel32.GetThreadContext(hth, ctypes.byref(ctx)):
                rip = ctx.Rip
                mod, off = addr_to_module(mods, rip)
                key = (tid, mod or f"未知模块({hex(rip)})")
                hist[key] = hist.get(key, 0) + 1
                ok = True
            kernel32.ResumeThread(hth)
            if not ok:
                break
            time.sleep(interval_ms / 1000.0)
        kernel32.CloseHandle(hth)

    print("\n=== RIP 落点直方图(线程ID -> 模块: 次数) ===")
    for (tid, mod), n in sorted(hist.items(), key=lambda x: -x[1]):
        print(f"  TID {tid}: {mod}: {n}/{samples}")
    kernel32.CloseHandle(hproc)

if __name__ == "__main__":
    main()
