#version 460 core

// GLSL port of src/windfoil.wgsl (post "perf round 2" + simplification pass).
// Differences from the WGSL original are mechanical: storage buffers become
// RGBA32F data textures (texelFetch, so reads stay bit-exact), and the row
// table's bit-punned f32s (band area, ink hull) are stored as plain floats
// by the uploader, so no bitcast is needed here.
//
// WGSL select(f, t, cond) returns t when cond is true — every ported select
// below is written as `cond ? t : f`. Getting this backwards was the
// original port's curve-corruption bug; keep the order in mind when syncing.

const uint SORT_MIN = 4u; // MUST equal bandSortMin in bands.dart
const int CURVE_TEX_WIDTH = 1024;

// Below guardPx device pixels (whole glyph, both axes) coverage comes from
// the banded ink profile (profile_face) instead of the exact gather.
// Threshold is a flat varying from FrameInfo.guardPx (default 3.7).
const bool MINIFICATION_GUARD = true;

uniform sampler2D curvesTex;
uniform sampler2D rowsTex;

in vec2 v_rc;
in vec4 v_place;
in vec4 v_bbox;
in vec4 v_color;
in vec4 v_band;
flat in vec2 v_style;
flat in float v_guardPx;

out vec4 frag_color;

// Curve points are packed two vec2s per RGBA32F texel (see atlas.dart):
// even indices in .xy, odd in .zw.
vec2 loadCurveVec2(int idx) {
  int t = idx >> 1;
  vec4 texel = texelFetch(
      curvesTex, ivec2(t % CURVE_TEX_WIDTH, t / CURVE_TEX_WIDTH), 0);
  return (idx & 1) == 0 ? texel.xy : texel.zw;
}

// Row-band table, two texels per band (see atlas.dart):
//   texel[2b]   = (start, count, area, xMin)
//   texel[2b+1] = (xMax, 0, 0, 0)
vec4 loadRowMain(int bandIdx) {
  int idx = bandIdx * 2;
  return texelFetch(rowsTex, ivec2(idx % CURVE_TEX_WIDTH, idx / CURVE_TEX_WIDTH), 0);
}

float loadRowXMax(int bandIdx) {
  int idx = bandIdx * 2 + 1;
  return texelFetch(rowsTex, ivec2(idx % CURVE_TEX_WIDTH, idx / CURVE_TEX_WIDTH), 0).x;
}

// Period-2 triangle wave 1 − |1 − (t mod 2)|: folds signed winding to
// even-odd coverage, range [0, 1].
float tri_wave(float t) {
  float m = t - 2.0 * floor(t * 0.5);
  return 1.0 - abs(1.0 - m);
}

// Opt-in perceptual styling; (1, 1) leaves the exact coverage untouched.
float style_coverage(float cov, float gamma, float sharp) {
  if (gamma == 1.0 && sharp == 1.0) return cov;
  float g = pow(cov, gamma);
  float s;
  if (g < 0.5) {
    s = 0.5 * pow(2.0 * g, sharp);
  } else {
    s = 1.0 - 0.5 * pow(2.0 * (1.0 - g), sharp);
  }
  return clamp(s, 0.0, 1.0);
}

// Straight-alpha color × coverage → premultiplied RGBA.
vec4 shade(vec4 color, float cov) {
  float a = color.a * cov;
  return vec4(color.rgb * a, a);
}

// Shared fragment tail: fold the pixel-averaged winding by fill rule, shade.
vec4 fold_shade(float f, float fillRule, vec4 color) {
  float cov;
  if (fillRule > 0.5) {
    cov = tri_wave(f);              // even-odd
  } else {
    cov = clamp(abs(f), 0.0, 1.0);  // nonzero (saturating)
  }
  return shade(color, style_coverage(cov, v_style.x, v_style.y));
}

// Solve the monotone quadratic component A2·t² + A1·t + A0 = v on [0,1],
// saturating to the endpoints (a0 = value at t = 0, e1 = value at t = 1).
float mono_root(float a2, float a1, float a0, float e1, float v, bool rising) {
  if (rising) {
    if (a0 >= v) return 0.0;
    if (e1 <= v) return 1.0;
  } else {
    if (a0 <= v) return 0.0;
    if (e1 >= v) return 1.0;
  }
  float c = a0 - v;
  if (abs(a2) < 1.0e-12 * max(abs(a1), 1.0)) { // near-linear fallback
    return clamp(-c / a1, 0.0, 1.0);
  }
  float disc = max(a1 * a1 - 4.0 * a2 * c, 0.0);
  float sq = sqrt(disc);
  float qq = -0.5 * (a1 + (a1 >= 0.0 ? sq : -sq)); // numerically stable
  float r1 = qq / a2;
  float r2 = qq != 0.0 ? c / qq : 0.0;
  // The derivative at r1 is −sign(a1)·sq, so the branch pick is a sign test.
  float t = ((a1 < 0.0) == rising) ? r1 : r2;
  return clamp(t, 0.0, 1.0);
}

// The INSIDE zone's exact integral of (x(t)+hx)·y′(t) over [ta,tb]: midpoint
// rule on a symmetric interval, exact for this cubic integrand.
float integrate_inside(vec2 a2, vec2 a1, float x0, float ta, float tb, float hx) {
  if (tb <= ta) return 0.0;
  float tm = 0.5 * (ta + tb);
  float d = 0.5 * (tb - ta);
  float x_mid = (a2.x * tm + a1.x) * tm + x0 + hx;
  vec2 dmid = 2.0 * a2 * tm + a1; // (x′, y′) at the midpoint
  return 2.0 * d * x_mid * dmid.y +
      (2.0 * d * d * d / 3.0) * (a2.x * dmid.y + 2.0 * a2.y * dmid.x);
}

// One xy-monotone piece's contribution over the y-window [lo, hi]: integrate
// clamp(x(t), −hx, hx) + hx via LEFT / INSIDE / RIGHT zones.
float integrate_piece(vec2 q1, vec2 q2, vec2 q3, float lo, float hi, float hx) {
  vec2 a2 = q1 - 2.0 * q2 + q3;
  vec2 a1 = 2.0 * (q2 - q1);
  bool y_rising = q3.y >= q1.y;
  float t_lo = mono_root(a2.y, a1.y, q1.y, q3.y, y_rising ? lo : hi, y_rising);
  float t_hi = mono_root(a2.y, a1.y, q1.y, q3.y, y_rising ? hi : lo, y_rising);
  if (t_hi <= t_lo) return 0.0;
  bool x_rising = q3.x >= q1.x;
  float t_left = clamp(mono_root(a2.x, a1.x, q1.x, q3.x, -hx, x_rising), t_lo, t_hi);
  float t_right = clamp(mono_root(a2.x, a1.x, q1.x, q3.x, hx, x_rising), t_lo, t_hi);
  // Zones in sweep order: x rising ⇒ LEFT · INSIDE · RIGHT; mirrored if not.
  float t1 = x_rising ? t_left : t_right;
  float t2 = max(x_rising ? t_right : t_left, t1);
  float acc = integrate_inside(a2, a1, q1.x, t1, t2, hx);
  float ra = x_rising ? t2 : t_lo;
  float rb = x_rising ? t_hi : t1;
  if (rb > ra) {
    float tm = 0.5 * (ra + rb);
    acc += (rb - ra) * (2.0 * a2.y * tm + a1.y) * (2.0 * hx); // RIGHT: full width × Δy
  }
  return acc;
}

// A piece's y-span clipped to the window, as a difference of clamped
// ENDPOINTS so it telescopes over piece chains. Signed.
float clipped_dy(float y1, float y3, float wlo, float whi) {
  return clamp(y3, wlo, whi) - clamp(y1, wlo, whi);
}

// Accumulate one row band's pieces over the rc-relative y-window [wlo, whi].
float integrate_band(int start, int count, vec2 rc, float wlo, float whi, float sx) {
  float acc = 0.0;
  float hx = sx * 0.5;
  bool sorted = count > int(SORT_MIN);
  float coord_ulp = max(abs(rc.x), abs(rc.y)) * 1.2e-7;
  for (int i = 0; i < count; i++) {
    int base = (start + i) * 3;
    vec2 q1 = loadCurveVec2(base) - rc;
    vec2 q2 = loadCurveVec2(base + 1) - rc;
    vec2 q3 = loadCurveVec2(base + 2) - rc;
    float x_hull_max = max(q1.x, max(q2.x, q3.x));
    if (x_hull_max <= -hx) {            // fully LEFT of the box → no area
      if (sorted) break;
      continue;
    }
    float py_lo = min(q1.y, q3.y);      // piece y-span (endpoint-exact)
    float py_hi = max(q1.y, q3.y);
    float lo = max(wlo, py_lo);
    float hi = min(whi, py_hi);
    if (hi <= lo) continue;
    float x_hull_min = min(q1.x, min(q2.x, q3.x));
    if (x_hull_min >= hx) {             // fully RIGHT → full width × clipped Δy
      acc += sx * clipped_dy(q1.y, q3.y, wlo, whi);
      continue;
    }
    // f32-degenerate piece: midpoint-clamp form, exact to ~span².
    if (x_hull_max - x_hull_min + (py_hi - py_lo) <= coord_ulp * 16.0) {
      float xm = clamp((q1.x + q3.x) * 0.5, -hx, hx) + hx;
      acc += xm * clipped_dy(q1.y, q3.y, wlo, whi);
      continue;
    }
    acc += integrate_piece(q1, q2, q3, lo, hi, hx);
  }
  return acc;
}

// Band index for a y-offset from the band origin — same mapping bands.dart
// files with.
int band_index(float dy, float invH, int R) {
  return int(clamp(floor(dy * invH), 0.0, float(R) - 1.0));
}

// Band ri's y-range relative to `base`. R ≤ 64, so float(ri) + 1.0 is exact.
vec2 band_edges(float base, int ri, float invH) {
  float r = float(ri);
  return vec2(base + r / invH, base + (r + 1.0) / invH);
}

// Length of the overlap of [a0, a1] and [b0, b1] (0 when disjoint).
float overlap1d(float a0, float a1, float b0, float b1) {
  return max(min(a1, b1) - max(a0, b0), 0.0);
}

// One glyph's winding integral over the pixel box (rc ± s/2), gathered
// through the row bands its y-slab touches. Windows stay rc-RELATIVE for
// deep-zoom stability and tile exactly across bands.
float integrate_face(vec4 band, vec2 rc, vec2 s) {
  int rowBase = int(band.x + 0.5);
  int R = int(band.y + 0.5);
  float invH = band.w;
  float sy2 = s.y * 0.5;
  float dy0 = band.z - rc.y; // band origin y0, relative to the pixel center
  int ri0 = 0;
  int ri1 = 0;
  if (invH > 0.0) { // invH > 0 only for multi-band glyphs
    ri0 = band_index(-dy0 - sy2, invH, R);
    ri1 = band_index(-dy0 + sy2, invH, R);
  }
  float f_int = 0.0;
  for (int ri = ri0; ri <= ri1; ri++) {
    float w_lo = -sy2;
    float w_hi = sy2;
    if (invH > 0.0) {
      vec2 e = band_edges(dy0, ri, invH);
      w_lo = max(w_lo, e.x);
      w_hi = min(w_hi, e.y);
    }
    if (w_hi <= w_lo) continue;
    vec4 row = loadRowMain(rowBase + ri);
    f_int += integrate_band(int(row.x + 0.5), int(row.y + 0.5), rc, w_lo, w_hi, s.x);
  }
  return f_int;
}

// The minification guard's twin of integrate_face: the same ∫∫_box w dA,
// approximated from the precomputed banded ink profile — each band's strip
// integral × the pixel's y-share of the strip × its x-share of the band's
// ink hull. A few table taps, no curve reads.
float profile_face(vec4 band, vec4 bbox, vec2 rc, vec2 s) {
  vec2 pixLo = rc - s * 0.5;
  vec2 pixHi = rc + s * 0.5;
  if (overlap1d(pixLo.x, pixHi.x, bbox.x, bbox.z) <= 0.0) return 0.0;
  int rowBase = int(band.x + 0.5);
  int R = int(band.y + 0.5);
  // header invH is 0 for a single band — the profile wants the real value
  float invH = band.w == 0.0 ? 1.0 / max(bbox.w - bbox.y, 1.0e-30) : band.w;
  float y0 = band.z;
  int ri0 = 0;
  int ri1 = 0;
  if (R > 1) {
    ri0 = band_index(pixLo.y - y0, invH, R);
    ri1 = band_index(pixHi.y - y0, invH, R);
  }
  float ink = 0.0;
  for (int ri = ri0; ri <= ri1; ri++) {
    vec4 row = loadRowMain(rowBase + ri); // (start, count, area, xMin)
    vec2 e = band_edges(y0, ri, invH);
    float ov = overlap1d(pixLo.y, pixHi.y, e.x, e.y);
    float hull0 = row.w;
    float hull1 = loadRowXMax(rowBase + ri);
    float fx = overlap1d(pixLo.x, pixHi.x, hull0, hull1) / max(hull1 - hull0, 1.0e-30);
    ink += row.z * (ov * invH) * fx;
  }
  return ink;
}

void main() {
  vec2 rc = v_rc;
  // units_per_pixel from the screen-space gradients.
  vec2 s = max(fwidth(rc), vec2(1.0e-9));

  vec2 glyphSize = v_bbox.zw - v_bbox.xy;
  if (MINIFICATION_GUARD &&
      s.x * v_guardPx >= glyphSize.x &&
      s.y * v_guardPx >= glyphSize.y) {
    frag_color = fold_shade(
        profile_face(v_band, v_bbox, rc, s) / (s.x * s.y), v_place.w, v_color);
    return;
  }
  frag_color = fold_shade(
      integrate_face(v_band, rc, s) / (s.x * s.y), v_place.w, v_color);
}
