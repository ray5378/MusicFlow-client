#ifndef MUSICFLOW_DESKTOP_LYRIC_H_
#define MUSICFLOW_DESKTOP_LYRIC_H_

#include <string>
#include <windows.h>

// Native desktop lyric overlay window.
// Always-on-top, borderless, translucent, draggable with the mouse,
// right-click menu to hide. Text is streamed from Flutter via method channel.
void DesktopLyricInit(HINSTANCE instance);
void DesktopLyricSetText(const std::wstring& text);
void DesktopLyricSetVisible(bool visible);
void DesktopLyricShutdown();

#endif  // MUSICFLOW_DESKTOP_LYRIC_H_
