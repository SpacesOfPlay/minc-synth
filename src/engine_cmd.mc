// engine_cmd.mc: what crosses between the UI thread and the audio thread.
//
// Commands go UI -> audio through a single-producer, single-consumer
// ring. Telemetry goes audio -> UI as values published with atomics once
// per block. On wasm both sides run on one thread and the same code holds.

import atomic;
import dsp_math;

enum CmdKind {
    CMD_PARAM,              // a: param, value: normalized 0..1
    CMD_CONNECT,            // a: output slot, b: input jack
    CMD_DISCONNECT,         // a: output slot, b: input jack
    CMD_KEY_ON,             // a: note (60 = C4)
    CMD_KEY_OFF,            // a: note
    CMD_PANIC,              // fade out, reset every module, release keys, fade in
    CMD_RESET_MODULE,       // a: module
    CMD_LOAD_BEGIN,         // commands until LOAD_END apply together, in silence
    CMD_LOAD_END,
    CMD_PROFILE,            // a: Profile
    CMD_FEEL,               // a: PlugFeel
    CMD_SCOPE,              // a: channel 0/1, b: slot, or -1 for the master output
}

struct Cmd {
    i32 kind;
    i32 a;
    i32 b;
    f32 value;
}

const i32 CMD_RING_SIZE = 4096;
const u32 CMD_RING_MASK = CMD_RING_SIZE - 1;

struct CmdRing {
    Cmd[CMD_RING_SIZE] items;
    u32 head;               // next write, producer only
    u32 tail;               // next read, consumer only
}

// Producer side. False when the ring is full.
bool cmd_push(CmdRing* r, Cmd c) {
    u32 h = atomic_load(&r.head, RELAXED);
    u32 t = atomic_load(&r.tail, ACQUIRE);
    if h - t >= CMD_RING_SIZE { return false; }
    r.items[h & CMD_RING_MASK] = c;
    atomic_store(&r.head, h + 1, RELEASE);
    return true;
}

// Consumer side. False when the ring is empty.
bool cmd_pop(CmdRing* r, Cmd* out) {
    u32 t = atomic_load(&r.tail, RELAXED);
    u32 h = atomic_load(&r.head, ACQUIRE);
    if t == h { return false; }
    *out = r.items[t & CMD_RING_MASK];
    atomic_store(&r.tail, t + 1, RELEASE);
    return true;
}

// ---- telemetry ----

const i32 TELE_SLOTS = 512;                 // MAX_SLOTS
const i32 SCOPE_LEN = 4096;
const u32 SCOPE_MASK = SCOPE_LEN - 1;

struct Telemetry {
    u32[TELE_SLOTS] peak_bits;              // per slot: peak |volts| over the last 50..100 ms
    u32[TELE_SLOTS] value_bits;             // per slot: volts at the end of the last block
    u32[64] events;                         // per module: key presses taken, counted (MAX_MODULES)
    i32[64] state;                          // per module: what its panel shows (sequencer step, switch stage)
    f32:[2][4096] scope;                    // two channels, SCOPE_LEN each
    u32 scope_w;                            // write cursor, monotonic
    u32 scope_decim;                        // device frames per recorded frame
    u32 nan_resets;                         // modules reset by the NaN guard, total
    u32 blocks;                             // blocks rendered
    i32[512] channels;                      // per slot: voices it carries, 1 for mono (TELE_SLOTS)
    u32 out_peak_bits;                      // master output peak over the last block
    i32 note;                               // sounding KEYS note, or -1
    i32 silent;                             // 1 while held at silence for a load or panic
}

f32 tele_peak(Telemetry* t, i32 slot) { return bits_f32(atomic_load(&t.peak_bits[slot], RELAXED)); }
f32 tele_value(Telemetry* t, i32 slot) { return bits_f32(atomic_load(&t.value_bits[slot], RELAXED)); }
u32 tele_events(Telemetry* t, i32 module) { return atomic_load(&t.events[module], RELAXED); }
i32 tele_state(Telemetry* t, i32 module) { return atomic_load(&t.state[module], RELAXED); }
i32 tele_channels(Telemetry* t, i32 slot) { return atomic_load(&t.channels[slot], RELAXED); }
f32 tele_out_peak(Telemetry* t) { return bits_f32(atomic_load(&t.out_peak_bits, RELAXED)); }
