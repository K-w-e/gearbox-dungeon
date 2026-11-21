shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded;

uniform vec4 shield_color : source_color = vec4(0.22, 0.78, 1.0, 1.0);
uniform float shield_intensity : hint_range(0.0, 2.0) = 0.0;
uniform float pulse_speed : hint_range(0.0, 20.0) = 6.0;
uniform float hex_scale : hint_range(1.0, 100.0) = 28.0;
uniform float fresnel_power : hint_range(0.1, 8.0) = 2.2;

void fragment() {
	if (shield_intensity <= 0.001) {
		discard;
	}
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);
	vec2 uv_scaled = VERTEX.xy * hex_scale;
	float grid = abs(sin(uv_scaled.x) * cos(uv_scaled.y));
	grid = smoothstep(0.65, 0.98, grid);
	float wave_z = sin(VERTEX.z * 14.0 - TIME * pulse_speed) * 0.5 + 0.5;
	float energy = (fresnel * 0.75 + grid * 0.45 + wave_z * 0.35) * shield_intensity;
	ALBEDO = shield_color.rgb * energy * 2.2;
	ALPHA = clamp(energy * shield_color.a, 0.0, 0.95);
}
