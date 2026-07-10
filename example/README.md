# gputext_example

Demo app for the [gputext](../packages/gputext) GPU vector text renderer.

## Run

```bash
cd example
fvm flutter run --enable-impeller --enable-flutter-gpu -d <device>
```

Open a specific demo with `GPUTEXT_DEMO` (`widgets`, `pretext`, `justify`, `gsf`, `vars`, `rtl`, `leaks`, `bench`).

## Memory leak tracking

### Widget tests (automated)

```bash
cd example
fvm flutter test test/leak_demo_test.dart
```

`test/flutter_test_config.dart` enables `leak_tracker_flutter_testing` for the whole example suite. `leak_demo_test.dart` mounts/unmounts demo pages and a `GPURichText` create/dispose loop.

### Running app (manual, debug)

```bash
cd example
fvm flutter run --enable-impeller --enable-flutter-gpu --debug \
  --dart-define=GPUTEXT_LEAK_TRACK=true \
  -d <device>
```

Or set `GPUTEXT_LEAK_TRACK=1` in the environment.

Then:

1. Open and close demos (Widgets, RTL, Pretext, …) several times.
2. Tap **Leak report** on the home overlay (amber button), or open
   `GPUTEXT_DEMO=leaks`.
3. Read the summary, per-object list, and YAML on the page (copy via the
   app bar). Console still gets the same dump.

Periodic warnings also print every few seconds while tracking is on.

Leak tracking is debug-only (`LeakTracking.start` is assert-gated). For profile, you would also need `--dart-define=flutter.memory_allocations=true`, but collection still requires a debug assert path — prefer debug for this workflow.
