#version 460 core

// Color-bitmap glyph vertex shader (emoji from sbix / CBDT). Unlike the
// coverage path, the quad is already in world pixels — the emit layer converts
// the strike-pixel placement box to world px using the font size — so this
// shader only applies the camera and maps to clip space, then hands the atlas
// UVs to the fragment stage. FrameInfo is byte-identical to gputext.vert so the
// same per-frame uniform buffer binds to both pipelines.

uniform FrameInfo {
  vec2 res;
  vec2 style;
  vec4 cam;      // device px = world px * cam.xy + cam.zw
  float guardPx;
} frame_info;

in vec2 corner;  // unit quad 0..1
in vec4 rect;    // world-px quad: (x0, y0, x1, y1)
in vec4 uv;      // atlas UV rect: (u0, v0, u1, v1)
in vec4 tint;    // straight-alpha RGBA multiply

out vec2 v_uv;
out vec4 v_tint;

void main() {
  vec2 worldPx = mix(rect.xy, rect.zw, corner);
  vec2 devicePx = worldPx * frame_info.cam.xy + frame_info.cam.zw;
  vec2 clip = vec2(
    devicePx.x / frame_info.res.x * 2.0 - 1.0,
    1.0 - devicePx.y / frame_info.res.y * 2.0);
  gl_Position = vec4(clip, 0.0, 1.0);
  v_uv = mix(uv.xy, uv.zw, corner);
  v_tint = tint;
}
