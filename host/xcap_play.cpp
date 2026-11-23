// One click: TV to 3840x2160 120 Hz with HDR on, then Veyra full screen on the XCAP card.
// While Veyra runs, a display change (another monitor switching inputs, a TV re-plug) that drops the TV out of that
// mode is put right again. Everything is put back when Veyra closes.   xcap_play [pattern] [fps=120] [quality=2] [hz=120] [tv=NAME] [keep]     hz: highest refresh rate to use, tv: part of the monitor name, keep: leave the display mode alone
#include <windows.h>
#include "xcap_edid.h"
#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#pragma comment(lib, "user32.lib")

static FILE* g_log;
static void say(const char* f, ...) { va_list a; va_start(a, f); vfprintf(g_log, f, a); va_end(a); fflush(g_log); }

struct Path { DISPLAYCONFIG_PATH_INFO p{}; std::wstring gdi; bool ok = false; };
// The TV is known by its monitor device path (the same monitor on the same connector) and, when it comes back
// somewhere else, by its EDID name. Never by \\.\DISPLAYn: that name moves to another monitor when the
// topology changes. With the TV off or on another input there is no path, and nothing else is touched.
static std::wstring g_tvDev, g_tvName;
static Path tvPath() {
    Path named;
    UINT32 np = 0, nm = 0;
    if (g_tvDev.empty() && g_tvName.empty()) return named;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm)) return named;
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(np);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(nm);
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths.data(), &nm, modes.data(), nullptr)) return Path{};
    for (UINT32 i = 0; i < np; ++i) {
        DISPLAYCONFIG_TARGET_DEVICE_NAME t{};
        t.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(t), paths[i].targetInfo.adapterId, paths[i].targetInfo.id};
        if (DisplayConfigGetDeviceInfo(&t.header)) continue;
        const bool same = !g_tvDev.empty() && _wcsicmp(g_tvDev.c_str(), t.monitorDevicePath) == 0;
        if (!same && (named.ok || g_tvName.empty() || g_tvName != t.monitorFriendlyDeviceName)) continue;
        DISPLAYCONFIG_SOURCE_DEVICE_NAME s{};
        s.header = {DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, sizeof(s), paths[i].sourceInfo.adapterId, paths[i].sourceInfo.id};
        if (DisplayConfigGetDeviceInfo(&s.header)) continue;
        Path p; p.p = paths[i]; p.gdi = s.viewGdiDeviceName; p.ok = true;
        if (same) return p;
        named = p;
    }
    return named;
}
static int hdrState(const Path& d) {                               // -1 unknown, 0 off, 1 on, 2 not supported
    DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO c{};
    c.header = {DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO, sizeof(c), d.p.targetInfo.adapterId, d.p.targetInfo.id};
    if (DisplayConfigGetDeviceInfo(&c.header)) return -1;
    return !c.advancedColorSupported ? 2 : c.advancedColorEnabled ? 1 : 0;
}
// At least 10 bits per channel without chroma subsampling: what HDR needs. Unknown counts as good.
static bool fullDepth(const Path& d, bool log = true) {
    DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO c{};
    c.header = {DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO, sizeof(c), d.p.targetInfo.adapterId, d.p.targetInfo.id};
    if (DisplayConfigGetDeviceInfo(&c.header)) return true;
    if (log) say("  link: %u bit, encoding %d (0 RGB, 1 YCbCr 4:4:4, 2 4:2:2, 3 4:2:0)\n", c.bitsPerColorChannel, int(c.colorEncoding));
    return (c.bitsPerColorChannel == 0 || c.bitsPerColorChannel >= 10) && (c.colorEncoding == DISPLAYCONFIG_COLOR_ENCODING_RGB || c.colorEncoding == DISPLAYCONFIG_COLOR_ENCODING_YCBCR444);
}
static bool setMode(const Path& d, DWORD hz, bool again = false) {      // again: set it although it is the current mode (the link is negotiated anew)
    DEVMODEW m{}; m.dmSize = sizeof(m);
    m.dmPelsWidth = 3840; m.dmPelsHeight = 2160; m.dmDisplayFrequency = hz; m.dmBitsPerPel = 32;
    m.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_BITSPERPEL;
    return ChangeDisplaySettingsExW(d.gdi.c_str(), &m, nullptr, CDS_FULLSCREEN | (again ? CDS_RESET : 0), nullptr) == DISP_CHANGE_SUCCESSFUL;   // temporary
}
static bool setHdr(const Path& d, bool on) {
    DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE c{};
    c.header = {DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE, sizeof(c), d.p.targetInfo.adapterId, d.p.targetInfo.id};
    c.enableAdvancedColor = on;
    return DisplayConfigSetDeviceInfo(&c.header) == ERROR_SUCCESS;
}

// "HDR is on only because xcap_play turned it on": a file, so that a run that could not turn it off again
// (TV gone at the end, process killed) is made up for by the next one.
static std::wstring g_mark;
static bool marked() { return GetFileAttributesW(g_mark.c_str()) != INVALID_FILE_ATTRIBUTES; }
static void mark(bool on) {
    if (!on) { DeleteFileW(g_mark.c_str()); return; }
    const HANDLE h = CreateFileW(g_mark.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
}

// Closing: Ctrl+C / console close, WM_CLOSE (taskkill without /f), log-off and shutdown end the wait in
// wmain, which then puts the display back. The one who asked waits for that, as long as Windows allows.
static HANDLE g_quit, g_done;
static void quitAndWait() { SetEvent(g_quit); WaitForSingleObject(g_done, 4500); }
static BOOL WINAPI onConsole(DWORD) { quitAndWait(); return TRUE; }
static LRESULT CALLBACK onWindow(HWND w, UINT m, WPARAM wp, LPARAM lp) {
    if (m == WM_QUERYENDSESSION) return TRUE;
    if (m == WM_CLOSE || (m == WM_ENDSESSION && wp)) { quitAndWait(); return 0; }
    return DefWindowProcW(w, m, wp, lp);
}
static DWORD WINAPI windowThread(void*) {                           // a hidden top-level window: the only way a windowless program hears of these
    WNDCLASSW c{};
    c.lpfnWndProc = onWindow; c.hInstance = GetModuleHandleW(nullptr); c.lpszClassName = L"xcap_play";
    if (!RegisterClassW(&c) || !CreateWindowExW(0, c.lpszClassName, L"xcap_play", WS_OVERLAPPED, 0, 0, 0, 0, nullptr, nullptr, c.hInstance, nullptr)) return 1;
    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) DispatchMessageW(&msg);
    return 0;
}

int wmain(int argc, wchar_t** argv) {
    wchar_t self[MAX_PATH]{};
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    std::wstring dir(self);
    dir.resize(dir.find_last_of(L'\\'));
    g_log = _wfopen((dir + L"\\xcap_play.log").c_str(), L"w");
    if (!g_log) g_log = stdout;
    HANDLE once = CreateMutexW(nullptr, FALSE, L"Local\\xcap_play");
    if (GetLastError() == ERROR_ALREADY_EXISTS) { say("already running\n"); return 0; }
    (void)once;
    g_mark = dir + L"\\xcap_play.hdr";
    g_quit = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    SetConsoleCtrlHandler(onConsole, TRUE);
    if (const HANDLE t = CreateThread(nullptr, 0, windowThread, nullptr, 0, nullptr)) CloseHandle(t);
    std::wstring mode = L"hdmi", fps = L"120", quality = L"2";
    bool keep = false;
    std::wstring tvName;
    DWORD maxHz = 120;             // 165 Hz proved unstable on the G5
    for (int i = 1; i < argc; ++i) {
        const std::wstring a = argv[i];
        if (a == L"pattern") mode = a;
        else if (a == L"keep") keep = true;
        else if (a.rfind(L"fps=", 0) == 0) fps = a.substr(4);
        else if (a.rfind(L"hz=", 0) == 0) maxHz = DWORD(_wtoi(a.c_str() + 3));
        else if (a.rfind(L"tv=", 0) == 0) tvName = a.substr(3);
        else if (a.rfind(L"quality=", 0) == 0) quality = a.substr(8);
    }
    SetProcessDPIAware();
    const auto monitors = xcap::activeMonitors();
    const xcap::TvEdid* tv = xcap::chooseTv(monitors, tvName);
    if (tv) { g_tvDev = tv->path; g_tvName = tv->name; say("TV: %ls on %ls\n", tv->name.c_str(), tv->gdi.c_str()); }
    Path d = tvPath();
    DEVMODEW before{}; before.dmSize = sizeof(before);
    bool modeChanged = false;
    bool ownHdr = false;                                           // HDR is on because of this program (this run or an earlier one): off again at the end
    bool hdrWasOn = false;                                         // HDR was the user's own setting: stays on
    const auto hdrOn = [&](const Path& p) {                        // wherever HDR is turned on here, it is recorded for the end
        const bool ok = setHdr(p, true);
        if (ok && !hdrWasOn && !ownHdr) { ownHdr = true; mark(true); }
        return ok;
    };
    if (!d.ok) say("no desktop on this session\n");
    else if (!keep) {
        if (hdrState(d) == 1) { if (marked()) { ownHdr = true; say("HDR was left on by an earlier run: it goes off at the end\n"); } else hdrWasOn = true; }
        else if (hdrState(d) == 0) mark(false);
        EnumDisplaySettingsExW(d.gdi.c_str(), ENUM_CURRENT_SETTINGS, &before, 0);
        std::vector<DWORD> rates;
        DEVMODEW m{};
        m.dmSize = sizeof(m);
        for (DWORD i = 0; EnumDisplaySettingsExW(d.gdi.c_str(), i, &m, 0); ++i)
            if (m.dmPelsWidth == 3840 && m.dmPelsHeight == 2160 && m.dmBitsPerPel == 32 && m.dmDisplayFrequency <= maxHz && std::find(rates.begin(), rates.end(), m.dmDisplayFrequency) == rates.end()) rates.push_back(m.dmDisplayFrequency);
        std::sort(rates.rbegin(), rates.rend());
        say("%ls now %lux%lu %lu Hz, HDR %d, 4K rates:", d.gdi.c_str(), before.dmPelsWidth, before.dmPelsHeight, before.dmDisplayFrequency, hdrState(d));
        for (DWORD r : rates) say(" %lu", r);
        say("\n");
        if (d.ok && hdrState(d) == 0) { say("HDR on -> %d\n", int(hdrOn(d))); Sleep(1500); d = tvPath(); }
        // the highest rate that still carries 10-bit RGB / 4:4:4; below 119 Hz there is nothing to gain by looking further
        for (size_t i = 0; i < rates.size() && (rates[i] >= 119 || i == 0); ++i) {
            DEVMODEW now{}; now.dmSize = sizeof(now);
            EnumDisplaySettingsExW(d.gdi.c_str(), ENUM_CURRENT_SETTINGS, &now, 0);
            if (now.dmPelsWidth != 3840 || now.dmPelsHeight != 2160 || now.dmDisplayFrequency != rates[i]) {
                now.dmPelsWidth = 3840; now.dmPelsHeight = 2160; now.dmDisplayFrequency = rates[i]; now.dmBitsPerPel = 32;
                now.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_BITSPERPEL;
                const LONG r = ChangeDisplaySettingsExW(d.gdi.c_str(), &now, nullptr, CDS_FULLSCREEN, nullptr);      // temporary, not saved
                say("%lu Hz -> %ld\n", rates[i], r);
                if (r != DISP_CHANGE_SUCCESSFUL) continue;
                modeChanged = true;
                Sleep(2500);
                d = tvPath();
                if (!d.ok) break;
                if (hdrState(d) == 0) { hdrOn(d); Sleep(1500); d = tvPath(); if (!d.ok) break; }
            }
            if (fullDepth(d)) break;
        }
    }
    DWORD wantHz = 0;                                              // the mode to keep while Veyra runs
    bool wantHdr = false, wantDepth = false;
    if (d.ok && !keep) {
        DEVMODEW now{}; now.dmSize = sizeof(now);
        EnumDisplaySettingsExW(d.gdi.c_str(), ENUM_CURRENT_SETTINGS, &now, 0);
        if (now.dmPelsWidth == 3840 && now.dmPelsHeight == 2160) wantHz = now.dmDisplayFrequency;
        wantHdr = hdrState(d) == 1;
        wantDepth = fullDepth(d, false);
        say("keeping %lu Hz, HDR %d, full depth %d while Veyra runs\n", wantHz, int(wantHdr), int(wantDepth));
    }
    SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
    std::wstring cmd = L"\"" + dir + L"\\veyra_qml_ui.exe\" --data-dir \"" + dir + L"\\data\" --xcap " + mode + L"," + fps + L"," + quality + L" --fullscreen";
    if (tv) { cmd += L" --screen \"" + tv->name + L"\""; SetEnvironmentVariableW(L"VEYRA_XCAP_TV", tv->name.c_str()); }
    STARTUPINFOW si{}; si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    int rc = 0;
    if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, ABOVE_NORMAL_PRIORITY_CLASS, nullptr, dir.c_str(), &si, &pi)) { say("Veyra did not start, error %lu\n", GetLastError()); rc = 1; }
    else {
        say("Veyra started\n");
        unsigned off = 0;                                          // polls in a row with the TV out of its mode
        unsigned fixes = 0;                                        // restores in a row that did not hold
        ULONGLONG lastFix = 0;
        const HANDLE either[2] = {pi.hProcess, g_quit};
        DWORD woke;
        while ((woke = WaitForMultipleObjects(g_quit ? 2 : 1, either, FALSE, 1000)) == WAIT_TIMEOUT) {
            if (!wantHz) continue;
            Path n = tvPath();                                     // the TV itself, wherever it is now; absent: nothing to do, nothing else to touch
            if (!n.ok) { off = 0; continue; }
            DEVMODEW cur{}; cur.dmSize = sizeof(cur);
            if (!EnumDisplaySettingsExW(n.gdi.c_str(), ENUM_CURRENT_SETTINGS, &cur, 0)) continue;
            const int hdr = hdrState(n);
            const bool modeBad = cur.dmPelsWidth != 3840 || cur.dmPelsHeight != 2160 || cur.dmDisplayFrequency != wantHz;
            const bool depthBad = !modeBad && wantDepth && !fullDepth(n, false);          // right mode, but the link fell back to 8 bit or 4:2:x
            const bool bad = modeBad || depthBad || (wantHdr && hdr == 0);
            if (!bad) { off = 0; fixes = 0; continue; }
            if (++off < 2 || GetTickCount64() - lastFix < 10000 || fixes >= 3) continue;   // let Windows finish its own change first
            off = 0;
            if (++fixes == 3) say("  third restore in a row: giving up until the mode holds again\n");
            lastFix = GetTickCount64();
            say("display changed: %ls %lux%lu %lu Hz HDR %d%s, restoring %lu Hz\n", n.gdi.c_str(), cur.dmPelsWidth, cur.dmPelsHeight, cur.dmDisplayFrequency, hdr, depthBad ? " link depth lost" : "", wantHz);
            if (modeBad || depthBad) {
                const bool ok = setMode(n, wantHz, depthBad);
                say("  mode -> %d\n", int(ok));
                if (ok) modeChanged = true;
                Sleep(2500);
                n = tvPath();
            }
            if (wantHdr && n.ok && hdrState(n) == 0) { say("  HDR on -> %d\n", int(hdrOn(n))); Sleep(1500); n = tvPath(); }
            if (n.ok && wantDepth && !fullDepth(n)) say("  the link is not 10 bit RGB / 4:4:4 after the restore\n");
        }
        say(woke == WAIT_OBJECT_0 ? "Veyra closed\n" : "asked to close: putting the display back, Veyra stays\n");
    }
    // Put back what was changed here, on the TV only. A TV that is just being re-plugged gets a few seconds.
    d = tvPath();
    for (int i = 0; i < 10 && !d.ok && (ownHdr || modeChanged); ++i) { Sleep(500); d = tvPath(); }
    if (d.ok) {
        if (ownHdr) {
            const int h = hdrState(d);
            if (h == 0 || (h == 1 && setHdr(d, false))) mark(false);
            say("HDR off again -> %d\n", int(!marked()));
        }
        if (modeChanged) ChangeDisplaySettingsExW(d.gdi.c_str(), nullptr, nullptr, 0, nullptr);                   // back to the saved mode
    } else if (ownHdr || modeChanged) {
        // No TV, no display to change: the mode was temporary and is not saved; HDR is saved per monitor,
        // the mark makes the next run turn it off.
        say("the TV is not there at the end: nothing put back%s\n", ownHdr ? ", HDR will be turned off by the next run" : "");
    }
    SetThreadExecutionState(ES_CONTINUOUS);
    SetEvent(g_done);
    return rc;
}
