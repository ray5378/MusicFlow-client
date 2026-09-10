"""枚举指定进程的全部可见窗口: hwnd / class / title / owning thread。"""
import ctypes
import ctypes.wintypes as wt
import sys

user32 = ctypes.WinDLL("user32")
pid_target = int(sys.argv[1])

results = []
@ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)
def cb(hwnd, lparam):
    pid = wt.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    if pid.value == pid_target:
        cls = ctypes.create_unicode_buffer(256)
        title = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, cls, 256)
        user32.GetWindowTextW(hwnd, title, 256)
        visible = user32.IsWindowVisible(hwnd)
        results.append((hwnd, cls.value, title.value, bool(visible)))
    return True

user32.EnumWindows(cb, 0)
# 附加枚举所属线程的所有窗口(EnumThreadWindows)
for hwnd, cls, title, vis in list(results):
    pass

print(f"进程 {pid_target} 的顶层窗口:")
for hwnd, cls, title, vis in results:
    print(f"  hwnd={hwnd:#x} class={cls!r} title={title!r} visible={vis}")
