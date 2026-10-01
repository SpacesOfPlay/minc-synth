// rig.mc: an engine with the rack built, for tests that drive it by name.

// The one way into src/ for the test utilities: minc treats two spellings
// of one path as two modules, so everything goes through here.
import "../../src/engine_core.mc";
import "../../src/engine_cmd.mc";
import "../../src/engine.mc";
import "../../src/rack.mc";
import "../../src/dsp_svf.mc";
import "../../src/patch.mc";
import "../../src/patch_io.mc";
import "../../src/ui_layout.mc";
import "../../src/ui_view.mc";
import "../../src/ui_cables.mc";
import "../../src/ui_state.mc";

const f32 RIG_SR = 48000.0f;
const i32 RIG_BLOCK = 512;

f32[1024] g_rig_frames;                 // one stereo block

Engine* rig_new() {
    Engine* e = engine_new(RIG_SR);
    rack_build(e);
    return e;
}

// Renders n frames in blocks; returns the output peak.
f32 rig_run(Engine* e, i32 n) {
    f32 peak = 0.0f;
    i32 left = n;
    while left > 0 {
        i32 k = RIG_BLOCK;
        if left < k { k = left; }
        engine_render(e, &g_rig_frames[0], k, 2);
        for i32 i = 0; i < k * 2; i++ {
            if fabsf(g_rig_frames[i]) > peak { peak = fabsf(g_rig_frames[i]); }
        }
        left -= k;
    }
    return peak;
}

// Left channel of the last frame rendered.
f32 rig_last(Engine* e) {
    ignore e;
    return g_rig_frames[0];
}

// An output's latest value in canonical units.
f32 rig_value(Engine* e, str ref) {
    i32 s = engine_output_ref(e, ref);
    return slot_value(&e.core, s) / e.core.out_scale[s];
}

// An output's latest value in volts, as it sits on the bus.
f32 rig_volts(Engine* e, str ref) { return slot_value(&e.core, engine_output_ref(e, ref)); }

// What an input reads now, in canonical units.
f32 rig_input(Engine* e, str ref) { return jack_read(&e.core, engine_input_ref(e, ref)); }

Jack* rig_jack(Engine* e, str ref) { return &e.core.jacks[engine_input_ref(e, ref)]; }

// Applies queued commands and jumps every knob to its target, without
// the glide and without touching the modules.
void rig_snap_params(Engine* e) {
    engine_render(e, &g_rig_frames[0], 1, 2);
    Core* c = &e.core;
    for i32 i = 0; i < c.n_params; i++ {
        Param* p = &c.params[i];
        p.norm = p.target;
        p.value = param_map(p, p.norm);
    }
}

// Applies queued commands, then jumps every param to its target, ends all
// plugging fades and resets every module: the patch starts from rest with
// its final settings, as an analog model would.
void rig_settle(Engine* e) {
    engine_render(e, &g_rig_frames[0], 1, 2);
    Core* c = &e.core;
    for i32 i = 0; i < c.n_params; i++ {
        Param* p = &c.params[i];
        p.norm = p.target;
        p.value = param_map(p, p.norm);
    }
    for i32 j = 0; j < c.n_jacks; j++ {
        c.jacks[j].fade_left = 0;
        c.jacks[j].bounce_left = 0;
        c.jacks[j].animating = false;
    }
    c.n_anim = 0;
    for i32 m = 0; m < e.n_modules; m++ { engine_reset_module(e, m); }
}

// A copy of a running engine, with its bus pointers re-aimed at its own buses.
Engine* rig_clone(Engine* e) {
    Engine* c = new(Engine);
    *c = *e;
    core_rebind(&c.core, &e.core);
    return c;
}
