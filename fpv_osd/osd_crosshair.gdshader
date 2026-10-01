shader_type canvas_item;
render_mode blend_premul_alpha;

// fpv_osd's crosshair from a PNG (crosshair="image"): its own layer over the
// OSD's, just under the game's post-process rect, drawn at the screen's
// resolution in the PNG's own colours and see-through where it is. Like the
// OSD layer it undoes the post-process's lens bend: at each point q it finds
// the p with fisheye(p) = q and draws what belongs at p.

// premultiplied by its alpha (osd.gd), so its edges blend without fringes
uniform sampler2D xhair_tex : filter_linear_mipmap, repeat_disable;
uniform float fisheye_strength = 0.5;
uniform float fisheye_crop = 0.25;
uniform vec4 pic = vec4(0.0, 0.0, 1.0, 1.0);      // the visible picture, screen UV
uniform vec2 centre = vec2(0.5, 0.5);             // the crosshair's middle, picture UV
uniform vec2 half_size = vec2(0.03, 0.04);        // half its width and height, picture UV
uniform float opacity = 1.0;

// The post-process's lens function, as osd_overlay.gdshader has it.
vec2 fisheye(vec2 uv) {
	const vec2  center  = vec2(0.5, 0.5);
	const float radius  = 1.0;
	const float falloff = 0.0;
	vec2 dir = uv - center;
	float dist = length(dir);
	float r = dist / radius;
	if (r == 0.0) { return uv; }
	float influence;
	if (r >= 1.0) { influence = 0.0; }
	else { influence = 1.0 - smoothstep(1.0 - falloff, 1.0, r); }
	float r_dist = r * (1.0 + fisheye_strength * r * r);
	float new_dist = r_dist * radius;
	vec2 new_dir = normalize(dir) * new_dist;
	vec2 out_uv = center + mix(dir, new_dir, influence);
	return out_uv * (1.0 - fisheye_crop) + (fisheye_crop * 0.5);
}

void fragment() {
	vec2 dq = SCREEN_UV - 0.5;
	float lq = length(dq);
	vec2 u = lq > 0.000001 ? dq / lq : vec2(1.0, 0.0);
	float s = lq;
	for (int i = 0; i < 8; i++) {
		float ss = max(s, 0.0001);
		float m = length(fisheye(vec2(0.5) + u * ss) - vec2(0.5)) / ss;
		s = lq / max(m, 0.0001);
	}
	vec2 p = vec2(0.5) + u * s;
	vec2 pp = (p - pic.xy) / (pic.zw - pic.xy);
	vec2 t = (pp - centre) / (2.0 * max(half_size, vec2(0.00001))) + 0.5;
	float inside = step(0.0, t.x) * step(t.x, 1.0) * step(0.0, t.y) * step(t.y, 1.0);
	vec4 c = texture(xhair_tex, clamp(t, vec2(0.0), vec2(1.0)));
	COLOR = c * (opacity * inside);
}
