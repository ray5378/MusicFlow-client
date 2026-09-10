"""高频爆发捕捉: 无间隔 SuspendThread/GetContext 采样数千次,
统计 RIP 模块分布, 并对业务模块的 RIP 立即走栈。

用法: python burst_sampler.py <pid> <tid> [采样次数]
"""
import ctypes
import ctypes.wintypes as wt
import sys
import time

kernel32 = ctypes.WinDLL("kernel32")
psapi = ctypes.WinDLL("psapi")
dbghelp = ctypes.WinDLL("dbghelp")

PROCESS_ALL = 0x1F0FFF
THREAD_ALL = 0x1FFFFF
CONTEXT_AMD64 = 0x00100B
IMAGE_FILE_MACHINE_AMD64 = 0x8664

pid = int(sys.argv[1])
tid = int(sys.argv[2])
N = int(sys.argv[3]) if len(sys.argv) > 3 else 4000

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

def sym_name(addr):
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

mods = module_list(hproc)
IGNORE = {"win32u.dll", "ntdll.dll", "user32.dll", "win32.dll", "kernel32.dll"}

def mod_of(addr):
    for base, end, name in mods:
        if base <= addr < end:
            return name.replace("\\", "/").split("/")[-1], addr - base
    return None, None

hist = {}
stacks = []
ctx = CONTEXT()
for i in range(N):
    kernel32.SuspendThread(hth)
    ctx.ContextFlags = CONTEXT_AMD64
    if kernel32.GetThreadContext(hth, ctypes.byref(ctx)):
        mod, off = mod_of(ctx.Rip)
        key = mod or hex(ctx.Rip)
        hist[key] = hist.get(key, 0) + 1
        # 业务模块(非系统等待类) → 抓栈
        if mod and mod not in IGNORE and len(stacks) < 4:
            frame = STACKFRAME64()
            frame.AddrPC.Offset = ctx.Rip
            frame.AddrFrame.Offset = ctx.Rbp
            frame.AddrStack.Offset = ctx.Rsp
            frame.AddrPC.Segment = 0x33
            fr = []
            depth = 0
            while depth < 16:
                m, o = mod_of(frame.AddrPC.Offset)
                nm = sym_name(frame.AddrPC.Offset)
                fr.append((m, o, nm))
                depth += 1
                ok = dbghelp.StackWalk64(IMAGE_FILE_MACHINE_AMD64, hproc, hth,
                                         ctypes.byref(frame), ctypes.byref(ctx),
                                         None, dbghelp.SymFunctionTableAccess64,
                                         dbghelp.SymGetModuleBase64, None)
                if not ok or frame.AddrPC.Offset == 0:
                    break
            stacks.append(fr)
    kernel32.ResumeThread(hth)

print(f"采样 {N} 次 RIP 模块分布:")
for k, v in sorted(hist.items(), key=lambda x: -x[1]):
    print(f"  {k}: {v} ({v*100//N}%)")

for si, fr in enumerate(stacks):
    print(f"\n--- 业务栈样本 {si+1} ---")
    for m, o, nm in fr:
        label = f"{m}+{hex(o)}" if m else "?"
        if nm:
            label += f"  {nm}"
        print(f"  {label}")
