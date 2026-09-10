"""抓取目标线程完整调用栈(64位, StackWalk64 + 符号解析)。

用法: python thread_full_stack.py <pid> <tid> [次数] [间隔ms]
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
        ("AddrPC", ADDRESS64.__class__) if False else ("AddrPC", ctypes.c_uint64 * 0),
    ]

# ADDRESS64
class ADDRESS64(ctypes.Structure):
    _fields_ = [("Offset", ctypes.c_uint64), ("Segment", ctypes.c_uint16)]

class STACKFRAME64(ctypes.Structure):
    _fields_ = [
        ("AddrPC", ADDRESS64),
        ("AddrReturn", ADDRESS64),
        ("AddrFrame", ADDRESS64),
        ("AddrStack", ADDRESS64),
        ("AddrBStore", ADDRESS64),
        ("FuncTableEntry", ctypes.c_void_p),
        ("NumberParameters", ctypes.c_uint32),
        ("Params", ctypes.c_uint64 * 4),
        ("Far", ctypes.c_bool),
        ("Virtual", ctypes.c_bool),
        ("Reserved", ctypes.c_uint64 * 3),
        ("KdHelp", ctypes.c_byte * 72),
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
        ("Name", ctypes.c_char * 512),
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

def sym_name(hproc, addr):
    si = SYMBOL_INFO()
    si.SizeOfStruct = 88
    si.MaxNameLen = 512
    disp = ctypes.c_uint64()
    if dbghelp.SymFromAddr(hproc, ctypes.c_uint64(addr),
                           ctypes.byref(disp), ctypes.byref(si)):
        try:
            return si.Name.decode("utf-8", "replace")
        except Exception:
            return "?"
    return None

def main():
    pid = int(sys.argv[1])
    tid = int(sys.argv[2])
    samples = int(sys.argv[3]) if len(sys.argv) > 3 else 10
    interval_ms = int(sys.argv[4]) if len(sys.argv) > 4 else 100

    hproc = kernel32.OpenProcess(PROCESS_ALL, False, pid)
    hth = kernel32.OpenThread(THREAD_ALL, False, tid)
    if not hproc or not hth:
        print(f"打开失败 err={ctypes.get_last_error()}")
        return

    dbghelp.SymSetOptions(0x00000010 | 0x00000004)  # LOAD_LINES | UNDNAME
    dbghelp.SymInitializeW(hproc, None, True)

    mods = module_list(hproc)

    def mod_of(addr):
        for base, end, name in mods:
            if base <= addr < end:
                return name.replace("\\", "/").split("/")[-1], addr - base
        return None, None

    for s in range(samples):
        kernel32.SuspendThread(hth)
        ctx = CONTEXT()
        ctx.ContextFlags = CONTEXT_AMD64
        if kernel32.GetThreadContext(hth, ctypes.byref(ctx)):
            frame = STACKFRAME64()
            frame.AddrPC.Offset = ctx.Rip
            frame.AddrFrame.Offset = ctx.Rbp
            frame.AddrStack.Offset = ctx.Rsp
            frame.AddrPC.Segment = 0x33
            print(f"--- 采样 #{s+1} ---")
            depth = 0
            while depth < 14:
                mod, off = mod_of(frame.AddrPC.Offset)
                label = f"{mod}+{hex(off)}" if mod else hex(frame.AddrPC.Offset)
                name = sym_name(hproc, frame.AddrPC.Offset)
                if name:
                    label += f"  {name}"
                print(f"  #{depth} {label}")
                depth += 1
                ok = dbghelp.StackWalk64(
                    IMAGE_FILE_MACHINE_AMD64, hproc, hth,
                    ctypes.byref(frame), ctypes.byref(ctx),
                    None, dbghelp.SymFunctionTableAccess64,
                    dbghelp.SymGetModuleBase64, None)
                if not ok or frame.AddrPC.Offset == 0:
                    break
        kernel32.ResumeThread(hth)
        time.sleep(interval_ms / 1000.0)
    kernel32.CloseHandle(hth)
    kernel32.CloseHandle(hproc)

if __name__ == "__main__":
    main()
