// OpenType GSUB font features: single (type 1), multiple (type 2),
// alternate (type 3), and ligature (type 4) substitution, plus type 7
// extension wrappers. Contextual lookups (types 5/6/8) are skipped — the
// features that need them (calt chains, frac, ccmp decomposition) simply
// don't fire, degrading to the unsubstituted text.
//
// The rendering pipeline is character-keyed end to end, so substitution
// results that have no code point of their own (ligature glyphs, tabular
// figures, stylistic alternates) are round-tripped as plane-15 PUA proxy
// characters: applyFeatures() emits U+F0000+gid for any slot whose glyph no
// longer matches its source character, and _glyphId() resolves those back to
// glyph ids. Everything downstream (measurement, kerning, the shared atlas)
// treats a proxy like any other character of the same font.

part of 'font.dart';

/// Plane-15 Private Use Area; U+FFFFE/U+FFFFF are noncharacters, so glyph
/// ids that would land there (or beyond) are left unsubstituted.
const int _glyphProxyBase = 0xF0000;
const int _glyphProxyMax = 0xFFFFD;

class _ShapeSlot {
  _ShapeSlot(this.gid, this.rune);

  int gid; // -1 → not covered by this font's cmap (pass-through)
  int? rune; // original code point; null once merged/expanded away
}

class _Gsub {
  _Gsub(this.featureLookups, this.lookups);

  /// Feature tag → lookup indices, from the latn/DFLT default LangSys.
  final Map<String, List<int>> featureLookups;

  /// Indexed by lookup id; null → unsupported lookup type.
  final List<_GsubLookup?> lookups;

  static _Gsub parse(ByteData d, int off) {
    final scriptListOff = off + d.getUint16(off + 4, Endian.big);
    final featureListOff = off + d.getUint16(off + 6, Endian.big);
    final lookupListOff = off + d.getUint16(off + 8, Endian.big);

    // Script selection: latn, else DFLT, else the first script; default
    // LangSys only (language-specific systems are a shaping-engine concern).
    final scriptCount = d.getUint16(scriptListOff, Endian.big);
    int? latn, dflt, first;
    for (var i = 0; i < scriptCount; i++) {
      final ro = scriptListOff + 2 + i * 6;
      final so = scriptListOff + d.getUint16(ro + 4, Endian.big);
      first ??= so;
      final tag = _tag4(d, ro);
      if (tag == 'latn') latn = so;
      if (tag == 'DFLT') dflt = so;
    }
    final script = latn ?? dflt ?? first;

    final featureLookups = <String, List<int>>{};
    if (script != null) {
      final dls = d.getUint16(script, Endian.big);
      if (dls != 0) {
        final langSys = script + dls;
        final required = d.getUint16(langSys + 2, Endian.big);
        final featureCount = d.getUint16(langSys + 4, Endian.big);
        final indices = <int>[
          if (required != 0xFFFF) required,
          for (var i = 0; i < featureCount; i++)
            d.getUint16(langSys + 6 + i * 2, Endian.big),
        ];
        final totalFeatures = d.getUint16(featureListOff, Endian.big);
        for (final fi in indices) {
          if (fi >= totalFeatures) continue;
          final ro = featureListOff + 2 + fi * 6;
          final tag = _tag4(d, ro);
          final fo = featureListOff + d.getUint16(ro + 4, Endian.big);
          final lookupCount = d.getUint16(fo + 2, Endian.big);
          final list = featureLookups.putIfAbsent(tag, () => <int>[]);
          for (var j = 0; j < lookupCount; j++) {
            final li = d.getUint16(fo + 4 + j * 2, Endian.big);
            if (!list.contains(li)) list.add(li);
          }
        }
      }
    }

    final lookupCount = d.getUint16(lookupListOff, Endian.big);
    final lookups = List<_GsubLookup?>.filled(lookupCount, null);
    for (var li = 0; li < lookupCount; li++) {
      final lo =
          lookupListOff + d.getUint16(lookupListOff + 2 + li * 2, Endian.big);
      final type = d.getUint16(lo, Endian.big);
      final subCount = d.getUint16(lo + 4, Endian.big);
      final subs = <_GsubSubtable>[];
      for (var si = 0; si < subCount; si++) {
        var so = lo + d.getUint16(lo + 6 + si * 2, Endian.big);
        var t = type;
        if (t == 7) {
          // ExtensionSubst: format(2) + extensionLookupType(2) + offset32.
          t = d.getUint16(so + 2, Endian.big);
          so += d.getUint32(so + 4, Endian.big);
        }
        final sub = _parseGsubSubtable(d, so, t);
        if (sub != null) subs.add(sub);
      }
      if (subs.isNotEmpty) lookups[li] = _GsubLookup(subs);
    }
    return _Gsub(featureLookups, lookups);
  }
}

class _GsubLookup {
  _GsubLookup(this.subs);

  final List<_GsubSubtable> subs;
}

sealed class _GsubSubtable {
  /// Try to substitute at `slots[i]`; returns how many RESULT slots to step
  /// over (0 = no match at this position).
  int applyAt(List<_ShapeSlot> slots, int i, int featureValue);
}

class _SingleSub extends _GsubSubtable {
  _SingleSub(this.coverage, this.delta, this.substitutes);

  final _Coverage coverage;
  final int? delta; // format 1
  final Uint16List? substitutes; // format 2

  @override
  int applyAt(List<_ShapeSlot> slots, int i, int featureValue) {
    final gid = slots[i].gid;
    final ci = coverage.indexOf(gid);
    if (ci == null) return 0;
    final d = delta;
    int out;
    if (d != null) {
      out = (gid + d) & 0xFFFF;
    } else {
      if (ci >= substitutes!.length) return 0;
      out = substitutes![ci];
    }
    slots[i].gid = out;
    return 1;
  }
}

class _MultipleSub extends _GsubSubtable {
  _MultipleSub(this.coverage, this.sequences);

  final _Coverage coverage;
  final List<Uint16List> sequences;

  @override
  int applyAt(List<_ShapeSlot> slots, int i, int featureValue) {
    final ci = coverage.indexOf(slots[i].gid);
    if (ci == null || ci >= sequences.length) return 0;
    final seq = sequences[ci];
    if (seq.isEmpty) return 0; // glyph deletion unsupported
    if (seq.length == 1) {
      slots[i].gid = seq[0];
      return 1;
    }
    final rune = slots[i].rune;
    slots.replaceRange(i, i + 1, [
      for (var k = 0; k < seq.length; k++)
        _ShapeSlot(seq[k], k == 0 ? rune : null),
    ]);
    return seq.length;
  }
}

class _AlternateSub extends _GsubSubtable {
  _AlternateSub(this.coverage, this.alternates);

  final _Coverage coverage;
  final List<Uint16List> alternates;

  @override
  int applyAt(List<_ShapeSlot> slots, int i, int featureValue) {
    final ci = coverage.indexOf(slots[i].gid);
    if (ci == null || ci >= alternates.length) return 0;
    final alts = alternates[ci];
    if (alts.isEmpty) return 0;
    // CSS-style: the feature value picks the alternate, 1-based.
    slots[i].gid = alts[(featureValue - 1).clamp(0, alts.length - 1)];
    return 1;
  }
}

class _LigatureSub extends _GsubSubtable {
  _LigatureSub(this.coverage, this.ligatureSets);

  final _Coverage coverage;

  /// Per first-glyph coverage index: (ligature glyph, trailing components).
  final List<List<(int, Uint16List)>> ligatureSets;

  @override
  int applyAt(List<_ShapeSlot> slots, int i, int featureValue) {
    final ci = coverage.indexOf(slots[i].gid);
    if (ci == null || ci >= ligatureSets.length) return 0;
    outer:
    for (final (lig, components) in ligatureSets[ci]) {
      if (i + 1 + components.length > slots.length) continue;
      for (var k = 0; k < components.length; k++) {
        if (slots[i + 1 + k].gid != components[k]) continue outer;
      }
      slots[i]
        ..gid = lig
        ..rune = null; // multi-source: no single origin code point
      slots.removeRange(i + 1, i + 1 + components.length);
      return 1;
    }
    return 0;
  }
}

_GsubSubtable? _parseGsubSubtable(ByteData d, int off, int type) {
  switch (type) {
    case 1:
      final fmt = d.getUint16(off, Endian.big);
      final coverage =
          _Coverage.parse(d, off + d.getUint16(off + 2, Endian.big));
      if (fmt == 1) {
        return _SingleSub(coverage, d.getInt16(off + 4, Endian.big), null);
      }
      if (fmt == 2) {
        final count = d.getUint16(off + 4, Endian.big);
        final subs = Uint16List(count);
        for (var i = 0; i < count; i++) {
          subs[i] = d.getUint16(off + 6 + i * 2, Endian.big);
        }
        return _SingleSub(coverage, null, subs);
      }
      return null;
    case 2:
    case 3:
      // Multiple substitution and alternate sets share the same layout:
      // coverage + per-index offset to a (count, glyph ids) set.
      if (d.getUint16(off, Endian.big) != 1) return null;
      final coverage =
          _Coverage.parse(d, off + d.getUint16(off + 2, Endian.big));
      final setCount = d.getUint16(off + 4, Endian.big);
      final sets = <Uint16List>[];
      for (var i = 0; i < setCount; i++) {
        final so = off + d.getUint16(off + 6 + i * 2, Endian.big);
        final glyphCount = d.getUint16(so, Endian.big);
        final gids = Uint16List(glyphCount);
        for (var j = 0; j < glyphCount; j++) {
          gids[j] = d.getUint16(so + 2 + j * 2, Endian.big);
        }
        sets.add(gids);
      }
      return type == 2
          ? _MultipleSub(coverage, sets)
          : _AlternateSub(coverage, sets);
    case 4:
      if (d.getUint16(off, Endian.big) != 1) return null;
      final coverage =
          _Coverage.parse(d, off + d.getUint16(off + 2, Endian.big));
      final setCount = d.getUint16(off + 4, Endian.big);
      final sets = <List<(int, Uint16List)>>[];
      for (var i = 0; i < setCount; i++) {
        final so = off + d.getUint16(off + 6 + i * 2, Endian.big);
        final ligCount = d.getUint16(so, Endian.big);
        final ligs = <(int, Uint16List)>[];
        for (var j = 0; j < ligCount; j++) {
          final lo = so + d.getUint16(so + 2 + j * 2, Endian.big);
          final ligGlyph = d.getUint16(lo, Endian.big);
          final compCount = d.getUint16(lo + 2, Endian.big);
          final components = Uint16List(compCount > 0 ? compCount - 1 : 0);
          for (var k = 0; k < components.length; k++) {
            components[k] = d.getUint16(lo + 4 + k * 2, Endian.big);
          }
          ligs.add((ligGlyph, components));
        }
        sets.add(ligs);
      }
      return _LigatureSub(coverage, sets);
    default:
      return null; // contextual (5/6/8) — unsupported
  }
}

// ---------------------------------------------------------------------------
// Public feature API.

extension WindfoilFontFeatures on WindfoilFont {
  /// Apply GSUB substitution features to `text` and return pipeline text in
  /// which substituted glyphs appear as PUA proxy characters (see the file
  /// header). `features` follows TextStyle.fontFeatures semantics: value 0
  /// disables a feature, >= 1 enables it (and selects the alternate for
  /// aalt-style features). `defaultLigatures: false` drops the default-on
  /// liga/clig/calt set — the tracked-out-text rule — without affecting
  /// explicitly requested features.
  ///
  /// Fonts without a usable GSUB fall back to [applyBasicLigatures].
  String applyFeatures(
    String text, {
    Map<String, int> features = const {},
    bool defaultLigatures = true,
  }) {
    if (text.isEmpty) return text;
    final enabled = <String, int>{
      'ccmp': 1,
      'locl': 1,
      'rlig': 1,
      if (defaultLigatures) ...{'liga': 1, 'clig': 1, 'calt': 1},
    };
    features.forEach((tag, value) {
      if (value == 0) {
        enabled.remove(tag);
      } else {
        enabled[tag] = value;
      }
    });

    final gsub = _gsub;
    if (gsub == null) {
      return enabled.containsKey('liga')
          ? applyBasicLigatures(text, this)
          : text;
    }

    final chosen = <int, int>{}; // lookup index → feature value
    enabled.forEach((tag, value) {
      final lookupIndices = gsub.featureLookups[tag];
      if (lookupIndices == null) return;
      for (final li in lookupIndices) {
        chosen.putIfAbsent(li, () => value);
      }
    });
    if (chosen.isEmpty) return text;

    final slots = <_ShapeSlot>[
      for (final rune in text.runes) _ShapeSlot(_cmap[rune] ?? -1, rune),
    ];
    var changed = false;
    for (final li in chosen.keys.toList()..sort()) {
      final lookup = li < gsub.lookups.length ? gsub.lookups[li] : null;
      if (lookup == null) continue;
      final value = chosen[li]!;
      var i = 0;
      while (i < slots.length) {
        if (slots[i].gid < 0) {
          i++;
          continue;
        }
        var consumed = 0;
        for (final sub in lookup.subs) {
          consumed = sub.applyAt(slots, i, value);
          if (consumed > 0) break;
        }
        if (consumed > 0) {
          changed = true;
          i += consumed;
        } else {
          i++;
        }
      }
    }
    if (!changed) return text;

    final out = StringBuffer();
    for (final slot in slots) {
      final rune = slot.rune;
      if (rune != null && (slot.gid < 0 || _cmap[rune] == slot.gid)) {
        out.writeCharCode(rune); // unchanged → keep the original character
        continue;
      }
      final proxy = _glyphProxyBase + slot.gid;
      if (slot.gid >= 0 && proxy <= _glyphProxyMax) {
        out.writeCharCode(proxy);
      } else if (rune != null) {
        out.writeCharCode(rune); // out of proxy range → render unsubstituted
      }
    }
    return out.toString();
  }
}
