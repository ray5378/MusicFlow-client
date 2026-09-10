"""加载 msg_hook.dll, 安装 WH_GETMESSAGE 钩子到目标线程, 采样 N 秒后读直方图。

用法: python msg_hist.py <tid> [采样秒数]
共享数据段(.mfh RWS)在 python 与目标进程的 DLL 实例间共享,直接读本进程副本。
"""
import ctypes
from ctypes import c_uint64, c_uint32, POINTER
import sys
import time

tid = int(sys.argv[1])
secs = int(sys.argv[2]) if len(sys.argv) > 2 else 10

dll = ctypes.WinDLL(r"C:\Users\ray5378\WorkBuddy\MusicFlow-client\tool\msg_hook.dll")
dll.GetCounts.restype = POINTER(c_uint64)
dll.GetTotal.restype = POINTER(c_uint64)
dll.GetHwndCounts.restype = POINTER(c_uint32)
dll.GetHwndSlots.restype = POINTER(ctypes.c_void_p)

dll.InstallHook.restype = ctypes.c_void_p
hook = dll.InstallHook(ctypes.c_uint32(tid))
if not hook:
    err = ctypes.GetLastError()
    print(f"钩子安装失败! err={err}")
    sys.exit(1)
print(f"钩子已安装到 TID {tid} (hook={hook:#x}), 采样 {secs} 秒... 请现在复现操作!")

time.sleep(secs)
dll.UninstallHook()

counts_ptr = dll.GetCounts()
total_ptr = dll.GetTotal()
hwnd_counts = dll.GetHwndCounts()
hwnd_slots = dll.GetHwndSlots()

names = {0x0000: "WM_NULL", 0x0003: "WM_MOVE", 0x0005: "WM_SIZE",
    0x000F: "WM_PAINT", 0x0014: "WM_ERASEBKGND", 0x0018: "WM_SHOWWINDOW",
    0x0021: "WM_MOUSEACTIVATE", 0x0024: "WM_GETMINMAXINFO",
    0x0112: "WM_SYSCOMMAND", 0x0113: "WM_TIMER", 0x0114: "WM_HSCROLL",
    0x0115: "WM_VSCROLL", 0x0200: "WM_MOUSEMOVE",
    0x0201: "WM_LBUTTONDOWN", 0x0202: "WM_LBUTTONUP",
    0x0203: "WM_LBUTTONDBLCLK", 0x0204: "WM_RBUTTONDOWN",
    0x0205: "WM_RBUTTONUP", 0x0206: "WM_RBUTTONDBLCLK",
    0x0207: "WM_MBUTTONDOWN", 0x0208: "WM_MBUTTONUP",
    0x020A: "WM_MOUSEWHEEL", 0x020B: "WM_XBUTTONDOWN",
    0x020C: "WM_XBUTTONUP", 0x0281: "WM_IME_SETCONTEXT",
    0x0282: "WM_IME_NOTIFY", 0x0286: "WM_IME_COMPOSITION",
}

total = total_ptr[0]
print(f"\n总消息数: {total} / {secs}s => {total/secs:.0f} 条/秒")
rows = [(counts_ptr[i], i) for i in range(256) if counts_ptr[i]]
rows.sort(reverse=True)
for cnt, i in rows[:20]:
    if i < 0x400:
        msg = i
    elif 0x100 <= i < 0x200:
        msg = 0x8000 + (i - 0x100)   # WM_APP 区
    elif 0x200 <= i < 0x300:
        msg = 0xC000 + (i - 0x200)   # 注册消息区
    else:
        msg = i - 0x300              # 其他高位消息(低位)
    name = names.get(msg, f"0x{msg:04X}")
    print(f"  {cnt:>10}  {name}")
print("\nHwnd 计数(采样期内出现消息的窗口):")
for i in range(16):
    if hwnd_slots[i]:
        print(f"  hwnd={hwnd_slots[i]:#x}: {hwnd_counts[i]}")
