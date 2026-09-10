"""主线程烧核诱捕器: 监控 CPU 速率,超阈值自动高频采样 RIP + 抓调用栈。

用法: python trap.py <pid> <tid> [监控秒数]
触发条件: 2 秒窗口内 CPU 速率 > 50% 单核
输出: tool/trap_report.txt
"""
import ctypes
import ctypes.wintypes as wt
import sys
import time

kernel32 = ctypes.WinDLL("kernel32")
psapi = ctypes.WinDLL("psapi")
dbghelp = ctypes.WinDLL("dbghelp")
user32 = ctypes.WinDLL("user32")

PROCESS_ALL = 0x1F0FFF
THREAD_ALL = 0x1FFFFF
CONTEXT_AMD64 = 0x00100B
IMAGE_FILE_MACHINE_AMD64 = 0x8664

pid = int(sys.argv[1])
tid = int(sys.argv[2])
watch_secs = int(sys.argv[3]) if len(sys.argv) > 3 else 600

hproc = kernel32.OpenProcess(PROCESS_ALL, False, pid)
hth = kernel32.OpenThread(THREAD_ALL, False, tid)

dbghelp.SymSetOptions(0x10 | 0x4)
dbghelp.SymInitializeW(hproc, None, True)

class ADDRESS64(ctypes.Structure):
    _fields_ = [("Offset", ctypes.c_uint64), ("Segment", ctypes.c_uint16)]

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

class STACKFRAME64(ctypes.Structure):
    _fields_ = [
        ("AddrPC", ADDRESS64), ("AddrReturn", ADDRESS64),
        ("AddrFrame", ADDRESS64), ("AddrStack", ADDRESS64),
        ("AddrBStore", ADDRESS64),
        ("FuncTableEntry", ctypes.c_void_p),
        ("NumberParameters", ctypes.c_uint32),
        ("Params", ctypes.c_uint64 * 4),
        ("Far", ctypes.c_bool), ("Virtual", ctypes.c_bool),
        ("Reserved", ctypes.c_uint64 * 3),
        ("KdHelp", ctypes.c_byte * 72),
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

def mod_of(mods, addr):
    for base, end, name in mods:
        if base <= addr < end:
            return name.replace("\\", "/").split("/")[-1], addr - base
    return None, None

def sym_name(hproc, addr):
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
        return si.Name.decode("utf-8", "replace")
    return None

def cpu_of():
    ft0 = wt.FILETIME(); ft1 = wt.FILETIME(); ft2 = wt.FILETIME(); ft3 = wt.FILETIME()
    kernel32.GetThreadTimes(hth, ctypes.byref(ft0), ctypes.byref(ft1),
                            ctypes.byref(ft2), ctypes.byref(ft3))
    return (ft2.dwHighDateTime << 32 | ft2.dwLowDateTime) / 1e7

def get_ctx():
    kernel32.SuspendThread(hth)
    ctx = CONTEXT()
    ctx.ContextFlags = CONTEXT_AMD64
    ok = kernel32.GetThreadContext(hth, ctypes.byref(ctx))
    kernel32.ResumeThread(hth)
    return ctx if ok else None

mods = module_list(hproc)
report = []
report.append(f"诱捕器启动 pid={pid} tid={tid} 监控{watch_secs}s")

start = time.time()
c1 = cpu_of()
while time.time() - start < watch_secs:
    time.sleep(2)
    c2 = cpu_of()
    rate = (c2 - c1) / 2
    c1 = c2
    if rate > 0.5:
        report.append(f"[{time.strftime('%H:%M:%S')}] 触发! 速率={rate*100:.0f}%")
        # 高频 RIP 采样 300 次(不睡眠,抓瞬时分布)
        hist = {}
        outside = []
        for i in range(300):
            ctx = get_ctx()
            if not ctx:
                break
            mod, off = mod_of(mods, ctx.Rip)
            key = mod or hex(ctx.Rip)
            hist[key] = hist.get(key, 0) + 1
            if mod and mod not in ("win32u.dll", "ntdll.dll", "user32.dll") and len(outside) < 3:
                outside.append(ctx)
        report.append("RIP 直方图: " + ", ".join(f"{k}:{v}" for k, v in sorted(hist.items(), key=lambda x: -x[1])))
        # 对落在业务代码里的样本抓完整栈
        for j, ctx in enumerate(outside):
            mod, off = mod_of(mods, ctx.Rip)
            kernel32.SuspendThread(hth)
            frame = STACKFRAME64()
            frame.AddrPC.Offset = ctx.Rip
            frame.AddrFrame.Offset = ctx.Rbp
            frame.AddrStack.Offset = ctx.Rsp
            frame.AddrPC.Segment = 0x33
            report.append(f"--- 栈样本{j+1} @ {mod}+{hex(off)} {sym_name(hproc, ctx.Rip) or ''}")
            depth = 0
            while depth < 14:
                m, o = mod_of(mods, frame.AddrPC.Offset)
                nm = sym_name(hproc, frame.AddrPC.Offset)
                label = (f"{m}+{hex(o)}" if m else hex(frame.AddrPC.Offset))
                if nm:
                    label += f" {nm}"
                report.append(f"  #{depth} {label}")
                depth += 1
                ok = dbghelp.StackWalk64(IMAGE_FILE_MACHINE_AMD64, hproc, hth,
                                         ctypes.byref(frame), ctypes.byref(ctx),
                                         None, dbghelp.SymFunctionTableAccess64,
                                         dbghelp.SymGetModuleBase64, None)
                if not ok or frame.AddrPC.Offset == 0:
                    break
            kernel32.ResumeThread(hth)
        break  # 抓一次就够,出循环写报告
    else:
        report.append(f"[{time.strftime('%H:%M:%S')}] {rate*100:.0f}%")

with open(r"tool\trap_report.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(report))
print("DONE, 报告已写入 tool/trap_report.txt")
