shader_type canvas_item;

// fpv_osd layer. It is drawn just under the game's post-process rect,
// which shows each screen point p the screen content at fisheye(p). A real OSD
// is added after the lens, so this layer undoes that bend: at each point q it
// finds the p with fisheye(p) = q and draws what belongs at p.

uniform sampler2D osd_tex : filter_nearest, repeat_disable;
uniform float fisheye_strength = 0.5;
uniform float fisheye_crop = 0.25;
uniform vec4 pic = vec4(0.0, 0.0, 1.0, 1.0);          // the visible picture, screen UV
uniform vec4 grid = vec4(0.04, 0.03, 0.96, 0.97);     // the 30x13 grid, picture UV
uniform float white = 0.94;
uniform float black = 0.03;

// The post-process's lens function, copied exactly - including its smoothstep
// with equal edges, which GPUs evaluate differently - so this layer bends the
// same way the post-process does on this machine.
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
	// fisheye() only scales the distance from the centre, so solve for that
	// distance: s = |q - 0.5| / (scale at s), a few rounds
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
	vec2 g = ((p - pic.xy) / (pic.zw - pic.xy) - grid.xy) / (grid.zw - grid.xy);
	float inside = step(0.0, g.x) * step(g.x, 1.0) * step(0.0, g.y) * step(g.y, 1.0);
	vec4 o = texture(osd_tex, clamp(g, vec2(0.0), vec2(1.0)));
	COLOR = vec4(vec3(mix(black, white, o.r)), o.a * inside);
}
