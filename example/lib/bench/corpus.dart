// Benchmark corpora: text inputs shared by every tier so gputext and
// RichText passes always measure identical content.
//
// The .txt files are copies of /pretext/corpora — the TS engine's benchmark
// inputs — so cross-port numbers stay comparable. The synthetic stress text
// is a Dart port of buildLongBreakableStressText in pretext/pages/benchmark.ts.

import 'package:flutter/services.dart' show rootBundle;

class BenchCorpus {
  BenchCorpus({
    required this.gatsby,
    required this.zhZhufu,
    required this.mixedApp,
  });

  /// English long-form prose (en-gatsby-opening.txt, ~279 KB).
  final String gatsby;

  /// Chinese prose (zh-zhufu.txt) — per-ideograph break opportunities.
  final String zhZhufu;

  /// Mixed app text (emoji ZWJ runs, CJK, URLs, quotes) — the hybrid canary.
  final String mixedApp;

  /// Paragraphs of the Gatsby corpus (blank-line separated, non-empty).
  late final List<String> gatsbyParagraphs = gatsby
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.replaceAll('\n', ' ').trim())
      .where((p) => p.isNotEmpty)
      .toList();

  /// Lines of the mixed-app canary (each line is one product-shaped text).
  late final List<String> mixedAppLines = mixedApp
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  /// `count` comment-length texts cycled from Gatsby sentences and mixed-app
  /// lines — the analog of pretext's 500-text shared corpus batch. Each text
  /// gets a distinct ordinal prefix so prepared-paragraph cache keys never
  /// collide between "unique texts" scenarios.
  List<String> commentTexts(int count, {bool unique = false}) {
    final sentences = <String>[];
    for (final p in gatsbyParagraphs) {
      for (final s in p.split(RegExp(r'(?<=[.!?]) '))) {
        final t = s.trim();
        if (t.length > 20 && t.length < 400) sentences.add(t);
      }
      if (sentences.length >= count) break;
    }
    if (sentences.isEmpty) sentences.add(gatsby.substring(0, 200));
    return [
      for (var i = 0; i < count; i++)
        unique
            ? '¶$i ${sentences[i % sentences.length]}'
            : sentences[i % sentences.length],
    ];
  }

  static Future<BenchCorpus> load() async => BenchCorpus(
    gatsby: await rootBundle.loadString('assets/bench/en-gatsby-opening.txt'),
    zhZhufu: await rootBundle.loadString('assets/bench/zh-zhufu.txt'),
    mixedApp: await rootBundle.loadString('assets/bench/mixed-app-text.txt'),
  );
}

/// Dart port of pretext/pages/benchmark.ts buildLongBreakableStressText:
/// URLs with queries, giant camel-case cache keys, NBSP-glued metric runs,
/// time windows, and :: module paths — long-breakable-run measurement stress.
String buildLongBreakableStressText(int repeatCount) {
  final parts = <String>[];
  for (var i = 0; i < repeatCount; i++) {
    final startHour = (i % 24).toString().padLeft(2, '0');
    final endHour = ((i + 5) % 24).toString().padLeft(2, '0');
    final minute = ((i * 7) % 60).toString().padLeft(2, '0');
    final second = ((i * 11) % 60).toString().padLeft(2, '0');
    parts.addAll([
      'https://bench.example.com/releases/2026/04/$i/artifact-alpha-beta-'
          'gamma-delta-epsilon-${i.toRadixString(36)}?build=${1200 + i}'
          '&cursor=sha${(0xabcde + i).toRadixString(16)}&channel=stable',
      'cacheKey_v${i}_AlphaBetaGammaDeltaEpsilonZetaEtaThetaIotaKappaLambda'
          'MuNuXiOmicronPiRhoSigmaTauUpsilonPhiChiPsiOmega',
      'metrics pipeline phase ${i % 17} snapshot'
          ' ${(i * 13) % 97}',
      'window:$startHour:$minute-$endHour:$second',
      'module::worker::queue::flush::retry::recover::ship::$i',
    ]);
  }
  return parts.join(' ');
}
