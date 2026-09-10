import ctypes, ctypes.wintypes as wt, sys
user32 = ctypes.WinDLL("user32")
for hwnd_str in sys.argv[1:]:
    hwnd = int(hwnd_str, 16)
    tid = user32.GetWindowThreadProcessId(hwnd, None)
    print(f"hwnd={hwnd_str} -> owner TID={tid}")
