"""终极定位: 抓平台线程爆发栈 + 用 app.so ELF 符号表还原 Dart 函数名。

用法: python dart_symbolizer.py <pid> <tid> [采样次数]
"""
import ctypes
import ctypes.wintypes as wt
import struct
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
N = int(sys.argv[3]) if len(sys.argv) > 3 else 3000

APP_SO = r"C:\Users\ray5378\WorkBuddy\MusicFlow-client\build\windows\x64\runner\Profile\data\app.so"

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

class MEMORY_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", ctypes.c_uint32), ("__pad", ctypes.c_uint32),
        ("RegionSize", ctypes.c_size_t), ("State", ctypes.c_uint32),
        ("Protect", ctypes.c_uint32), ("Type", ctypes.c_uint32),
        ("__pad2", ctypes.c_uint32),
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

# ============ 1. 找 app.so 映射基址 ============
def find_appso_base(hproc, expected_size):
    addr = 0x10000
    mbi = MEMORY_BASIC_INFORMATION()
    while addr < 0x7FFFFFFEFFFF:
        if ctypes.windll.kernel32.VirtualQueryEx(hproc, ctypes.c_void_p(addr),
                ctypes.byref(mbi), ctypes.sizeof(mbi)) == 0:
            addr += 0x10000
            continue
        if mbi.State == 0x1000 and mbi.Type == 0x40000:  # MEM_MAPPED
            buf = ctypes.create_string_buffer(4)
            got = ctypes.c_size_t()
            if kernel32.ReadProcessMemory(hproc, ctypes.c_void_p(mbi.BaseAddress),
                                          buf, 4, ctypes.byref(got)) and \
               buf.raw[:4] == b"\x7fELF":
                if abs(mbi.RegionSize - expected_size) < expected_size * 0.35:
                    return mbi.BaseAddress
        addr = (mbi.BaseAddress or addr) + (mbi.RegionSize or 0x10000)
        addr = (addr + 0xFFFF) & ~0xFFFF
    return None

# ============ 2. 解析 app.so 符号表 ============
def parse_elf_symbols(path):
    with open(path, "rb") as f:
        data = f.read()
    # ELF64 header
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_type = struct.unpack_from("<I", data, off + 4)[0]
        sh_offset = struct.unpack_from("<Q", data, off + 24)[0]
        sh_size = struct.unpack_from("<Q", data, off + 32)[0]
        sh_link = struct.unpack_from("<I", data, off + 40)[0]
        sh_entsize = struct.unpack_from("<Q", data, off + 56)[0]
        sections.append((sh_type, sh_offset, sh_size, sh_link, sh_entsize))
    syms = []
    for stype, soff, ssize, slink, entsize in sections:
        if stype != 2:  # SHT_SYMTAB
            continue
        stroff = sections[slink][1]
        n = ssize // entsize
        for i in range(n):
            off = soff + i * entsize
            st_name = struct.unpack_from("<I", data, off)[0]
            st_value = struct.unpack_from("<Q", data, off + 8)[0]
            st_size = struct.unpack_from("<Q", data, off + 16)[0]
            end = stroff + st_name
            nend = data.index(b"\x00", end)
            name = data[end:nend].decode("utf-8", "replace")
            if name and st_value:
                syms.append((st_value, name))
    syms.sort()
    return syms

so_size = 16106376
base = find_appso_base(hproc, so_size)
print(f"app.so 映射基址: {hex(base) if base else '未找到'}")
syms = []
if base:
    syms = parse_elf_symbols(APP_SO)
    print(f"符号数: {len(syms)}")

import bisect
sym_starts = [s[0] for s in syms]

def dart_sym(addr_off):
    i = bisect.bisect_right(sym_starts, addr_off) - 1
    if i >= 0:
        return syms[i][1]
    return None

mods = module_list(hproc)
IGNORE = {"win32u.dll", "ntdll.dll", "user32.dll", "kernel32.dll"}

def mod_of(addr):
    for b, e, name in mods:
        if b <= addr < e:
            return name.replace("\\", "/").split("/")[-1], addr - b
    return None, None

def is_dart(addr):
    return base and base <= addr < base + so_size

# ============ 3. 高频采样 + Dart 栈扫描 ============
hist = {}
dart_chains = {}
ctx = CONTEXT()
for i in range(N):
    kernel32.SuspendThread(hth)
    ctx.ContextFlags = CONTEXT_AMD64
    if kernel32.GetThreadContext(hth, ctypes.byref(ctx)):
        mod, off = mod_of(ctx.Rip)
        key = mod or (f"dart:{dart_sym(ctx.Rip - base)}" if is_dart(ctx.Rip)
                      else hex(ctx.Rip))
        hist[key] = hist.get(key, 0) + 1
        if is_dart(ctx.Rip) and len(dart_chains) < 6:
            # 读 RSP 附近内存, 找 Dart 返回地址链
            chain = []
            rsp = ctx.Rsp
            qwords = (ctypes.c_uint64 * 400)()
            got = ctypes.c_size_t()
            if kernel32.ReadProcessMemory(hproc, ctypes.c_void_p(rsp),
                                          qwords, 3200, ctypes.byref(got)):
                for q in qwords:
                    if is_dart(q):
                        nm = dart_sym(q - base)
                        if nm and (not chain or chain[-1] != nm):
                            chain.append(nm)
                    if len(chain) >= 10:
                        break
            key2 = " <- ".join(chain[:8]) if chain else "(无Dart返回地址)"
            dart_chains[key2] = dart_chains.get(key2, 0) + 1
    kernel32.ResumeThread(hth)

print(f"\n采样 {N} 次 RIP 分布:")
for k, v in sorted(hist.items(), key=lambda x: -x[1])[:12]:
    print(f"  {k}: {v} ({v*100//N}%)")

print("\n=== Dart 返回地址链(采样命中 Dart 代码时) ===")
for k, v in sorted(dart_chains.items(), key=lambda x: -x[1])[:8]:
    print(f"  x{v}: {k}")
