// window.mc: the window's chrome.
//
// The icon, drawn here as pixels so nothing needs a resource compiler:
// a jack on a dark square. The title bar shows no name, since the bar
// inside the window has it; the name stays for the taskbar and window
// switching. On Windows also a dark title bar; Linux takes what its
// window manager gives. The window starts maximized through sapp_desc
// (main.mc), which sokol_app applies before the window is first shown.

import sokol_all;
import math;

when os(windows) {
    extern "dwmapi.dll" i32 DwmSetWindowAttribute(void* hwnd, u32 attr, void* value, u32 size);
    extern "uxtheme.dll" i32 SetWindowThemeAttribute(void* hwnd, i32 attr, void* options, u32 size);
    extern "user32.dll" i64 win_send_message(void* hwnd, u32 msg, u64 wparam, i64 lparam) from "SendMessageW";
    extern "user32.dll" i64 win_set_class_long(void* hwnd, i32 index, i64 value) from "SetClassLongPtrW";
    const u32 WM_GETICON = 0x7F;
    const i32 GCLP_HICON = -14;
    const i32 GCLP_HICONSM = -34;
    const u32 DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    const i32 WTA_NONCLIENT = 1;
    const u32 WTNCA_NODRAWCAPTION = 1;

    struct WtaOptions {
        u32 flags;
        u32 mask;
    }
}

private {
    u8[64 * 64 * 4] g_icon64;
    u8[32 * 32 * 4] g_icon32;
    u8[16 * 16 * 4] g_icon16;

    // Coverage of a disc of radius r at distance d from its centre, one
    // pixel of anti-aliasing.
    f32 disc(f32 d, f32 r) { return clampf(r - d + 0.5f, 0.0f, 1.0f); }

    void blend(f32* dst, f32 src, f32 cover) { *dst = *dst + (src - *dst) * cover; }

    // A rounded dark square, a white ring, a red dot.
    void draw_icon(u8* px, i32 n) {
        f32 half = cast(f32, n) * 0.5f;
        f32 corner = cast(f32, n) * 0.18f;
        for i32 y = 0; y < n; y++ {
            for i32 x = 0; x < n; x++ {
                f32 fx = cast(f32, x) + 0.5f - half;
                f32 fy = cast(f32, y) + 0.5f - half;
                // Rounded square: distance to the inner box, then a radius.
                f32 qx = fabsf(fx) - (half - corner);
                f32 qy = fabsf(fy) - (half - corner);
                f32 ox = qx > 0.0f ? qx : 0.0f;
                f32 oy = qy > 0.0f ? qy : 0.0f;
                f32 dbox = sqrtf(ox * ox + oy * oy) + (qx > qy ? qx : qy) * (qx > 0.0f || qy > 0.0f ? 0.0f : 1.0f);
                f32 a = disc(dbox, corner);
                f32 d = sqrtf(fx * fx + fy * fy);
                f32 r = 0.07f;
                f32 g = 0.07f;
                f32 b = 0.07f;
                f32 ring = disc(d, half * 0.62f) - disc(d, half * 0.42f);
                if ring < 0.0f { ring = 0.0f; }
                blend(&r, 0.96f, ring);
                blend(&g, 0.96f, ring);
                blend(&b, 0.96f, ring);
                f32 dot = disc(d, half * 0.2f);
                blend(&r, 0.90f, dot);
                blend(&g, 0.13f, dot);
                blend(&b, 0.15f, dot);
                i32 i = (y * n + x) * 4;
                px[i] = cast(u8, r * 255.0f + 0.5f);
                px[i + 1] = cast(u8, g * 255.0f + 0.5f);
                px[i + 2] = cast(u8, b * 255.0f + 0.5f);
                px[i + 3] = cast(u8, a * 255.0f + 0.5f);
            }
        }
    }
}

// Sets the icon, hides the title bar's name and, on Windows, darkens the
// title bar. Call once from init, after sokol_app has its window.
void window_setup() {
    draw_icon(&g_icon64[0], 64);
    draw_icon(&g_icon32[0], 32);
    draw_icon(&g_icon16[0], 16);
    sapp_set_icon(&sapp_icon_desc{
        .images[0] = { .width = 64, .height = 64, .pixels = { &g_icon64[0], sizeof(g_icon64) } },
        .images[1] = { .width = 32, .height = 32, .pixels = { &g_icon32[0], sizeof(g_icon32) } },
        .images[2] = { .width = 16, .height = 16, .pixels = { &g_icon16[0], sizeof(g_icon16) } },
    });
    when os(windows) {
        void* hwnd = sapp_win32_get_hwnd();
        i32 dark = 1;
        ignore DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, 4);
        // The window class keeps the stock icon sokol_app registered it
        // with; the taskbar reads the class's.
        ignore win_set_class_long(hwnd, GCLP_HICON, win_send_message(hwnd, WM_GETICON, 1, 0));
        ignore win_set_class_long(hwnd, GCLP_HICONSM, win_send_message(hwnd, WM_GETICON, 0, 0));
        WtaOptions caption = WtaOptions{ WTNCA_NODRAWCAPTION, WTNCA_NODRAWCAPTION };
        ignore SetWindowThemeAttribute(hwnd, WTA_NONCLIENT, &caption, 8);
    }
    when os(macos) {
        void* win = sapp_macos_get_window();
        if win != null { objc.msg_void_q(win, objc_selref("setTitleVisibility:"), 1); }   // NSWindowTitleHidden
    }
}
