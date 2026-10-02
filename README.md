# minc-synth

A cable-patched modular synthesizer written in [minc](https://minc.dev).
The sound and layout follow the large 1970s studio modular systems, with
the Moog System 55 as the sonic inspiration. The names and visuals are
original.

It runs on Windows, macOS and Linux, and in the browser (wasm). Please do
report any bugs found.

## Install minc

Windows:
```
powershell -c "irm minc.dev/install.ps1 | iex"
```

macOS and Linux:
```
curl -fsSL https://minc.dev/install | bash
```

minc 0.9.16 or newer is required.

## Build and run

```
git clone <this repo>
cd minc-synth
minc run            # build for this machine and start the synth
minc wasm           # build for the browser, serve it and open it
minc test           # run the tests
minc build all      # build every target into build/
```

Run the commands from the repo root. The app reads its presets from
`patches/` and its fonts from `fonts/`.

## Playing

- The keys Z to M and Q to I play two octaves; the rows above play the
  sharps.
- Drag from a jack to another jack to connect a cable. Drag a plug to
  move it. Right-click a cable to remove it.
- Drag a knob left or right, or turn it with the mouse wheel. Hold Shift
  for fine steps.
- PRESET (or `[` and `]`) steps through the presets.
- SAVE and LOAD use the system's file dialogs. Ctrl+S saves the current
  file, Ctrl+Shift+S asks where. A patch file dropped on the window opens.
- HELP lists every key and gesture.

In the browser, the patch is kept in the page and in the address bar.

Offline rendering to a WAV file:
```
minc run render out.wav 16 --patch patches/01-unison-bass.patch
```

## Technical summary

- **Engine.** Every module is processed once per sample. A cable adds
  one sample of delay, so feedback patches work like on the hardware.
  The engine runs at 2x the device rate by default and 4x on HIGH, and
  is filtered back down at the output.
- **Modules.** Keyboard, oscillator and oscillator banks, 4-pole
  transistor-ladder low-pass and high-pass filters, band filter, filter
  bank, envelopes, amplifiers, mixers, noise, 3x8 sequencer, step switch,
  trigger delay, gates, offsets, attenuators, multiples, scope and output.
- **DSP.** Band-limited oscillators (polyBLEP), a nonlinear ladder filter,
  RC-curve envelopes and an AGE control that adds component tolerances and
  slow pitch drift. Parameters are smoothed over 30 ms.
- **Polyphony.** Up to 8 voices. A cable carries 1 to 8 channels; each
  module keeps a fast path for one channel.
- **Profiles.** MODERN and VINTAGE switched with F1.
  - Both: pitch at 1 V per octave.
  - MODERN: audio at +-5 V; control voltages at 0 to 10 V or +-5 V;
    gates and triggers at 0 to 10 V, on above 2 V and off below 1 V; any
    output can go to any input.
  - VINTAGE: audio at +-1.5 V; control voltages at 0 to 5.5 V or
    +-2.75 V; triggers are switch closures on square jacks and connect
    only to other trigger jacks; one trigger input takes up to four
    cables, and any of them turns it on; the GATES module turns an audio
    or control signal into a trigger.
  - A patch within one kind of signal sounds the same in both. Audio
    into a control input modulates about half as deep in VINTAGE.
- **Audio thread.** The UI sends commands to the engine through a queue;
  the engine reports levels back for the cable display. The audio thread
  does not allocate or lock.
- **UI.** Drawn with sokol_gl, text with fontstash. Cables are simulated
  as ropes and show the signal passing through them.
- **Patches.** A plain text format, one line per setting or cable.
- **Tests.** Unit tests for each DSP part, engine and patch tests, a UI
  test that replays mouse and key events, and an analog reference suite
  that compares modules against exact models (`minc run analog`).

## Layout

- `src/`: the app. `dsp_*` signal processing, `mod_*` modules,
  `engine*` the engine, `ui_*` drawing and input, `patch*` the patch
  model and file format.
- `patches/`: presets, written by `tools/presets.mc`.
- `tools/`: offline renderer, preset writer, benchmark, analog report.
- `test/`: the tests.
- `web/`: the browser page.
- `lib/`: sokol modules not included with minc (see `lib/VENDORED.txt`).
- `fonts/`: Liberation Sans, under the SIL Open Font License
  (`fonts/LICENSE.txt`).
- `build.mc`: the build script behind `minc run`, `minc build`,
  `minc wasm` and `minc test`.

## Copyright

minc-synth is released under the MIT License (see `LICENSE`).

Liberation Sans is copyright Red Hat, Inc. and Google Corporation, under
the SIL Open Font License 1.1 (see `fonts/LICENSE.txt`).

The sokol, sokol_gl and fontstash modules in `lib/` are copyright their
authors, under the licenses in each file.

Moog and System 55 are trademarks of Moog Music Inc. minc-synth is not
affiliated with or endorsed by Moog Music.

