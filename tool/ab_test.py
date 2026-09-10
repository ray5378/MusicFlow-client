"""A/B 实验: 切换歌词窗可见性并测量 TID CPU 速率。

用法: python ab_test.py <pid> <tid> <hwnd_hex>
阶段: hide -> 测速 -> show -> 测速
"""
import ctypes
import ctypes.wintypes as wt
import sys
import time

kernel32 = ctypes.WinDLL("kernel32")
user32 = ctypes.WinDLL("user32")
THREAD_ALL = 0x1FFFFF

pid = int(sys.argv[1])
tid = int(sys.argv[2])
hwnd = int(sys.argv[3], 16)

hth = kernel32.OpenThread(THREAD_ALL, False, tid)

def cpu_of():
    ft0 = wt.FILETIME(); ft1 = wt.FILETIME(); ft2 = wt.FILETIME(); ft3 = wt.FILETIME()
    kernel32.GetThreadTimes(hth, ctypes.byref(ft0), ctypes.byref(ft1),
                            ctypes.byref(ft2), ctypes.byref(ft3))
    return (ft2.dwHighDateTime << 32 | ft2.dwLowDateTime) / 1e7

def rate(label, secs=8):
    c1 = cpu_of(); time.sleep(secs); c2 = cpu_of()
    print(f"{label}: {c2-c1:.2f}s/{secs}s => {(c2-c1)/secs*100:.0f}% 单核")

rate("基线(歌词窗可见)")
user32.ShowWindow(hwnd, 0)  # SW_HIDE
time.sleep(1)
rate("歌词窗隐藏后")
user32.ShowWindow(hwnd, 8)  # SW_SHOW
time.sleep(1)
rate("歌词窗恢复后")
