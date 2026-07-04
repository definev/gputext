#version 460 core

uniform FrameInfo {
  vec2 res;
  vec2 style;
  vec4 cam;
} frame_info;

in vec2 corner;
in vec4 place;
in vec4 bbox;
in vec4 color;
in vec4 band;

out vec2 v_rc;
out vec4 v_place;
out vec4 v_bbox;
out vec4 v_color;
out vec4 v_band;

void main() {
  float unitsToPx = place.z;
  vec2 camScale = frame_info.cam.xy;
  float pad = 2.0 / (unitsToPx * max(camScale.x, 1.0e-6));
  vec2 lo = bbox.xy - vec2(pad);
  vec2 hi = bbox.zw + vec2(pad);
  vec2 em = mix(lo, hi, corner);
  vec2 worldPx = place.xy + em * unitsToPx;
  vec2 devicePx = worldPx * camScale + frame_info.cam.zw;
  vec2 clip = vec2(
    devicePx.x / frame_info.res.x * 2.0 - 1.0,
    1.0 - devicePx.y / frame_info.res.y * 2.0);
  gl_Position = vec4(clip, 0.0, 1.0);
  v_rc = em;
  v_place = place;
  v_bbox = bbox;
  v_color = color;
  v_band = band;
}
