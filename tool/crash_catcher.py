# -*- coding: utf-8 -*-
# 用户态调试器: 启动 MusicFlow.exe, 捕获 0xC0000409 (fail-fast/abort) 并落全量 dump
# 用法: python crash_catcher.py <exe路径>
import ctypes, ctypes.wintypes as wt, sys, os, time

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
dbh = ctypes.WinDLL("dbghelp")
psapi = ctypes.WinDLL("kernel32")  # K32* 就在 kernel32

DEBUG_ONLY_THIS_PROCESS = 0x00000002
INFINITE = 0xFFFFFFFF
DBG_CONTINUE = 0x00010002
DBG_EXCEPTION_NOT_HANDLED = 0x80010001

EV = {1:"EXCEPTION",2:"CREATE_THREAD",3:"CREATE_PROCESS",4:"EXIT_THREAD",
      5:"EXIT_PROCESS",6:"LOAD_DLL",7:"UNLOAD_DLL",8:"DEBUG_STRING",9:"RIP"}

class STARTUPINFOW(ctypes.Structure):
    _fields_ = [("cb",wt.DWORD),("lpReserved",wt.LPWSTR),("lpDesktop",wt.LPWSTR),
        ("lpTitle",wt.LPWSTR),("dwX",wt.DWORD),("dwY",wt.DWORD),("dwXSize",wt.DWORD),
        ("dwYSize",wt.DWORD),("dwXCountChars",wt.DWORD),("dwYCountChars",wt.DWORD),
        ("dwFillAttribute",wt.DWORD),("dwFlags",wt.DWORD),("wShowWindow",wt.WORD),
        ("cbReserved2",wt.WORD),("lpReserved2",ctypes.c_void_p),("hStdInput",wt.HANDLE),
        ("hStdOutput",wt.HANDLE),("hStdError",wt.HANDLE)]

class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess",wt.HANDLE),("hThread",wt.HANDLE),("dwProcessId",wt.DWORD),("dwThreadId",wt.DWORD)]

class DEBUG_EVENT(ctypes.Structure):
    _fields_ = [("dwDebugEventCode",wt.DWORD),("dwProcessId",wt.DWORD),
                ("dwThreadId",wt.DWORD),("u",ctypes.c_byte*164)]

class EXCEPTION_RECORD64(ctypes.Structure):
    _fields_ = [("ExceptionCode",wt.DWORD),("ExceptionFlags",wt.DWORD),
                ("ExceptionRecord",ctypes.c_uint64),("ExceptionAddress",ctypes.c_uint64),
                ("NumberParameters",wt.DWORD),("_pad",wt.DWORD),
                ("ExceptionInformation",ctypes.c_uint64*15)]

def modules_of(hproc):
    """返回 [(base, size, name)]"""
    need = wt.DWORD(0)
    psapi.K32EnumProcessModules(hproc, None, 0, ctypes.byref(need))
    n = need.value // ctypes.sizeof(wt.HANDLE)
    arr = (wt.HANDLE * n)()
    psapi.K32EnumProcessModules(hproc, arr, ctypes.sizeof(arr), ctypes.byref(need))
    out = []
    for h in arr:
        class MODULEINFO(ctypes.Structure):
            _fields_=[("lpBaseOfDll",ctypes.c_void_p),("SizeOfImage",wt.DWORD),("EntryPoint",ctypes.c_void_p)]
        mi = MODULEINFO()
        psapi.K32GetModuleInformation(hproc, h, ctypes.byref(mi), ctypes.sizeof(mi))
        buf = ctypes.create_unicode_buffer(512)
        psapi.K32GetModuleFileNameExW(hproc, h, buf, 512)
        out.append((mi.lpBaseOfDll or 0, mi.SizeOfImage, os.path.basename(buf.value)))
    return out

def find_mod(mods, addr):
    for base, size, name in mods:
        if base <= addr < base + size:
            return f"{name}+0x{addr-base:x}"
    return f"0x{addr:x} (unknown)"

def write_dump(hproc, pid, tid, path):
    hfile = k32.CreateFileW(path, 0x40000000, 0, None, 2, 0, None)  # GENERIC_WRITE, CREATE_ALWAYS
    if hfile == -1 or hfile == 0xFFFFFFFFFFFFFFFF:
        print(f"!! CreateFileW 失败 err={ctypes.get_last_error()}"); return False
    ok = dbh.MiniDumpWriteDump(wt.HANDLE(hproc), wt.DWORD(pid), wt.HANDLE(hfile),
                               wt.DWORD(0x2),  # MiniDumpWithFullMemory
                               None, None, None)
    k32.CloseHandle(wt.HANDLE(hfile))
    print(f"MiniDumpWriteDump -> {'OK' if ok else 'FAIL err='+str(ctypes.get_last_error())}")
    return bool(ok)

def main():
    exe = sys.argv[1]
    outdir = os.path.dirname(os.path.abspath(__file__))
    exe = os.path.abspath(exe)
    cmdline = ctypes.create_unicode_buffer(f'"{exe}"')
    si = STARTUPINFOW(); si.cb = ctypes.sizeof(si)
    pi = PROCESS_INFORMATION()
    if not k32.CreateProcessW(exe, cmdline, None, None, False,
                              DEBUG_ONLY_THIS_PROCESS, None, None,
                              ctypes.byref(si), ctypes.byref(pi)):
        print(f"CreateProcessW 失败 err={ctypes.get_last_error()}"); return
    print(f"[catcher] 已以调试器身份启动 PID={pi.dwProcessId} exe={exe}")
    print("[catcher] 等待崩溃... 现在请去复现卡顿/崩溃操作")
    hproc_dbg = None
    ev = DEBUG_EVENT()
    dumped = False
    while True:
        if not k32.WaitForDebugEvent(ctypes.byref(ev), INFINITE):
            break
        code, pid, tid = ev.dwDebugEventCode, ev.dwProcessId, ev.dwThreadId
        cont = DBG_CONTINUE
        if code == 3:  # CREATE_PROCESS
            hproc_dbg = ctypes.c_void_p.from_buffer_copy(ev.u).value
            print(f"[catcher] 进程创建, hProcess=0x{hproc_dbg:x}")
        elif code == 1:  # EXCEPTION
            rec = EXCEPTION_RECORD64.from_buffer_copy(ev.u)
            ec, addr = rec.ExceptionCode, rec.ExceptionAddress
            first = ctypes.c_uint32.from_buffer_copy(ev.u, ctypes.sizeof(EXCEPTION_RECORD64)).value
            mods = modules_of(wt.HANDLE(hproc_dbg)) if hproc_dbg else []
            loc = find_mod(mods, addr)
            print(f"[catcher] 异常 0x{ec:08X} firstChance={first} @ {loc}")
            if ec == 0xC0000409:
                if first == 0:  # second chance = 致命
                    path = os.path.join(outdir, f"crash_{time.strftime('%H%M%S')}.dmp")
                    print(f"[catcher] !!! 抓到致命 fail-fast, 落 dump: {path}")
                    write_dump(wt.HANDLE(hproc_dbg), pid, tid, path)
                    dumped = True
                    cont = DBG_EXCEPTION_NOT_HANDLED
                else:
                    cont = DBG_EXCEPTION_NOT_HANDLED
            else:
                cont = DBG_EXCEPTION_NOT_HANDLED
        elif code == 5:  # EXIT_PROCESS
            ec = ctypes.c_uint32.from_buffer_copy(ev.u).value
            print(f"[catcher] 进程退出 code=0x{ec:08X} dump={'已落' if dumped else '无'}")
            k32.ContinueDebugEvent(pid, tid, DBG_CONTINUE)
            break
        k32.ContinueDebugEvent(pid, tid, cont)
    if hproc_dbg:
        k32.CloseHandle(wt.HANDLE(hproc_dbg))
    print("[catcher] 结束")

if __name__ == "__main__":
    main()
