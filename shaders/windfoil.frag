#version 460 core

const uint SORT_MIN = 8u;
const bool MINIFICATION_GUARD = true;
const float INK_AVERAGE = 0.42;
const int CURVE_TEX_WIDTH = 1024;

uniform sampler2D curvesTex;
uniform sampler2D rowsTex;

in vec2 v_rc;
in vec4 v_place;
in vec4 v_bbox;
in vec4 v_color;
in vec4 v_band;

out vec4 frag_color;

float tri_wave(float t) {
  float m = t - 2.0 * floor(t * 0.5);
  return 1.0 - abs(1.0 - m);
}

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

float qd(float a2, float a1, float t) {
  return 2.0 * a2 * t + a1;
}

vec2 loadCurveVec2(int idx) {
  int x = idx % CURVE_TEX_WIDTH;
  int y = idx / CURVE_TEX_WIDTH;
  return texelFetch(curvesTex, ivec2(x, y), 0).xy;
}

ivec2 loadRowBand(int bandIdx) {
  int x = bandIdx % CURVE_TEX_WIDTH;
  int y = bandIdx / CURVE_TEX_WIDTH;
  vec4 r = texelFetch(rowsTex, ivec2(x, y), 0);
  return ivec2(int(r.x + 0.5), int(r.y + 0.5));
}

float mono_root(float a2, float a1, float a0, float e1, float v, bool rising) {
  if (rising) {
    if (a0 >= v) return 0.0;
    if (e1 <= v) return 1.0;
  } else {
    if (a0 <= v) return 0.0;
    if (e1 >= v) return 1.0;
  }
  float c = a0 - v;
  if (abs(a2) < 1.0e-12 * max(abs(a1), 1.0)) {
    return clamp(-c / a1, 0.0, 1.0);
  }
  float disc = max(a1 * a1 - 4.0 * a2 * c, 0.0);
  float sq = sqrt(disc);
  float qq = -0.5 * (a1 + (a1 >= 0.0 ? sq : -sq));
  float r1 = qq / a2;
  float r2 = qq != 0.0 ? c / qq : 0.0;
  float d1 = qd(a2, a1, r1);
  float want = rising ? 1.0 : -1.0;
  float t = (d1 * want >= 0.0) ? r1 : r2;
  return clamp(t, 0.0, 1.0);
}

float integrate_inside(vec2 a2, vec2 a1, vec2 q1, float ta, float tb, float hx) {
  if (tb <= ta) return 0.0;
  float tm = 0.5 * (ta + tb);
  float d = 0.5 * (tb - ta);
  float x_mid = (a2.x * tm + a1.x) * tm + q1.x + hx;
  float xp = qd(a2.x, a1.x, tm);
  float yp = qd(a2.y, a1.y, tm);
  return 2.0 * d * x_mid * yp +
      (2.0 * d * d * d / 3.0) * (a2.x * yp + 2.0 * a2.y * xp);
}

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
  float t1 = x_rising ? t_left : t_right;
  float t2 = max(x_rising ? t_right : t_left, t1);
  float acc = integrate_inside(a2, a1, q1, t1, t2, hx);
  float ra = x_rising ? t2 : t_lo;
  float rb = x_rising ? t_hi : t1;
  if (rb > ra) {
    float tm = 0.5 * (ra + rb);
    acc += (rb - ra) * qd(a2.y, a1.y, tm) * (2.0 * hx);
  }
  return acc;
}

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
    if (x_hull_max <= -hx) {
      if (sorted) break;
      continue;
    }
    float lo = max(wlo, min(q1.y, q3.y));
    float hi = min(whi, max(q1.y, q3.y));
    if (hi <= lo) continue;
    float x_hull_min = min(q1.x, min(q2.x, q3.x));
    if (x_hull_min >= hx) {
      acc += sx * (clamp(q3.y, wlo, whi) - clamp(q1.y, wlo, whi));
      continue;
    }
    if (x_hull_max - x_hull_min + (max(q1.y, q3.y) - min(q1.y, q3.y)) <= coord_ulp * 16.0) {
      float xm = clamp((q1.x + q3.x) * 0.5, -hx, hx) + hx;
      acc += xm * (clamp(q3.y, wlo, whi) - clamp(q1.y, wlo, whi));
      continue;
    }
    acc += integrate_piece(q1, q2, q3, lo, hi, hx);
  }
  return acc;
}

float integrate_face(vec4 place, vec4 bbox, vec4 band, vec2 rc, vec2 s) {
  int rowBase = int(band.x + 0.5);
  int R = int(band.y + 0.5);
  float invH = band.w;
  float sy2 = s.y * 0.5;
  float dy0 = band.z - rc.y;
  int ri0 = 0;
  int ri1 = 0;
  if (invH > 0.0 && R > 1) {
    ri0 = int(clamp(floor((-dy0 - sy2) * invH), 0.0, float(R) - 1.0));
    ri1 = int(clamp(floor((-dy0 + sy2) * invH), 0.0, float(R) - 1.0));
  }
  float f_int = 0.0;
  for (int ri = ri0; ri <= ri1; ri++) {
    float w_lo = -sy2;
    float w_hi = sy2;
    if (invH > 0.0) {
      w_lo = max(w_lo, dy0 + float(ri) / invH);
      w_hi = min(w_hi, dy0 + (float(ri) + 1.0) / invH);
    }
    if (w_hi <= w_lo) continue;
    int bandTableIdx = rowBase + ri;
    ivec2 row = loadRowBand(bandTableIdx);
    f_int += integrate_band(row.x, row.y, rc, w_lo, w_hi, s.x);
  }
  return f_int;
}

vec4 shade(vec4 color, float cov) {
  float a = color.a * cov;
  return vec4(color.rgb * a, a);
}

void main() {
  vec2 rc = v_rc;
  vec2 s = max(
    vec2(length(vec2(dFdx(rc.x), dFdy(rc.x))),
         length(vec2(dFdx(rc.y), dFdy(rc.y)))),
    vec2(1.0e-9));

  if (MINIFICATION_GUARD) {
    float gw = v_bbox.z - v_bbox.x;
    float gh = v_bbox.w - v_bbox.y;
    if (s.x >= gw && s.y >= gh) {
      vec2 pixLo = rc - s * 0.5;
      vec2 pixHi = rc + s * 0.5;
      vec2 ovLo = max(pixLo, v_bbox.xy);
      vec2 ovHi = min(pixHi, v_bbox.zw);
      vec2 ov = max(ovHi - ovLo, vec2(0.0));
      float cov = clamp(INK_AVERAGE * ov.x * ov.y / (s.x * s.y), 0.0, 1.0);
      frag_color = shade(v_color, cov);
      return;
    }
  }

  float f_cov = integrate_face(v_place, v_bbox, v_band, rc, s) / max(s.x * s.y, 1.0e-30);
  float cov;
  if (v_place.w > 0.5) {
    cov = clamp(tri_wave(f_cov), 0.0, 1.0);
  } else {
    cov = clamp(abs(f_cov), 0.0, 1.0);
  }
  // style uniforms are wired when the demo exposes gamma/sharp tuning.
  frag_color = shade(v_color, cov);
}
