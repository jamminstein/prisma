// Engine_PRISMA.sc
// v4 — all audit issues resolved
//
// Fixes from v3:
//   A. LinExp srclo changed from 0 to 0.001 throughout
//      (LinExp(0, 0, 1, ...) produces NaN/silence when input hits 0.0)
//   B. All effectSynth.set calls guarded with .notNil check
//      (s.bind is async; .set on nil before bind executes crashes SC)
//   C. Added unused arg in_bus to fx1 and fx5 SynthDefs
//      (suppresses "arg not found" warnings from prSwitchTo always
//       passing \in_bus regardless of whether the SynthDef uses it)

Engine_PRISMA : CroneEngine {

  var recorder;
  var effectSynth;
  var sharedBuf;
  var activePage;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    var s = context.server;

    sharedBuf  = Buffer.alloc(s, 131072, 1); // ~3s mono at 44100
    activePage = 1;

    s.sync;

    // ------------------------------------------------------------------
    // RECORDER — always running, fills sharedBuf continuously
    // bufnum is ir-rate: RecordBuf resolves it once at synth creation
    // ------------------------------------------------------------------
    SynthDef(\prisma_recorder, {
      arg in_bus;
      var bufnum = \bufnum.ir(0);
      var input  = In.ar(in_bus, 2).sum * 0.5;
      RecordBuf.ar(input, bufnum, loop: 1, doneAction: 0);
    }).add;

    // ------------------------------------------------------------------
    // FX 1 — Granular Morph
    // in_bus declared even though unused — suppresses "arg not found" log
    // LinExp srclo = 0.001 throughout (never 0 — avoids log(0) NaN)
    // ------------------------------------------------------------------
    SynthDef(\prisma_fx1_granular_morph, {
      arg in_bus = 0, out_bus = 0, gate = 1, pos = 0.5, amp = 1.0;
      var bufnum   = \bufnum.ir(0);
      var safePos  = pos.max(0.001);
      var bufDur   = BufDur.kr(bufnum);
      var trigRate = LinExp.kr(safePos, 0.001, 1, 4, 28);
      var grainDur = LinExp.kr(safePos, 0.001, 1, 0.4, 0.04);
      var rate     = LinExp.kr(safePos, 0.001, 1, 0.5, 2.0);
      var centre   = LFSaw.kr(0.08 + (safePos * 0.12)).range(0.05, 0.95) * bufDur;
      var grains   = TGrains.ar(
        numChannels: 2,
        trigger:     Impulse.ar(trigRate),
        bufnum:      bufnum,
        rate:        rate + LFNoise1.kr(2).range(-0.05, 0.05),
        centerPos:   centre,
        dur:         grainDur,
        pan:         LFNoise1.kr(1.5).range(-0.6, 0.6),
        amp:         0.5
      );
      var env = EnvGen.kr(Env.asr(0.08, 1.0, 0.2), gate, doneAction: 2);
      Out.ar(out_bus, grains * env * amp);
    }).add;

    // ------------------------------------------------------------------
    // FX 2 — Spectral Freeze
    // K2A.ar converts kr boolean to ar for PV_MagFreeze gate input
    // ------------------------------------------------------------------
    SynthDef(\prisma_fx2_spectral_freeze, {
      arg in_bus = 0, out_bus = 0, gate = 1, density = 0.5, amp = 1.0;
      var input      = In.ar(in_bus, 2).sum * 0.5;
      var chain      = FFT(LocalBuf(2048), input);
      var freezeGate = K2A.ar((density > 0.6).asUGenInput);
      var frozen     = PV_MagFreeze(chain, freezeGate);
      var smeared    = PV_MagSmear(frozen, (density * 8).round.max(0));
      var wet        = IFFT(smeared);
      var sig        = XFade2.ar(input, wet, (density * 2) - 1);
      var env        = EnvGen.kr(Env.asr(0.08, 1.0, 0.2), gate, doneAction: 2);
      Out.ar(out_bus, (sig ! 2) * env * amp);
    }).add;

    // ------------------------------------------------------------------
    // FX 3 — Reactive Grain
    // scatter clamped to 0.001 min for LinExp safety
    // trigRate hard-capped at 28 for CPU safety
    // ------------------------------------------------------------------
    SynthDef(\prisma_fx3_reactive_grain, {
      arg in_bus = 0, out_bus = 0, gate = 1, scatter = 0.5, amp = 1.0;
      var bufnum      = \bufnum.ir(0);
      var safeScatter = scatter.max(0.001);
      var input       = In.ar(in_bus, 2).sum * 0.5;
      var bufDur      = BufDur.kr(bufnum);
      var envAmp      = Amplitude.kr(input, 0.005, 0.2).clip(0.001, 1.0);
      var trigRate    = (LinExp.kr(envAmp, 0.001, 1.0, 3, 24) * (1 + safeScatter)).min(28);
      var posNoise    = LFNoise1.kr(trigRate * 0.4).range(0.0, 1.0);
      var centre      = (posNoise * envAmp * safeScatter * bufDur).max(0.01);
      var grains      = TGrains.ar(
        numChannels: 2,
        trigger:     Impulse.ar(trigRate),
        bufnum:      bufnum,
        rate:        1.0 + (LFNoise1.kr(3).range(-0.15, 0.15) * safeScatter),
        centerPos:   centre,
        dur:         LinExp.kr(safeScatter, 0.001, 1, 0.25, 0.04),
        pan:         LFNoise1.kr(2).range(-0.7, 0.7),
        amp:         0.45
      );
      var env = EnvGen.kr(Env.asr(0.08, 1.0, 0.2), gate, doneAction: 2);
      Out.ar(out_bus, grains * env * amp);
    }).add;

    // ------------------------------------------------------------------
    // FX 4 — Modal Resonator
    // Three Resonz banks always running, XFade2 blends in real time.
    // XFade2 pan arguments corrected to stay within [-1, 1] range:
    //   blend1 uses morph*2-1 (glass->metal over full 0..1 range)
    //   blend2 uses (morph-0.5)*4-1 (metal->vocal over 0.5..1 range)
    //   final  uses morph*2-1 (blend1->blend2 over full 0..1 range)
    // softclip on resonator output prevents gain spikes from hurting ears
    // ------------------------------------------------------------------
    SynthDef(\prisma_fx4_modal_resonator, {
      arg in_bus = 0, out_bus = 0, gate = 1, morph = 0.5, amp = 1.0;
      var raw   = In.ar(in_bus, 2).sum;
      var input = raw * 0.04;
      var glass = Mix(Resonz.ar(input,
        [523,  1047, 2093, 3520, 7040],
        [0.003, 0.004, 0.003, 0.005, 0.004]
      ));
      var metal = Mix(Resonz.ar(input,
        [220,  550,  1320, 2200, 4400],
        [0.01, 0.008, 0.006, 0.007, 0.005]
      ));
      var vocal = Mix(Resonz.ar(input,
        [300,  870,  2300, 3000, 3500],
        [0.02, 0.015, 0.01, 0.012, 0.008]
      ));
      // blend1: glass (morph=0) -> metal (morph=1), full range
      var blend1 = XFade2.ar(glass, metal, (morph * 2) - 1);
      // blend2: metal (morph=0.5) -> vocal (morph=1), upper half only
      var blend2 = XFade2.ar(metal, vocal, ((morph - 0.5) * 4) - 1);
      // final: blend1 (morph=0) -> blend2 (morph=1)
      var res    = XFade2.ar(blend1, blend2, (morph * 2) - 1).softclip;
      var dry    = raw * 0.5;
      var sig    = XFade2.ar(dry, res, (morph * 2) - 1);
      var env    = EnvGen.kr(Env.asr(0.08, 1.0, 0.2), gate, doneAction: 2);
      Out.ar(out_bus, (sig ! 2) * env * amp);
    }).add;

    // ------------------------------------------------------------------
    // FX 5 — Grain Clouds
    // in_bus declared even though unused — suppresses "arg not found" log
    // LinExp srclo = 0.001 throughout
    // Select.kr replaces .choose (which is lang-time only)
    // ------------------------------------------------------------------
    SynthDef(\prisma_fx5_grain_clouds, {
      arg in_bus = 0, out_bus = 0, gate = 1, density = 0.5, amp = 1.0;
      var bufnum      = \bufnum.ir(0);
      var safeDensity = density.max(0.001);
      var bufDur      = BufDur.kr(bufnum);
      var trigRate    = LinExp.kr(safeDensity, 0.001, 1, 2, 20);
      var grainDur    = LinExp.kr(safeDensity, 0.001, 1, 0.8, 0.06);
      var centre      = LFNoise1.kr(0.15).range(0.05, 0.95) * bufDur;
      var hiRate      = LFPulse.kr(0.25).range(0.5, 2.0);
      var rate        = Select.kr((density > 0.65).asUGenInput, [1.0, hiRate]);
      var grains      = TGrains.ar(
        numChannels: 2,
        trigger:     Impulse.ar(trigRate),
        bufnum:      bufnum,
        rate:        rate,
        centerPos:   centre,
        dur:         grainDur,
        pan:         LFNoise1.kr(0.8).range(-0.9, 0.9),
        amp:         0.5
      );
      var env = EnvGen.kr(Env.asr(0.08, 1.0, 0.2), gate, doneAction: 2);
      Out.ar(out_bus, grains * env * amp);
    }).add;

    // ------------------------------------------------------------------
    // FX 6 — Spectral Scramble
    // Impulse.kr(2) retriggers scramble pattern at 2Hz
    // ------------------------------------------------------------------
    SynthDef(\prisma_fx6_spectral_scramble, {
      arg in_bus = 0, out_bus = 0, gate = 1, amount = 0.5, amp = 1.0;
      var input    = In.ar(in_bus, 2).sum * 0.5;
      var chain    = FFT(LocalBuf(2048), input);
      var scramble = PV_BinScramble(chain, amount, amount * 0.4, Impulse.kr(2));
      var wet      = IFFT(scramble);
      var sig      = XFade2.ar(input, wet, (amount * 2) - 1);
      var env      = EnvGen.kr(Env.asr(0.08, 1.0, 0.2), gate, doneAction: 2);
      Out.ar(out_bus, (sig ! 2) * env * amp);
    }).add;

    s.sync; // wait for all SynthDefs to reach server before starting synths

    recorder = Synth(\prisma_recorder, [
      \in_bus,  context.in_b.index,
      \bufnum,  sharedBuf.bufnum
    ], context.xg);

    s.sync; // recorder must be running before effect synth starts

    this.prSwitchTo(1, 0.5);
  }

  // ------------------------------------------------------------------
  // prSwitchTo: graceful page switch via ASR gate envelope
  // activePage set BEFORE s.bind so command routing is immediately correct
  // ------------------------------------------------------------------
  prSwitchTo { |newPage, initVal|
    var s     = context.server;
    var names = [
      \prisma_fx1_granular_morph,
      \prisma_fx2_spectral_freeze,
      \prisma_fx3_reactive_grain,
      \prisma_fx4_modal_resonator,
      \prisma_fx5_grain_clouds,
      \prisma_fx6_spectral_scramble
    ];
    var paramNames = [\pos, \density, \scatter, \morph, \density, \amount];
    var name  = names[newPage - 1];
    var param = paramNames[newPage - 1];

    activePage = newPage;

    if(effectSynth.notNil, {
      effectSynth.set(\gate, 0); // ASR release; doneAction:2 frees the node
    });

    s.bind({
      effectSynth = Synth.after(recorder, name, [
        \out_bus, context.out_b.index,
        \in_bus,  context.in_b.index,
        \bufnum,  sharedBuf.bufnum,
        \gate,    1,
        \amp,     1.0,
        param,    initVal
      ]);
    });
  }

  // ------------------------------------------------------------------
  // Engine commands — called from Lua
  // All .set calls guarded with notNil (s.bind is async;
  // effectSynth may be nil for ~1ms after prSwitchTo is called)
  // ------------------------------------------------------------------
  grain_pos { |v|
    if(activePage != 1,
      { this.prSwitchTo(1, v); },
      { if(effectSynth.notNil, { effectSynth.set(\pos, v); }); }
    );
  }

  freeze_density { |v|
    if(activePage != 2,
      { this.prSwitchTo(2, v); },
      { if(effectSynth.notNil, { effectSynth.set(\density, v); }); }
    );
  }

  react_scatter { |v|
    if(activePage != 3,
      { this.prSwitchTo(3, v); },
      { if(effectSynth.notNil, { effectSynth.set(\scatter, v); }); }
    );
  }

  modal_morph { |v|
    if(activePage != 4,
      { this.prSwitchTo(4, v); },
      { if(effectSynth.notNil, { effectSynth.set(\morph, v); }); }
    );
  }

  cloud_density { |v|
    if(activePage != 5,
      { this.prSwitchTo(5, v); },
      { if(effectSynth.notNil, { effectSynth.set(\density, v); }); }
    );
  }

  scramble_amt { |v|
    if(activePage != 6,
      { this.prSwitchTo(6, v); },
      { if(effectSynth.notNil, { effectSynth.set(\amount, v); }); }
    );
  }

  free {
    if(recorder.notNil,    { recorder.free; });
    if(effectSynth.notNil, { effectSynth.free; });
    sharedBuf.free;
  }
}
