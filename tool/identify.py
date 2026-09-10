import ctypes, ctypes.wintypes as wt, sys
user32 = ctypes.WinDLL("user32")
for h in sys.argv[1:]:
    hwnd = int(h, 16)
    cls = ctypes.create_unicode_buffer(256); title = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, cls, 256); user32.GetWindowTextW(hwnd, title, 256)
    pid = wt.DWORD(); tid = user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    print(f"hwnd={h} class={cls.value!r} title={title.value!r} tid={tid} pid={pid.value}")
