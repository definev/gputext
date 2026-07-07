// Tier C — memory sampling.
//
// Two sources: process RSS (dart:io ProcessInfo, median of 3 samples 100 ms
// apart to ride out GC noise), and gputext-internal accounting collected by
// walking the live render tree for RenderGPUParagraph objects. The
// RichText pass reports RSS only — the engine's paragraph memory is opaque
// from Dart.

import 'dart:io';

import 'package:flutter/rendering.dart';

import '../src/engine/engine.dart';
import '../src/widgets/rich_text.dart';

Future<int> sampleRss() async {
  final samples = <int>[];
  for (var i = 0; i < 3; i++) {
    samples.add(ProcessInfo.currentRss);
    if (i < 2) await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  samples.sort();
  return samples[1];
}

class GPUTextMemorySnapshot {
  GPUTextMemorySnapshot({
    required this.atlasGpuBytes,
    required this.atlasCpuBytes,
    required this.atlasGlyphEntries,
    required this.imageBytes,
    required this.instanceBytes,
    required this.paragraphCount,
    required this.layoutCacheEntries,
  });

  /// Curves (RGBA32F) + rows (Uint32) as uploaded: 4 bytes per element.
  final int atlasGpuBytes;

  /// The CPU-side growable lists backing the atlas (8 bytes per element).
  final int atlasCpuBytes;

  final int atlasGlyphEntries;

  /// Σ w*h*4 over every live paragraph's cached glyph image.
  final int imageBytes;

  /// Σ emitted instance-buffer bytes (64 per glyph).
  final int instanceBytes;

  final int paragraphCount;
  final int layoutCacheEntries;

  Map<String, Object> toJson() => {
        'atlasGpuBytes': atlasGpuBytes,
        'atlasCpuBytes': atlasCpuBytes,
        'atlasGlyphEntries': atlasGlyphEntries,
        'imageBytes': imageBytes,
        'instanceBytes': instanceBytes,
        'paragraphCount': paragraphCount,
        'layoutCacheEntries': layoutCacheEntries,
      };
}

/// Walk the render tree under [root] and total gputext paragraph state.
GPUTextMemorySnapshot snapshotGPUText(RenderObject? root) {
  var imageBytes = 0;
  var instanceBytes = 0;
  var paragraphs = 0;
  void visit(RenderObject node) {
    if (node is RenderGPUParagraph) {
      paragraphs++;
      instanceBytes += node.debugInstanceBytes;
      final size = node.debugImageSize;
      if (size != null) imageBytes += size.$1 * size.$2 * 4;
    }
    node.visitChildren(visit);
  }

  if (root != null) visit(root);
  final atlas = GPUText.instance.atlas;
  return GPUTextMemorySnapshot(
    atlasGpuBytes: (atlas.curveFloatCount + atlas.rowCount) * 4,
    atlasCpuBytes: (atlas.curveFloatCount + atlas.rowCount) * 8,
    atlasGlyphEntries: atlas.glyphEntryCount,
    imageBytes: imageBytes,
    instanceBytes: instanceBytes,
    paragraphCount: paragraphs,
    layoutCacheEntries: GPUText.instance.debugLayoutCacheLength,
  );
}
