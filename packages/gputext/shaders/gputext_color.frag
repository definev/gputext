#version 460 core

// Color-bitmap glyph fragment shader: sample the PREMULTIPLIED RGBA8 color
// atlas and scale by the per-instance tint, then emit straight into the
// coverage pipeline's premultiplied-alpha blend. The atlas is premultiplied on
// upload (so its mip chain is halo-free), and the tint is a scalar opacity
// replicated across all four channels — multiplying premultiplied RGBA by a
// scalar is the correct way to fade it.

uniform sampler2D colorAtlas;

in vec2 v_uv;
in vec4 v_tint;

out vec4 frag_color;

void main() {
  frag_color = texture(colorAtlas, v_uv) * v_tint; // both premultiplied-safe
}
