// file_dialog.mc: the system's own dialogs for opening and saving a patch.
//
// Windows uses the common file dialogs, macOS the open and save panels
// through the Objective-C runtime. Linux has no one standard, so zenity is
// tried, then kdialog. Each dialog is modal: the drawing thread waits while
// it is open, and the audio thread plays on. The web has no dialog here; it
// keeps its patch in the page (main.mc).

import str;
import file;
import process;
import objc_runtime;

const str PATCH_EXT = ".patch";

// What a dialog came back with.
struct Picked {
    string path;                        // the file chosen, "/" separated; empty when cancelled
    bool missing;                       // no dialog exists on this system
}

// The path with ".patch" added when it has no extension.
string with_patch_ext(str path) {
    if path_ext(path).len > 0 { return format("{}", path); }
    return str_concat(path, PATCH_EXT);
}

private string slashes(str path) {
    string s = format("{}", path);
    for i32 i = 0; i < s.len; i++ { if s.data[i] == '\\' { s.data[i] = '/'; } }
    return s;
}

// ---- Windows ----

when os(windows) {
    extern "comdlg32.dll" {
        i32 GetOpenFileNameW(OpenFileName* ofn);
        i32 GetSaveFileNameW(OpenFileName* ofn);
    }
    extern "kernel32.dll" {
        i32 dlg_to_wide(u32 cp, u32 flags, u8* mb, i32 cb, u16* wc, i32 cc) from "MultiByteToWideChar";
        i32 dlg_from_wide(u32 cp, u32 flags, u16* wc, i32 cc, u8* mb, i32 cb, void* def, void* used) from "WideCharToMultiByte";
    }

    // OPENFILENAMEW, 152 bytes on x64.
    struct OpenFileName {
        u32 size;
        void* owner;
        void* instance;
        u16* filter;
        u16* custom_filter;
        u32 max_custom_filter;
        u32 filter_index;
        u16* file;
        u32 max_file;
        u16* file_title;
        u32 max_file_title;
        u16* initial_dir;
        u16* title;
        u32 flags;
        u16 file_offset;
        u16 file_extension;
        u16* default_ext;
        i64 cust_data;
        void* hook;
        u16* template_name;
        void* reserved_ptr;
        u32 reserved;
        u32 flags_ex;
    }

    const u32 CP_UTF8 = 65001;
    const u32 OFN_OVERWRITEPROMPT = 0x2;
    const u32 OFN_NOCHANGEDIR = 0x8;
    const u32 OFN_PATHMUSTEXIST = 0x800;
    const u32 OFN_FILEMUSTEXIST = 0x1000;
    const u32 OFN_EXPLORER = 0x80000;
    const i32 WIN_PATH = 1024;

    private {
        u16[1024] g_dlg_file;
        u16[96] g_dlg_filter;

        // Appends s and its terminating 0 at `at`; returns the next free place.
        i32 wide_put(u16* buf, i32 at, str s) {
            for i32 i = 0; i < s.len; i++ { buf[at + i] = cast(u16, s.data[i]); }
            buf[at + s.len] = 0;
            return at + s.len + 1;
        }
    }

    Picked win_dialog(void* owner, bool save, str suggested) {
        Picked r;
        r.path = string("");
        // "Patches\0*.patch\0All files\0*.*\0\0"
        i32 at = wide_put(&g_dlg_filter[0], 0, "Patches (*.patch)");
        at = wide_put(&g_dlg_filter[0], at, "*.patch");
        at = wide_put(&g_dlg_filter[0], at, "All files (*.*)");
        at = wide_put(&g_dlg_filter[0], at, "*.*");
        g_dlg_filter[at] = 0;
        u16[8] ext;
        ignore wide_put(&ext[0], 0, "patch");
        g_dlg_file[0] = 0;
        if suggested.len > 0 {
            // The dialog takes backslashes only: a "/" makes the name invalid.
            u8* c = str_to_cstr(suggested);
            defer free(c);
            for i32 i = 0; i < suggested.len; i++ { if c[i] == '/' { c[i] = '\\'; } }
            if dlg_to_wide(CP_UTF8, 0, c, -1, &g_dlg_file[0], WIN_PATH) <= 0 { g_dlg_file[0] = 0; }
        }
        OpenFileName o;
        o.size = cast(u32, sizeof(OpenFileName));
        o.owner = owner;
        o.filter = &g_dlg_filter[0];
        o.filter_index = 1;
        o.file = &g_dlg_file[0];
        o.max_file = cast(u32, WIN_PATH);
        o.default_ext = &ext[0];
        o.flags = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST;
        i32 ok = 0;
        if save {
            o.flags |= OFN_OVERWRITEPROMPT;
            ok = GetSaveFileNameW(&o);
        } else {
            o.flags |= OFN_FILEMUSTEXIST;
            ok = GetOpenFileNameW(&o);
        }
        if ok == 0 { return r; }
        u8[4096] out;
        i32 n = dlg_from_wide(CP_UTF8, 0, &g_dlg_file[0], -1, &out[0], 4096, null, null);
        if n <= 1 { return r; }
        free(r.path);
        r.path = slashes(str_from(&out[0], n - 1));
        return r;
    }
}

// ---- macOS ----

when os(macos) {
    private void* ns_string(str s) {
        u8* c = str_to_cstr(s);
        defer free(c);
        return objc.msg_id_i(objc_classref("NSString", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("stringWithUTF8String:"), cast(void*, c));
    }

    Picked mac_dialog(bool save, str suggested) {
        Picked r;
        r.path = string("");
        void* panel = null;
        if save { panel = objc.msg_id_v(objc_classref("NSSavePanel", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("savePanel")); }
        else { panel = objc.msg_id_v(objc_classref("NSOpenPanel", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("openPanel")); }
        if panel == null {
            r.missing = true;
            return r;
        }
        void* types = objc.msg_id_i(objc_classref("NSArray", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("arrayWithObject:"), ns_string("patch"));
        objc.msg_void_i(panel, objc_selref("setAllowedFileTypes:"), types);
        if save && suggested.len > 0 {
            objc.msg_void_i(panel, objc_selref("setNameFieldStringValue:"), ns_string(path_basename(suggested)));
        }
        // Start in the suggested file's folder, else the working directory.
        // Left alone, the panel starts where the system last saw a panel
        // from a program without a bundle, which can be another program's.
        void* dir = null;
        if path_dirname(suggested).len > 0 { dir = ns_string(path_dirname(suggested)); }
        else {
            void* fm = objc.msg_id_v(objc_classref("NSFileManager", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("defaultManager"));
            dir = objc.msg_id_v(fm, objc_selref("currentDirectoryPath"));
        }
        if dir != null {
            void* dir_url = objc.msg_id_i(objc_classref("NSURL", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("fileURLWithPath:"), dir);
            objc.msg_void_i(panel, objc_selref("setDirectoryURL:"), dir_url);
        }
        if objc.msg_q_v(panel, objc_selref("runModal")) != 1 { return r; }          // NSModalResponseOK
        void* url = objc.msg_id_v(panel, objc_selref("URL"));
        if url == null { return r; }
        void* path = objc.msg_id_v(url, objc_selref("path"));
        u8* c = cast(u8*, objc.msg_id_v(path, objc_selref("UTF8String")));
        if c == null { return r; }
        free(r.path);
        r.path = format("{}", str_from_cstr(c));
        return r;
    }
}

// ---- Linux ----

when os(linux) {
    // Runs a dialog program; its chosen path, or empty. `spawned` tells
    // whether the program exists at all.
    private string run_dialog(ProcCmd* c, bool* spawned) {
        proc_capture(c, true);
        proc_merge_stderr(c, false);
        ProcResult r = proc_run(c);
        defer proc_result_free(&r);
        *spawned = r.spawned && r.exit_code != 127;
        if !r.spawned || r.exit_code != 0 { return string(""); }
        return format("{}", str_trim(str_from(r.out.data, r.out.len)));
    }

    Picked linux_dialog(bool save, str suggested) {
        Picked r;
        bool spawned = false;
        ProcCmd z = { .args = { "zenity", "--file-selection", "--title=minc-synth",
                                "--file-filter=Patches | *.patch", "--file-filter=All files | *" } };
        if save {
            proc_arg(&z, "--save");
            proc_arg(&z, "--confirm-overwrite");
            if suggested.len > 0 {
                string f = str_concat("--filename=", suggested);
                defer free(f);
                proc_arg(&z, str_from(f.data, f.len));
            }
        }
        r.path = run_dialog(&z, &spawned);
        if spawned { return r; }
        free(r.path);
        str start = suggested.len > 0 ? suggested : ".";
        ProcCmd k = { .args = { "kdialog", save ? "--getsavefilename" : "--getopenfilename", start, "*.patch|Patches" } };
        r.path = run_dialog(&k, &spawned);
        r.missing = !spawned;
        return r;
    }
}

// ---- one call for all ----

// Asks for a patch to open (save false) or a place to save one. `owner`
// is the window on Windows; `suggested` the file or name to start from.
Picked file_dialog(void* owner, bool save, str suggested) {
    when os(windows) { return win_dialog(owner, save, suggested); }
    else when os(macos) {
        ignore owner;
        return mac_dialog(save, suggested);
    }
    else when os(linux) {
        ignore owner;
        return linux_dialog(save, suggested);
    }
    else {
        ignore owner;
        ignore save;
        ignore suggested;
        Picked r;
        r.path = string("");
        r.missing = true;
        return r;
    }
}
