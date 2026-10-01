// build.mc: build, run and test minc-synth.
//
// Usage, from this folder:
//   minc run [args]           build for this machine and run; args go to the app
//   minc run render [args]    build and run tools/render.mc, the offline renderer
//   minc run analog           build and run tools/analog_report.mc, the analog reference report
//   minc run <file.mc> [args] build and run another program in the tree
//   minc build                compile for this machine
//   minc build <target>       windows | linux | macos | wasm | all
//   minc build vendor         re-copy the sokol helper modules into lib/
//   minc wasm                 build for the browser, stage fonts and presets, serve and open
//   minc wasm --no-run        the same without opening the browser
//   minc test                 run test/*.mc (--filter, --changed, --timeout)
//   minc clean
//
// minc hands only its own verbs (run, build, test, clean, wasm) to this
// script, so the extra actions ride on run and build.
//
// Outputs go under build/<target>/: windows/minc-synth.exe,
// linux/minc-synth, macos/minc-synth, web/minc-synth.wasm. The natural
// name on each platform, since macOS shows it in the title bar; a
// directory per target keeps the cross-builds apart.
//
// The compiler is taken from MINC, then PATH.

@minc_min_version "0.9.16"

// Older minc ignores the tag above; this forces an error instead.
when !defined(MINC_VERSION) || MINC_VERSION < 9016 {
    minc_0_9_16_or_newer_required please_update_minc;
}

import process;
import file;
import str;
import test_framework;

const str APP_SRC = "src/main.mc";

// sokol helper modules the minc install does not ship. They come from
// the sokol-samples-minc repository and are pinned in lib/VENDORED.txt.
const str VENDOR_DEFAULT_DIR = "../sokol-samples-minc";
str[5] VENDOR_FILES = { "sokol_gl.mc", "sokol_debugtext.mc", "sokol_time.mc", "fontstash.mc", "sokol_fontstash.mc" };

when os(windows) { const str HOST_TARGET = "windows"; }
else when os(linux) { const str HOST_TARGET = "linux"; }
else when os(macos) { const str HOST_TARGET = "macos"; }

void die(str s) {
    eprint("{}\n", s);
    exit(1);
    return;
}

// MINC (an install dir or the binary itself), then PATH.
string find_minc() {
    string env = env_get("MINC");
    if env.len > 0 {
        if path_is_dir(env) {
            string base = str_concat("minc", TEST_EXE_SUFFIX);
            defer free(base);
            string cand = path_join(env, base);
            free(env);
            return cand;
        }
        return env;
    }
    free(env);
    return path_which("minc");
}

// Output path for a target; empty for an unknown target.
str out_path(str target) {
    if str_equal(target, "windows") { return "build/windows/minc-synth.exe"; }
    if str_equal(target, "linux") { return "build/linux/minc-synth"; }
    if str_equal(target, "macos") { return "build/macos/minc-synth"; }
    if str_equal(target, "wasm") { return "build/web/minc-synth.wasm"; }
    return "";
}

// Compile `src` for `target` into `out`. Returns the compiler's exit code.
i32 compile(str cc, str src, str target, str out) {
    ProcCmd c = { .args = { cc, src, "--target", target, "-o", out } };
    ProcResult r = proc_run(&c);
    i32 rc = r.exit_code;
    if !r.spawned { eprint("could not start {}\n", cc); rc = 1; }
    proc_result_free(&r);
    return rc;
}

i32 build_target(str cc, str target) {
    str out = out_path(target);
    if out.len == 0 {
        eprint("unknown target '{}' (windows, linux, macos, wasm, all)\n", target);
        return 1;
    }
    ignore dir_create(path_dirname(out));
    if str_equal(target, "wasm") {
        if !stage_web() { return 1; }
    }
    print("building {} -> {}\n", target, out);
    return compile(cc, APP_SRC, target, out);
}

// The browser has no file system: the host page preloads what the app
// reads (fonts, presets) into a virtual one from assets.json, and the
// preset list comes from patches/index.txt since a directory cannot be
// listed. Both are written here, next to the .wasm the dev server serves.
bool stage_web() {
    ignore dir_create("build/web/fonts");
    ignore dir_create("build/web/patches");
    str_buf assets;
    str_buf_init(&assets);
    defer str_buf_free(&assets);
    str_buf_add(&assets, "[");
    str_buf index;
    str_buf_init(&index);
    defer str_buf_free(&index);
    i32 n = 0;
    str[2] dirs = { "fonts", "patches" };
    str[2] exts = { ".ttf", ".patch" };
    for i32 d = 0; d < 2; d++ {
        DirList files = dir_list_ext(dirs[d], exts[d]);
        defer dir_list_free(&files);
        for i32 i = 0; i < files.count; i++ {
            string rel = path_join(dirs[d], files.items[i]);
            defer free(rel);
            string dst = path_join("build/web", rel);
            defer free(dst);
            if !file_copy(rel, dst) {
                eprint("could not copy {}\n", rel);
                return false;
            }
            if n > 0 { str_buf_add(&assets, ","); }
            str_buf_add(&assets, "\"");
            str_buf_add(&assets, rel);
            str_buf_add(&assets, "\"");
            n++;
            if d == 1 {
                str_buf_add(&index, files.items[i]);
                str_buf_add(&index, "\n");
            }
        }
    }
    if n > 0 { str_buf_add(&assets, ","); }
    str_buf_add(&assets, "\"patches/index.txt\"]\n");
    return file_write_str("build/web/patches/index.txt", str_buf_to_str(&index))
        && file_write_str("build/web/assets.json", str_buf_to_str(&assets));
}

// Builds for the browser and serves build/web, as the compiler does for
// any wasm program: it stages the page main.mc declares (@wasm_html,
// web/synth.html) as index.html, serves the folder and opens the browser.
// It runs from build/, where no build.mc hands the verb back to this
// script. --no-run serves without opening the browser.
i32 wasm_run(str cc, bool open) {
    ignore dir_create("build/web");
    if !stage_web() { return 1; }
    ProcCmd c = { .args = { cc, "run", "--target", "wasm", "../src/main.mc", "-o", "web/minc-synth.wasm" } };
    proc_cwd(&c, "build");
    if !open { proc_arg(&c, "--no-browser"); }
    ProcResult r = proc_run(&c);
    i32 rc = r.exit_code;
    proc_result_free(&r);
    return rc;
}

i32 build_all(str cc) {
    str[4] targets = { "windows", "linux", "macos", "wasm" };
    i32 failed = 0;
    for i32 i = 0; i < 4; i++ {
        if build_target(cc, targets[i]) != 0 { failed++; }
    }
    if failed > 0 {
        print("{} of 4 target(s) failed\n", failed);
        return 1;
    }
    print("all 4 targets built.\n");
    return 0;
}

// Build `src` for this machine into `exe`, then run it with args[first..].
i32 build_and_run(str cc, str src, str exe, i32 first) {
    ignore dir_create(path_dirname(exe));
    i32 rc = compile(cc, src, HOST_TARGET, exe);
    if rc != 0 { return rc; }
    ProcCmd c = { .args = { exe } };
    i32 argc = get_argc();
    for i32 i = first; i < argc; i++ { proc_arg_cstr(&c, get_arg(i)); }
    ProcResult r = proc_run(&c);
    rc = r.exit_code;
    proc_result_free(&r);
    return rc;
}

// Short commit id of a git checkout, or "unknown".
string git_rev(str dir) {
    ProcCmd c = { .args = { "git", "-C", dir, "rev-parse", "--short", "HEAD" }, .capture = true };
    ProcResult r = proc_run(&c);
    defer proc_result_free(&r);
    if !r.spawned || r.exit_code != 0 { return string("unknown"); }
    return string(str_trim(r.out));
}

i32 vendor() {
    string env = env_get("SOKOL_SAMPLES_MINC");
    defer free(env);
    str src_dir = VENDOR_DEFAULT_DIR;
    if env.len > 0 { src_dir = env; }
    string lib_dir = path_join(src_dir, "lib");
    defer free(lib_dir);
    if !path_is_dir(lib_dir) {
        eprint("no {} (set SOKOL_SAMPLES_MINC to a sokol-samples-minc checkout)\n", lib_dir);
        return 1;
    }
    ignore dir_create("lib");
    for i32 i = 0; i < 5; i++ {
        string src = path_join(lib_dir, VENDOR_FILES[i]);
        defer free(src);
        string dst = path_join("lib", VENDOR_FILES[i]);
        defer free(dst);
        if !file_copy(src, dst) {
            eprint("copy failed: {} -> {}\n", src, dst);
            return 1;
        }
        print("  {}\n", dst);
    }
    string rev = git_rev(src_dir);
    defer free(rev);
    string note = format(
        "Vendored from sokol-samples-minc (https://github.com/SpacesOfPlay/sokol-samples-minc).\n"
        "source: {}\n"
        "commit: {}\n"
        "files:  sokol_gl.mc sokol_debugtext.mc sokol_time.mc fontstash.mc sokol_fontstash.mc\n"
        "\n"
        "The minc install ships sokol_all and sokol_audio but not these.\n"
        "Refresh with `minc build vendor` after a compiler update.\n",
        src_dir, rev);
    defer free(note);
    if !file_write_str("lib/VENDORED.txt", note) {
        eprint("could not write lib/VENDORED.txt\n");
        return 1;
    }
    print("vendored from {} at {}\n", src_dir, rev);
    return 0;
}

void usage() {
    print("minc-synth build script\n"
          "  minc run [args]          build for this machine and run\n"
          "  minc run render [args]   build and run tools/render.mc\n"
          "  minc build [target]      windows | linux | macos | wasm | all\n"
          "  minc build vendor        refresh lib/ from ../sokol-samples-minc\n"
          "  minc wasm [--no-run]     build for the browser, stage fonts and presets, serve\n"
          "  minc test                run test/*.mc\n"
          "  minc clean\n");
    return;
}

i32 main() {
    i32 argc = get_argc();
    str verb = "run";
    if argc > 1 { verb = str_from_cstr(get_arg(1)); }
    str sub = "";
    if argc > 2 { sub = str_from_cstr(get_arg(2)); }

    if str_equal(verb, "clean") {
        ignore dir_remove("build");
        print("clean.\n");
        return 0;
    }
    if str_equal(verb, "test") { return test_run_dir("test"); }
    if str_equal(verb, "build") && str_equal(sub, "vendor") { return vendor(); }

    string cc = find_minc();
    defer free(cc);
    if cc.len == 0 { die("minc compiler not found; set MINC or put minc on PATH"); }
    ignore dir_create("build");

    if str_equal(verb, "wasm") { return wasm_run(cc, !str_equal(sub, "--no-run")); }
    if str_equal(verb, "build") {
        if sub.len == 0 { return build_target(cc, HOST_TARGET); }
        if str_equal(sub, "all") { return build_all(cc); }
        return build_target(cc, sub);
    }
    if str_equal(verb, "run") {
        if str_ends_with(sub, ".mc") {
            // Any other program in the tree, e.g. a scratch test.
            string exe = str_concat("build/run", TEST_EXE_SUFFIX);
            defer free(exe);
            return build_and_run(cc, sub, exe, 3);
        }
        if str_equal(sub, "render") {
            if !path_exists("tools/render.mc") { die("tools/render.mc does not exist yet"); }
            string exe = str_concat("build/render", TEST_EXE_SUFFIX);
            defer free(exe);
            return build_and_run(cc, "tools/render.mc", exe, 3);
        }
        if str_equal(sub, "analog") {
            string exe = str_concat("build/analog_report", TEST_EXE_SUFFIX);
            defer free(exe);
            return build_and_run(cc, "tools/analog_report.mc", exe, 3);
        }
        return build_and_run(cc, APP_SRC, out_path(HOST_TARGET), 2);
    }
    usage();
    return 1;
}
