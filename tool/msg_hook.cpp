// msg_hook.cpp - WH_GETMESSAGE 钩子 DLL: 把目标线程消息队列里流经的
// 消息 ID / hwnd 按 256 桶直方图写入共享内存,供外部进程读取。
// 由外部进程 LoadLibrary 后调用 InstallHook(tid) 安装,Windows 会把本
// DLL 自动映射进目标线程所在进程。
#include <windows.h>

#define MAP_NAME L"MF_MSG_HIST_11384"
#define BUCKETS 256

#pragma data_seg(".mfh")
volatile ULONG64 g_counts[BUCKETS] = {0};
volatile ULONG64 g_total = 0;
volatile ULONG   g_lastMsg = 0;
volatile HWND    g_lastHwnd = 0;
volatile ULONG   g_hwndCounts[16] = {0};  // 最近 16 个不同 hwnd 简化计数
HWND             g_hwndSlots[16] = {0};
#pragma data_seg()
#pragma comment(linker, "/SECTION:.mfh,RWS")

HHOOK g_hook = nullptr;

static void Count(HWND hwnd, UINT msg) {
  InterlockedIncrement64((volatile LONG64*)&g_total);
  g_lastMsg = msg;
  g_lastHwnd = hwnd;
  ULONG bucket = (msg < 0x400) ? msg
                 : (msg >= 0x8000 && msg < 0x8100) ? 0x100 + (msg - 0x8000)
                 : (msg >= 0xC000 && msg < 0xC100) ? 0x200 + (msg - 0xC000)
                 : 0x300 + (msg & 0xFF);
  InterlockedIncrement64((volatile LONG64*)&g_counts[bucket & (BUCKETS - 1)]);
  // hwnd 计数: 16 槽线性探测
  for (int i = 0; i < 16; ++i) {
    HWND expect = g_hwndSlots[i];
    if (expect == hwnd) { InterlockedIncrement(&g_hwndCounts[i]); return; }
    if (expect == nullptr) {
      HWND prev = (HWND)InterlockedCompareExchangePointer(
          (PVOID*)&g_hwndSlots[i], (PVOID)hwnd, nullptr);
      InterlockedIncrement(&g_hwndCounts[i]);
      return;
    }
  }
}

LRESULT CALLBACK GetMsgProc(int code, WPARAM wParam, LPARAM lParam) {
  if (code >= 0 && lParam) {
    MSG* m = (MSG*)lParam;
    Count(m->hwnd, m->message);
  }
  return CallNextHookEx(g_hook, code, wParam, lParam);
}

extern "C" __declspec(dllexport)
HHOOK InstallHook(DWORD tid) {
  // 跨进程线程钩子: hMod 必须是本 DLL 的真实模块句柄(系统据此注入)
  HMODULE hMod;
  GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                     (LPCWSTR)&InstallHook, &hMod);
  g_hook = SetWindowsHookExW(WH_GETMESSAGE, GetMsgProc, hMod, tid);
  return g_hook;
}

extern "C" __declspec(dllexport)
void UninstallHook() {
  if (g_hook) { UnhookWindowsHookEx(g_hook); g_hook = nullptr; }
}

extern "C" __declspec(dllexport)
ULONG64* GetCounts() { return (ULONG64*)g_counts; }

extern "C" __declspec(dllexport)
ULONG64* GetTotal() { return (ULONG64*)&g_total; }

extern "C" __declspec(dllexport)
ULONG* GetHwndCounts() { return (ULONG*)g_hwndCounts; }

extern "C" __declspec(dllexport)
HWND* GetHwndSlots() { return (HWND*)g_hwndSlots; }

BOOL APIENTRY DllMain(HMODULE, DWORD, LPVOID) { return TRUE; }
