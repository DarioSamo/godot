#[vertex]

#version 450

#VERSION_DEFINES

precision mediump float;

/* Include our forward mobile UBOs definitions etc. */
#include "scene_forward_mobile_inc.glsl"

#define SHADER_IS_SRGB false
#define SHADER_SPACE_FAR 0.0

/* INPUT ATTRIBS */

// Always contains vertex position in XYZ, can contain tangent angle in W.
layout(location = 0) in highp vec4 vertex_angle_attrib;

//only for pure render depth when normal is not used

#ifdef NORMAL_USED
// Contains Normal/Axis in RG, can contain tangent in BA.
layout(location = 1) in highp vec4 axis_tangent_attrib;
#endif

// Location 2 is unused.

#if defined(COLOR_USED)
layout(location = 3) in highp vec4 color_attrib;
#endif

#ifdef UV_USED
layout(location = 4) in highp vec2 uv_attrib;
#endif

#if defined(UV2_USED) || defined(USE_LIGHTMAP) || defined(MODE_RENDER_MATERIAL)
layout(location = 5) in highp vec2 uv2_attrib;
#endif // MODE_RENDER_MATERIAL

#if defined(CUSTOM0_USED)
layout(location = 6) in highp vec4 custom0_attrib;
#endif

#if defined(CUSTOM1_USED)
layout(location = 7) in highp vec4 custom1_attrib;
#endif

#if defined(CUSTOM2_USED)
layout(location = 8) in highp vec4 custom2_attrib;
#endif

#if defined(CUSTOM3_USED)
layout(location = 9) in highp vec4 custom3_attrib;
#endif

#if defined(BONES_USED) || defined(USE_PARTICLE_TRAILS)
layout(location = 10) in uvec4 bone_attrib;
#endif

#if defined(WEIGHTS_USED) || defined(USE_PARTICLE_TRAILS)
layout(location = 11) in highp vec4 weight_attrib;
#endif

highp vec3 oct_to_vec3(highp vec2 e) {
	highp vec3 v = vec3(e.xy, 1.0 - abs(e.x) - abs(e.y));
	highp float t = max(-v.z, 0.0);
	v.xy += t * -sign(v.xy);
	return normalize(v);
}

void axis_angle_to_tbn(highp vec3 axis, highp float angle, out highp vec3 tangent, out highp vec3 binormal, out highp vec3 normal) {
	highp float c = cos(angle);
	highp float s = sin(angle);
	highp vec3 omc_axis = (1.0 - c) * axis;
	highp vec3 s_axis = s * axis;
	tangent = omc_axis.xxx * axis + vec3(c, -s_axis.z, s_axis.y);
	binormal = omc_axis.yyy * axis + vec3(s_axis.z, c, -s_axis.x);
	normal = omc_axis.zzz * axis + vec3(-s_axis.y, s_axis.x, c);
}

/* Varyings */

layout(location = 0) out highp vec3 vertex_interp;

#ifdef NORMAL_USED
layout(location = 1) out vec3 normal_interp;
#endif

#if defined(COLOR_USED)
layout(location = 2) out vec4 color_interp;
#endif

#ifdef UV_USED
layout(location = 3) out vec2 uv_interp;
#endif

#if defined(UV2_USED) || defined(USE_LIGHTMAP)
layout(location = 4) out vec2 uv2_interp;
#endif

#if defined(TANGENT_USED) || defined(NORMAL_MAP_USED) || defined(LIGHT_ANISOTROPY_USED)
layout(location = 5) out vec3 tangent_interp;
layout(location = 6) out vec3 binormal_interp;
#endif
#if !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && defined(USE_VERTEX_LIGHTING)
layout(location = 7) out highp vec4 diffuse_light_interp;
layout(location = 8) out highp vec4 specular_light_interp;

#include "../scene_forward_vertex_lights_inc.glsl"
#endif // !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && defined(USE_VERTEX_LIGHTING)
#ifdef MATERIAL_UNIFORMS_USED
/* clang-format off */
layout(set = MATERIAL_UNIFORM_SET, binding = 0, std140) uniform MaterialUniforms {
#MATERIAL_UNIFORMS
} material;
/* clang-format on */
#endif

#ifdef MODE_DUAL_PARABOLOID

layout(location = 9) out highp float dp_clip;

#endif

#ifdef USE_MULTIVIEW
#ifdef has_VK_KHR_multiview
#define ViewIndex gl_ViewIndex
#else
// !BAS! This needs to become an input once we implement our fallback!
#define ViewIndex 0
#endif
highp vec3 multiview_uv(highp vec2 uv) {
	return vec3(uv, ViewIndex);
}
ivec3 multiview_uv(ivec2 uv) {
	return ivec3(uv, int(ViewIndex));
}
#else
// Set to zero, not supported in non stereo
#define ViewIndex 0
highp vec2 multiview_uv(highp vec2 uv) {
	return uv;
}
ivec2 multiview_uv(ivec2 uv) {
	return uv;
}
#endif //USE_MULTIVIEW

invariant gl_Position;

#GLOBALS

#define scene_data scene_data_block.data

#ifdef USE_DOUBLE_PRECISION
// Helper functions for emulating double precision when adding floats.
highp vec3 quick_two_sum(highp vec3 a, highp vec3 b, out highp vec3 out_p) {
	highp vec3 s = a + b;
	out_p = b - (s - a);
	return s;
}

highp vec3 two_sum(highp vec3 a, highp vec3 b, out highp vec3 out_p) {
	highp vec3 s = a + b;
	highp vec3 v = s - a;
	out_p = (a - (s - v)) + (b - v);
	return s;
}

highp vec3 double_add_vec3(highp vec3 base_a, highp vec3 prec_a, highp vec3 base_b, highp vec3 prec_b, out highp vec3 out_precision) {
	highp vec3 s, t, se, te;
	s = two_sum(base_a, base_b, se);
	t = two_sum(prec_a, prec_b, te);
	se += t;
	s = quick_two_sum(s, se, se);
	se += te;
	s = quick_two_sum(s, se, out_precision);
	return s;
}
#endif

uint multimesh_stride() {
	uint stride = sc_multimesh_format_2d() ? 2 : 3;
	stride += sc_multimesh_has_color() ? 1 : 0;
	stride += sc_multimesh_has_custom_data() ? 1 : 0;
	return stride;
}

void main() {
	highp vec4 instance_custom = vec4(0.0);
#if defined(COLOR_USED)
	color_interp = color_attrib;
#endif

	highp mat4 model_matrix = instances.data[draw_call.instance_index].transform;
	highp mat4 inv_view_matrix = scene_data.inv_view_matrix;

#ifdef USE_DOUBLE_PRECISION
	highp vec3 model_precision = vec3(model_matrix[0][3], model_matrix[1][3], model_matrix[2][3]);
	model_matrix[0][3] = 0.0;
	model_matrix[1][3] = 0.0;
	model_matrix[2][3] = 0.0;
	highp vec3 view_precision = vec3(inv_view_matrix[0][3], inv_view_matrix[1][3], inv_view_matrix[2][3]);
	inv_view_matrix[0][3] = 0.0;
	inv_view_matrix[1][3] = 0.0;
	inv_view_matrix[2][3] = 0.0;
#endif

	highp mat3 model_normal_matrix;
	if (bool(instances.data[draw_call.instance_index].flags & INSTANCE_FLAGS_NON_UNIFORM_SCALE)) {
		model_normal_matrix = transpose(inverse(mat3(model_matrix)));
	} else {
		model_normal_matrix = mat3(model_matrix);
	}

	highp mat4 matrix;
	highp mat4 read_model_matrix = model_matrix;

	if (sc_multimesh()) {
		//multimesh, instances are for it

#ifdef USE_PARTICLE_TRAILS
		uint trail_size = (instances.data[draw_call.instance_index].flags >> INSTANCE_FLAGS_PARTICLE_TRAIL_SHIFT) & INSTANCE_FLAGS_PARTICLE_TRAIL_MASK;
		uint stride = 3 + 1 + 1; //particles always uses this format

		uint offset = trail_size * stride * gl_InstanceIndex;

#ifdef COLOR_USED
		highp vec4 pcolor;
#endif
		{
			uint boffset = offset + bone_attrib.x * stride;
			matrix = mat4(transforms.data[boffset + 0], transforms.data[boffset + 1], transforms.data[boffset + 2], vec4(0.0, 0.0, 0.0, 1.0)) * weight_attrib.x;
#ifdef COLOR_USED
			pcolor = transforms.data[boffset + 3] * weight_attrib.x;
#endif
		}
		if (weight_attrib.y > 0.001) {
			uint boffset = offset + bone_attrib.y * stride;
			matrix += mat4(transforms.data[boffset + 0], transforms.data[boffset + 1], transforms.data[boffset + 2], vec4(0.0, 0.0, 0.0, 1.0)) * weight_attrib.y;
#ifdef COLOR_USED
			pcolor += transforms.data[boffset + 3] * weight_attrib.y;
#endif
		}
		if (weight_attrib.z > 0.001) {
			uint boffset = offset + bone_attrib.z * stride;
			matrix += mat4(transforms.data[boffset + 0], transforms.data[boffset + 1], transforms.data[boffset + 2], vec4(0.0, 0.0, 0.0, 1.0)) * weight_attrib.z;
#ifdef COLOR_USED
			pcolor += transforms.data[boffset + 3] * weight_attrib.z;
#endif
		}
		if (weight_attrib.w > 0.001) {
			uint boffset = offset + bone_attrib.w * stride;
			matrix += mat4(transforms.data[boffset + 0], transforms.data[boffset + 1], transforms.data[boffset + 2], vec4(0.0, 0.0, 0.0, 1.0)) * weight_attrib.w;
#ifdef COLOR_USED
			pcolor += transforms.data[boffset + 3] * weight_attrib.w;
#endif
		}

		instance_custom = transforms.data[offset + 4];

#ifdef COLOR_USED
		color_interp *= pcolor;
#endif

#else
		uint stride = multimesh_stride();
		uint offset = stride * gl_InstanceIndex;

		if (sc_multimesh_format_2d()) {
			matrix = mat4(transforms.data[offset + 0], transforms.data[offset + 1], vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
			offset += 2;
		} else {
			matrix = mat4(transforms.data[offset + 0], transforms.data[offset + 1], transforms.data[offset + 2], vec4(0.0, 0.0, 0.0, 1.0));
			offset += 3;
		}

		if (sc_multimesh_has_color()) {
#ifdef COLOR_USED
			color_interp *= transforms.data[offset];
#endif
			offset += 1;
		}

		if (sc_multimesh_has_custom_data()) {
			instance_custom = transforms.data[offset];
		}

#endif
		//transpose
		matrix = transpose(matrix);

#if !defined(USE_DOUBLE_PRECISION) || defined(SKIP_TRANSFORM_USED) || defined(VERTEX_WORLD_COORDS_USED) || defined(MODEL_MATRIX_USED)
		// Normally we can bake the multimesh transform into the model matrix, but when using double precision
		// we avoid baking it in so we can emulate high precision.
		read_model_matrix = model_matrix * matrix;
#if !defined(USE_DOUBLE_PRECISION) || defined(SKIP_TRANSFORM_USED) || defined(VERTEX_WORLD_COORDS_USED)
		model_matrix = read_model_matrix;
#endif // !defined(USE_DOUBLE_PRECISION) || defined(SKIP_TRANSFORM_USED) || defined(VERTEX_WORLD_COORDS_USED)
#endif // !defined(USE_DOUBLE_PRECISION) || defined(SKIP_TRANSFORM_USED) || defined(VERTEX_WORLD_COORDS_USED) || defined(MODEL_MATRIX_USED)
		model_normal_matrix = model_normal_matrix * mat3(matrix);
	}

	highp vec3 vertex = vertex_angle_attrib.xyz * instances.data[draw_call.instance_index].compressed_aabb_size_pad.xyz + instances.data[draw_call.instance_index].compressed_aabb_position_pad.xyz;
#ifdef NORMAL_USED
	highp vec3 normal = oct_to_vec3(axis_tangent_attrib.xy * 2.0 - 1.0);
#endif

#if defined(NORMAL_USED) || defined(TANGENT_USED) || defined(NORMAL_MAP_USED) || defined(LIGHT_ANISOTROPY_USED)

	highp vec3 binormal;
	highp float binormal_sign;
	highp vec3 tangent;
	if (axis_tangent_attrib.z > 0.0 || axis_tangent_attrib.w < 1.0) {
		// Uncompressed format.
		highp vec2 signed_tangent_attrib = axis_tangent_attrib.zw * 2.0 - 1.0;
		tangent = oct_to_vec3(vec2(signed_tangent_attrib.x, abs(signed_tangent_attrib.y) * 2.0 - 1.0));
		binormal_sign = sign(signed_tangent_attrib.y);
		binormal = normalize(cross(normal, tangent) * binormal_sign);
	} else {
		// Compressed format.
		highp float angle = vertex_angle_attrib.w;
		binormal_sign = angle > 0.5 ? 1.0 : -1.0; // 0.5 does not exist in UNORM16, so values are either greater or smaller.
		angle = abs(angle * 2.0 - 1.0) * M_PI; // 0.5 is basically zero, allowing to encode both signs reliably.
		highp vec3 axis = normal;
		axis_angle_to_tbn(axis, angle, tangent, binormal, normal);
		binormal *= binormal_sign;
	}
#endif

#ifdef UV_USED
	uv_interp = uv_attrib;
#endif

#if defined(UV2_USED) || defined(USE_LIGHTMAP)
	uv2_interp = uv2_attrib;
#endif

	highp vec4 uv_scale = instances.data[draw_call.instance_index].uv_scale;

	if (uv_scale != vec4(0.0)) { // Compression enabled
#ifdef UV_USED
		uv_interp = (uv_interp - 0.5) * uv_scale.xy;
#endif
#if defined(UV2_USED) || defined(USE_LIGHTMAP)
		uv2_interp = (uv2_interp - 0.5) * uv_scale.zw;
#endif
	}

#ifdef OVERRIDE_POSITION
	highp vec4 position = vec4(1.0);
#endif

#ifdef USE_MULTIVIEW
	highp mat4 projection_matrix = scene_data.projection_matrix_view[ViewIndex];
	highp mat4 inv_projection_matrix = scene_data.inv_projection_matrix_view[ViewIndex];
	highp vec3 eye_offset = scene_data.eye_offset[ViewIndex].xyz;
#else
	highp mat4 projection_matrix = scene_data.projection_matrix;
	highp mat4 inv_projection_matrix = scene_data.inv_projection_matrix;
	highp vec3 eye_offset = vec3(0.0, 0.0, 0.0);
#endif //USE_MULTIVIEW

//using world coordinates
#if !defined(SKIP_TRANSFORM_USED) && defined(VERTEX_WORLD_COORDS_USED)

	vertex = (model_matrix * vec4(vertex, 1.0)).xyz;

#ifdef NORMAL_USED
	normal = model_normal_matrix * normal;
#endif

#if defined(TANGENT_USED) || defined(NORMAL_MAP_USED) || defined(LIGHT_ANISOTROPY_USED)

	tangent = model_normal_matrix * tangent;
	binormal = model_normal_matrix * binormal;

#endif
#endif

	highp float roughness = 1.0;

	highp mat4 modelview = scene_data.view_matrix * model_matrix;
	highp mat3 modelview_normal = mat3(scene_data.view_matrix) * model_normal_matrix;
	highp mat4 read_view_matrix = scene_data.view_matrix;
	highp vec2 read_viewport_size = scene_data.viewport_size;

	{
#CODE : VERTEX
	}

// using local coordinates (default)
#if !defined(SKIP_TRANSFORM_USED) && !defined(VERTEX_WORLD_COORDS_USED)

#ifdef USE_DOUBLE_PRECISION
	// We separate the basis from the origin because the basis is fine with single point precision.
	// Then we combine the translations from the model matrix and the view matrix using emulated doubles.
	// We add the result to the vertex and ignore the final lost precision.
	highp vec3 model_origin = model_matrix[3].xyz;
	if (sc_multimesh()) {
		vertex = mat3(matrix) * vertex;
		model_origin = double_add_vec3(model_origin, model_precision, matrix[3].xyz, vec3(0.0), model_precision);
	}
	vertex = mat3(inv_view_matrix * modelview) * vertex;
	highp vec3 temp_precision;
	vertex += double_add_vec3(model_origin, model_precision, scene_data.inv_view_matrix[3].xyz, view_precision, temp_precision);
	vertex = mat3(scene_data.view_matrix) * vertex;
#else
	vertex = (modelview * vec4(vertex, 1.0)).xyz;
#endif
#ifdef NORMAL_USED
	normal = modelview_normal * normal;
#endif

#if defined(TANGENT_USED) || defined(NORMAL_MAP_USED) || defined(LIGHT_ANISOTROPY_USED)

	binormal = modelview_normal * binormal;
	tangent = modelview_normal * tangent;
#endif
#endif // !defined(SKIP_TRANSFORM_USED) && !defined(VERTEX_WORLD_COORDS_USED)

//using world coordinates
#if !defined(SKIP_TRANSFORM_USED) && defined(VERTEX_WORLD_COORDS_USED)

	vertex = (scene_data.view_matrix * vec4(vertex, 1.0)).xyz;
#ifdef NORMAL_USED
	normal = (scene_data.view_matrix * vec4(normal, 0.0)).xyz;
#endif

#if defined(TANGENT_USED) || defined(NORMAL_MAP_USED) || defined(LIGHT_ANISOTROPY_USED)
	binormal = (scene_data.view_matrix * vec4(binormal, 0.0)).xyz;
	tangent = (scene_data.view_matrix * vec4(tangent, 0.0)).xyz;
#endif
#endif

	vertex_interp = vertex;
#ifdef NORMAL_USED
	normal_interp = normal;
#endif

#if defined(TANGENT_USED) || defined(NORMAL_MAP_USED) || defined(LIGHT_ANISOTROPY_USED)
	tangent_interp = tangent;
	binormal_interp = binormal;
#endif

// VERTEX LIGHTING
#if !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && defined(USE_VERTEX_LIGHTING)
#ifdef USE_MULTIVIEW
	highp vec3 view = -normalize(vertex_interp - eye_offset);
#else
	highp vec3 view = -normalize(vertex_interp);
#endif

	diffuse_light_interp = vec4(0.0);
	specular_light_interp = vec4(0.0);

	uvec2 omni_light_indices = instances.data[draw_call.instance_index].omni_lights;
	for (uint i = 0; i < sc_omni_lights(); i++) {
		uint light_index = (i > 3) ? ((omni_light_indices.y >> ((i - 4) * 8)) & 0xFF) : ((omni_light_indices.x >> (i * 8)) & 0xFF);
		light_process_omni_vertex(light_index, vertex, view, normal, roughness, diffuse_light_interp.rgb, specular_light_interp.rgb);
	}

	uvec2 spot_light_indices = instances.data[draw_call.instance_index].spot_lights;
	for (uint i = 0; i < sc_spot_lights(); i++) {
		uint light_index = (i > 3) ? ((spot_light_indices.y >> ((i - 4) * 8)) & 0xFF) : ((spot_light_indices.x >> (i * 8)) & 0xFF);
		light_process_spot_vertex(light_index, vertex, view, normal, roughness, diffuse_light_interp.rgb, specular_light_interp.rgb);
	}

	if (sc_directional_lights() > 0) {
		// We process the first directional light separately as it may have shadows.
		highp vec3 directional_diffuse = vec3(0.0);
		highp vec3 directional_specular = vec3(0.0);

		for (uint i = 0; i < sc_directional_lights(); i++) {
			if (!bool(directional_lights.data[i].mask & instances.data[draw_call.instance_index].layer_mask)) {
				continue; // Not masked, skip.
			}

			if (directional_lights.data[i].bake_mode == LIGHT_BAKE_STATIC && bool(instances.data[draw_call.instance_index].flags & INSTANCE_FLAGS_USE_LIGHTMAP)) {
				continue; // Statically baked light and object uses lightmap, skip.
			}
			if (i == 0) {
				light_compute_vertex(normal, directional_lights.data[0].direction, view,
						directional_lights.data[0].color * directional_lights.data[0].energy,
						true, roughness,
						directional_diffuse,
						directional_specular);
			} else {
				light_compute_vertex(normal, directional_lights.data[i].direction, view,
						directional_lights.data[i].color * directional_lights.data[i].energy,
						true, roughness,
						diffuse_light_interp.rgb,
						specular_light_interp.rgb);
			}
		}

		// Calculate the contribution from the shadowed light so we can scale the shadows accordingly.
		highp float diff_avg = dot(diffuse_light_interp.rgb, vec3(0.33333));
		highp float diff_dir_avg = dot(directional_diffuse, vec3(0.33333));
		if (diff_avg > 0.0) {
			diffuse_light_interp.a = diff_dir_avg / (diff_avg + diff_dir_avg);
		} else {
			diffuse_light_interp.a = 1.0;
		}

		diffuse_light_interp.rgb += directional_diffuse;

		highp float spec_avg = dot(specular_light_interp.rgb, vec3(0.33333));
		highp float spec_dir_avg = dot(directional_specular, vec3(0.33333));
		if (spec_avg > 0.0) {
			specular_light_interp.a = spec_dir_avg / (spec_avg + spec_dir_avg);
		} else {
			specular_light_interp.a = 1.0;
		}

		specular_light_interp.rgb += directional_specular;
	}

#endif //!defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && defined(USE_VERTEX_LIGHTING)

#ifdef MODE_RENDER_DEPTH

#ifdef MODE_DUAL_PARABOLOID

	vertex_interp.z *= scene_data.dual_paraboloid_side;

	dp_clip = vertex_interp.z; //this attempts to avoid noise caused by objects sent to the other parabolloid side due to bias

	//for dual paraboloid shadow mapping, this is the fastest but least correct way, as it curves straight edges

	highp vec3 vtx = vertex_interp;
	highp float distance = length(vtx);
	vtx = normalize(vtx);
	vtx.xy /= 1.0 - vtx.z;
	vtx.z = (distance / scene_data.z_far);
	vtx.z = vtx.z * 2.0 - 1.0;
	vertex_interp = vtx;

#endif

#endif //MODE_RENDER_DEPTH

#ifdef OVERRIDE_POSITION
	gl_Position = position;
#else
	gl_Position = projection_matrix * vec4(vertex_interp, 1.0);
#endif // OVERRIDE_POSITION

#ifdef MODE_RENDER_DEPTH
	if (scene_data.pancake_shadows) {
		if (gl_Position.z >= 0.9999) {
			gl_Position.z = 0.9999;
		}
	}
#endif // MODE_RENDER_DEPTH
#ifdef MODE_RENDER_MATERIAL
	if (scene_data.material_uv2_mode) {
		gl_Position.xy = (uv2_attrib.xy + draw_call.uv_offset) * 2.0 - 1.0;
		gl_Position.z = 0.00001;
		gl_Position.w = 1.0;
	}
#endif // MODE_RENDER_MATERIAL
}

#[fragment]

#version 450

#VERSION_DEFINES

precision mediump float;

#define SHADER_IS_SRGB false
#define SHADER_SPACE_FAR 0.0

/* Include our forward mobile UBOs definitions etc. */
#include "scene_forward_mobile_inc.glsl"

/* Varyings */

layout(location = 0) in highp vec3 vertex_interp;

#ifdef USE_MULTIVIEW
#ifdef has_VK_KHR_multiview
#define ViewIndex gl_ViewIndex
#else
// !BAS! This needs to become an input once we implement our fallback!
#define ViewIndex 0
#endif
vec3 multiview_uv(vec2 uv) {
	return vec3(uv, ViewIndex);
}
ivec3 multiview_uv(ivec2 uv) {
	return ivec3(uv, int(ViewIndex));
}
#else
// Set to zero, not supported in non stereo
#define ViewIndex 0
vec2 multiview_uv(vec2 uv) {
	return uv;
}
ivec2 multiview_uv(ivec2 uv) {
	return uv;
}
#endif //USE_MULTIVIEW

//defines to keep compatibility with vertex

#ifdef USE_MULTIVIEW
#define projection_matrix scene_data.projection_matrix_view[ViewIndex]
#define inv_projection_matrix scene_data.inv_projection_matrix_view[ViewIndex]
#else
#define projection_matrix scene_data.projection_matrix
#define inv_projection_matrix scene_data.inv_projection_matrix
#endif

#if defined(ENABLE_SSS) && defined(ENABLE_TRANSMITTANCE)
//both required for transmittance to be enabled
#define LIGHT_TRANSMITTANCE_USED
#endif

#ifdef MATERIAL_UNIFORMS_USED
/* clang-format off */
layout(set = MATERIAL_UNIFORM_SET, binding = 0, std140) uniform MaterialUniforms {
#MATERIAL_UNIFORMS
} material;
/* clang-format on */
#endif

#GLOBALS

#include "../scene_forward_aa_inc.glsl"

#if !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) // && !defined(USE_VERTEX_LIGHTING)

// Default to SPECULAR_SCHLICK_GGX.
#if !defined(SPECULAR_DISABLED) && !defined(SPECULAR_SCHLICK_GGX) && !defined(SPECULAR_TOON)
#define SPECULAR_SCHLICK_GGX
#endif

#include "../scene_forward_lights_inc.glsl"

#endif //!defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && !defined(USE_VERTEX_LIGHTING)

#define scene_data scene_data_block.data

// Ubershader.

#ifdef UBERSHADER
#define ubershader_check_culling()                                                                                            \
	if ((uc_cull_mode() == POLYGON_CULL_BACK && !gl_FrontFacing) || (uc_cull_mode() == POLYGON_CULL_FRONT && gl_FrontFacing)) \
		discard;
#else
#define ubershader_check_culling()
#endif

// Dual paraboloid.

#ifdef MODE_DUAL_PARABOLOID
layout(location = 9) in highp float dp_clip;
#define dual_paraboloid_check_clip() \
	if (dp_clip > 0.0)               \
		discard;
#else
#define dual_paraboloid_check_clip()
#endif

// Normal.

#if defined(NORMAL_USED)
layout(location = 1) in mediump vec3 normal_interp;

void roughness_limiter_process(vec3 normal, inout float roughness) {
	if (sc_scene_roughness_limiter_enabled()) {
		//https://www.jp.square-enix.com/tech/library/pdf/ImprovedGeometricSpecularAA.pdf
		float roughness2 = roughness * roughness;
		vec3 dndu = dFdx(normal), dndv = dFdy(normal);
		float variance = scene_data.roughness_limiter_amount * (dot(dndu, dndu) + dot(dndv, dndv));
		float kernelRoughness2 = min(2.0 * variance, scene_data.roughness_limiter_limit); //limit effect
		float filteredRoughness2 = min(1.0, roughness2 + kernelRoughness2);
		roughness = sqrt(filteredRoughness2);
	}
}

#define initialize_normal()            \
	normal = normalize(normal_interp); \
	binormal = vec3(0.0);              \
	tangent = vec3(0.0);
#define apply_roughness_limiter() \
	roughness_limiter_process(normal, roughness);
#else
#define initialize_normal()
#define apply_roughness_limiter()
#endif

// Color.

#if defined(COLOR_USED)
layout(location = 2) in mediump vec4 color_interp;

#define initialize_color() \
	color = color_interp;
#else
#define initialize_color()
#endif

// UV.

#if defined(UV_USED)
layout(location = 3) in mediump vec2 uv_interp;

#define initialize_uv() \
	uv = uv_interp;
#else
#define initialize_uv()
#endif

// UV2.

#if defined(UV2_USED) || defined(USE_LIGHTMAP)
layout(location = 4) in mediump vec2 uv2_interp;

#define initialize_uv2() \
	uv2 = uv2_interp;
#else
#define initialize_uv2()
#endif

// Normal side check.

#if defined(NORMAL_USED) && defined(DO_SIDE_CHECK)
#define check_normal_side() \
	normal = gl_FrontFacing ? normal : -normal;
#else
#define check_normal_side()
#endif

// Binormal and tangent.

#if defined(TANGENT_USED) || defined(NORMAL_MAP_USED) || defined(LIGHT_ANISOTROPY_USED)
layout(location = 5) in mediump vec3 tangent_interp;
layout(location = 6) in mediump vec3 binormal_interp;

#define initialize_binormal_and_tangent()  \
	binormal = normalize(binormal_interp); \
	tangent = normalize(tangent_interp);
#else
#define initialize_binormal_and_tangent()
#endif

// Vertex lighting.

#if !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && defined(USE_VERTEX_LIGHTING)
layout(location = 7) in highp vec4 diffuse_light_interp;
layout(location = 8) in highp vec4 specular_light_interp;

#define apply_vertex_lighting()                \
	diffuse_light += diffuse_light_interp.rgb; \
	specular_light += specular_light_interp.rgb * f0;
#else
#define apply_vertex_lighting()
#endif

// Normal map.

#if defined(NORMAL_MAP_USED)
#define initialize_normal_map() \
	normal_map = vec3(0.5);     \
	normal_map_depth = 1.0;
#define compute_normal_from_normal_map()                                    \
	normal_map.xy = normal_map.xy * 2.0 - 1.0;                              \
	normal_map.z = sqrt(max(0.0, 1.0 - dot(normal_map.xy, normal_map.xy))); \
	normal = normalize(mix(normal, tangent * normal_map.x + binormal * normal_map.y + normal * normal_map.z, normal_map_depth));
#else
#define initialize_normal_map()
#define compute_normal_from_normal_map()
#endif

// Alpha scissor.

#if defined(ALPHA_SCISSOR_USED)
#define initialize_alpha_scissor_threshold() \
	alpha_scissor_threshold = 1.0;
#else
#define initialize_alpha_scissor_threshold()
#endif

// Material.

#if !defined(MODE_RENDER_DEPTH) && (defined(MODE_RENDER_MATERIAL) || !defined(MODE_UNSHADED))
#define initialize_material_parameters() \
	emission = vec3(0.0);                \
	ao = 1.0;                            \
	ao_light_affect = 0.0;               \
	metallic = 0.0;                      \
	specular = 0.5;                      \
	roughness = 1.0;
#else
#define initialize_material_parameters()
#endif

// ORMS (optimization by packing parameters).

#if !defined(MODE_RENDER_DEPTH)
#define pack_orms() \
	orms = packUnorm4x8(vec4(ao, roughness, metallic, specular));
#else
#define pack_orms()
#endif

// Fog (initialization).

#if !defined(FOG_DISABLED) && !defined(MODE_RENDER_DEPTH)
#define initialize_fog() \
	fog = vec4(0.0);
#else
#define initialize_fog()
#endif

// Fog (processing).

#if !defined(FOG_DISABLED) && !defined(MODE_RENDER_DEPTH) && !defined(CUSTOM_FOG_USED)

vec4 fog_process(vec3 vertex) {
	vec3 fog_color = scene_data_block.data.fog_light_color;

	if (scene_data_block.data.fog_aerial_perspective > 0.0) {
		vec3 sky_fog_color = vec3(0.0);
		vec3 cube_view = scene_data_block.data.radiance_inverse_xform * vertex;
		// mip_level always reads from the second mipmap and higher so the fog is always slightly blurred
		float mip_level = mix(1.0 / MAX_ROUGHNESS_LOD, 1.0, 1.0 - (abs(vertex.z) - scene_data_block.data.z_near) / (scene_data_block.data.z_far - scene_data_block.data.z_near));
#ifdef USE_RADIANCE_CUBEMAP_ARRAY
		float lod, blend;
		blend = modf(mip_level * MAX_ROUGHNESS_LOD, lod);
		sky_fog_color = texture(samplerCubeArray(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec4(cube_view, lod)).rgb;
		sky_fog_color = mix(sky_fog_color, texture(samplerCubeArray(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec4(cube_view, lod + 1)).rgb, blend);
#else
		sky_fog_color = textureLod(samplerCube(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), cube_view, mip_level * MAX_ROUGHNESS_LOD).rgb;
#endif //USE_RADIANCE_CUBEMAP_ARRAY
		fog_color = mix(fog_color, sky_fog_color, scene_data_block.data.fog_aerial_perspective);
	}

	if (scene_data_block.data.fog_sun_scatter > 0.001) {
		vec4 sun_scatter = vec4(0.0);
		float sun_total = 0.0;
		vec3 view = normalize(vertex);

		for (uint i = 0; i < sc_directional_lights(); i++) {
			vec3 light_color = directional_lights.data[i].color * directional_lights.data[i].energy;
			float light_amount = pow(max(dot(view, directional_lights.data[i].direction), 0.0), 8.0);
			fog_color += light_color * light_amount * scene_data_block.data.fog_sun_scatter;
		}
	}

	float fog_amount = 0.0;

	if (sc_use_depth_fog()) {
		float fog_z = smoothstep(scene_data_block.data.fog_depth_begin, scene_data_block.data.fog_depth_end, length(vertex));
		float fog_quad_amount = pow(fog_z, scene_data_block.data.fog_depth_curve) * scene_data_block.data.fog_density;
		fog_amount = fog_quad_amount;
	} else {
		fog_amount = 1 - exp(min(0.0, -length(vertex) * scene_data_block.data.fog_density));
	}

	if (abs(scene_data_block.data.fog_height_density) >= 0.0001) {
		float y = (scene_data_block.data.inv_view_matrix * vec4(vertex, 1.0)).y;
		float y_dist = y - scene_data_block.data.fog_height;
		float vfog_amount = 1.0 - exp(min(0.0, y_dist * scene_data_block.data.fog_height_density));
		fog_amount = max(vfog_amount, fog_amount);
	}

	return vec4(fog_color, fog_amount);
}

#define compute_fog()                                \
	if (!sc_disable_fog() && scene_data.fog_enabled) \
		fog = fog_process(vertex);
#else
#define compute_fog()
#endif

// Decals.

#if !defined(MODE_RENDER_DEPTH)

#define GET_DECAL_INDEX(i) (i > 3) ? ((decal_indices.y >> ((i - 4) * 8)) & 0xFF) : ((decal_indices.x >> (i * 8)) & 0xFF)

void decals_process(vec3 vertex, inout vec3 albedo, inout vec3 normal, inout float ao, inout float roughness, inout float metallic, inout vec3 emission) {
	vec3 vertex_ddx = dFdx(vertex);
	vec3 vertex_ddy = dFdy(vertex);
	uvec2 decal_indices = instances.data[draw_call.instance_index].decals;
	for (uint i = 0; i < sc_decals(); i++) {
		uint decal_index = (i > 3) ? ((decal_indices.y >> ((i - 4) * 8)) & 0xFF) : ((decal_indices.x >> (i * 8)) & 0xFF);
		if (!bool(decals.data[decal_index].mask & instances.data[draw_call.instance_index].layer_mask)) {
			// Not covered by the mask.
			continue;
		}

		vec3 uv_local = (decals.data[decal_index].xform * vec4(vertex, 1.0)).xyz;
		if (any(lessThan(uv_local, vec3(0.0, -1.0, 0.0))) || any(greaterThan(uv_local, vec3(1.0)))) {
			// Outside of the decal.
			continue;
		}

		float fade = pow(1.0 - (uv_local.y > 0.0 ? uv_local.y : -uv_local.y), uv_local.y > 0.0 ? decals.data[decal_index].upper_fade : decals.data[decal_index].lower_fade);
		if (decals.data[decal_index].normal_fade > 0.0) {
			fade *= smoothstep(decals.data[decal_index].normal_fade, 1.0, dot(normal_interp, decals.data[decal_index].normal) * 0.5 + 0.5);
		}

		// Simulate ddx/ddy for mipmaps.
		vec2 ddx = (decals.data[decal_index].xform * vec4(vertex_ddx, 0.0)).xz;
		vec2 ddy = (decals.data[decal_index].xform * vec4(vertex_ddy, 0.0)).xz;

		vec4 albedo_rect = decals.data[decal_index].albedo_rect;
		vec4 normal_rect = decals.data[decal_index].normal_rect;
		vec4 orm_rect = decals.data[decal_index].orm_rect;
		vec4 emission_rect = decals.data[decal_index].emission_rect;
		bool albedo_hit = (albedo_rect != vec4(0.0));
		bool normal_hit = albedo_hit && (normal_rect != vec4(0.0));
		bool orm_hit = albedo_hit && (orm_rect != vec4(0.0));
		bool emission_hit = (emission_rect != vec4(0.0));
		vec4 decal_albedo;
		vec3 decal_normal;
		vec3 decal_orm;
		vec3 decal_emission;
		if (albedo_hit) {
			decal_albedo = sc_decal_use_mipmaps() ? textureGrad(sampler2D(decal_atlas_srgb, decal_sampler), uv_local.xz * albedo_rect.zw + albedo_rect.xy, ddx * albedo_rect.zw, ddy * albedo_rect.zw) : textureLod(sampler2D(decal_atlas_srgb, decal_sampler), uv_local.xz * albedo_rect.zw + albedo_rect.xy, 0.0);
		}

		if (normal_hit) {
			decal_normal = sc_decal_use_mipmaps() ? textureGrad(sampler2D(decal_atlas, decal_sampler), uv_local.xz * normal_rect.zw + normal_rect.xy, ddx * normal_rect.zw, ddy * normal_rect.zw).xyz : textureLod(sampler2D(decal_atlas, decal_sampler), uv_local.xz * normal_rect.zw + normal_rect.xy, 0.0).xyz;
		}

		if (orm_hit) {
			decal_orm = sc_decal_use_mipmaps() ? textureGrad(sampler2D(decal_atlas, decal_sampler), uv_local.xz * orm_rect.zw + orm_rect.xy, ddx * orm_rect.zw, ddy * orm_rect.zw).xyz : textureLod(sampler2D(decal_atlas, decal_sampler), uv_local.xz * orm_rect.zw + orm_rect.xy, 0.0).xyz;
		}

		if (emission_hit) {
			decal_emission = sc_decal_use_mipmaps() ? textureGrad(sampler2D(decal_atlas_srgb, decal_sampler), uv_local.xz * emission_rect.zw + emission_rect.xy, ddx * emission_rect.zw, ddy * emission_rect.zw).xyz : textureLod(sampler2D(decal_atlas_srgb, decal_sampler), uv_local.xz * emission_rect.zw + emission_rect.xy, 0.0).xyz;
		}

		if (albedo_hit) {
			decal_albedo *= decals.data[decal_index].modulate;
			decal_albedo.a *= fade;
			albedo = mix(albedo, decal_albedo.rgb, decal_albedo.a * decals.data[decal_index].albedo_mix);
		}

		if (normal_hit) {
			decal_normal.xy = decal_normal.xy * vec2(2.0, -2.0) - vec2(1.0, -1.0);
			decal_normal.z = sqrt(max(0.0, 1.0 - dot(decal_normal.xy, decal_normal.xy)));

			// Convert to view space. Use XZY because Y is up.
			decal_normal = (decals.data[decal_index].normal_xform * decal_normal.xzy).xyz;
			normal = normalize(mix(normal, decal_normal, decal_albedo.a));
		}

		if (orm_hit) {
			ao = mix(ao, decal_orm.r, decal_albedo.a);
			roughness = mix(roughness, decal_orm.g, decal_albedo.a);
			metallic = mix(metallic, decal_orm.b, decal_albedo.a);
		}

		if (emission_hit) {
			// Emission is additive. Independent from albedo.
			emission += decal_emission * decals.data[decal_index].emission_energy * fade;
		}
	}
}

#define compute_decals() \
	decals_process(vertex, albedo, normal, ao, roughness, metallic, emission);
#else
#define compute_decals()
#endif

// Lighting (common)

#if !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED)

#define BIAS_FUNC(m_var, m_idx)                                                                 \
	m_var.xyz += light_dir * directional_lights.data[i].shadow_bias[m_idx];                     \
	vec3 normal_bias = base_normal_bias * directional_lights.data[i].shadow_normal_bias[m_idx]; \
	normal_bias -= light_dir * dot(light_dir, normal_bias);                                     \
	m_var.xyz += normal_bias;

void lights_process(vec3 albedo, float alpha, vec3 view, vec3 vertex, vec3 normal, vec3 binormal, vec3 tangent, float anisotropy, vec3 backlight, float rim, float rim_tint, float clearcoat, float clearcoat_roughness, uint orms, vec3 f0, inout vec3 diffuse_light, inout vec3 specular_light) {
	if (sc_directional_lights() > 0) {
#ifndef SHADOWS_DISABLED
		// Do shadow and lighting in two passes to reduce register pressure.
		uint shadow0 = 0;
		uint shadow1 = 0;

#ifdef USE_VERTEX_LIGHTING
		// Only process the first light's shadow for vertex lighting.
		for (uint i = 0; i < 1; i++) {
#else
		for (uint i = 0; i < sc_directional_lights(); i++) {
#endif
			if (!bool(directional_lights.data[i].mask & instances.data[draw_call.instance_index].layer_mask)) {
				// Not covered by the mask.
				continue;
			}

			float shadow = 1.0;
			if (directional_lights.data[i].shadow_opacity > 0.001) {
				float depth_z = -vertex.z;

				vec4 pssm_coord;
				float blur_factor;
				vec3 light_dir = directional_lights.data[i].direction;
				vec3 base_normal_bias = normalize(normal_interp) * (1.0 - max(0.0, dot(light_dir, -normalize(normal_interp))));
				vec4 v = vec4(vertex, 1.0);
				if (depth_z < directional_lights.data[i].shadow_split_offsets.x) {
					BIAS_FUNC(v, 0)
					pssm_coord = (directional_lights.data[i].shadow_matrix1 * v);
					blur_factor = 1.0;
				} else if (depth_z < directional_lights.data[i].shadow_split_offsets.y) {
					// In the rest of the splits, adjust shadow blur with reference to the first one to reduce the discrepancy between them.
					BIAS_FUNC(v, 1)
					pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
					blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.y;
				} else if (depth_z < directional_lights.data[i].shadow_split_offsets.z) {
					BIAS_FUNC(v, 2)
					pssm_coord = (directional_lights.data[i].shadow_matrix3 * v);
					blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.z;
				} else {
					BIAS_FUNC(v, 3)
					pssm_coord = (directional_lights.data[i].shadow_matrix4 * v);
					blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.w;
				}

				pssm_coord /= pssm_coord.w;

				shadow = sample_directional_pcf_shadow(directional_shadow_atlas, scene_data.directional_shadow_pixel_size * directional_lights.data[i].soft_shadow_scale * (blur_factor + (1.0 - blur_factor) * float(directional_lights.data[i].blend_splits)), pssm_coord, scene_data.taa_frame_count);

				if (directional_lights.data[i].blend_splits) {
					float pssm_blend;
					float blur_factor2;
					vec4 v = vec4(vertex, 1.0);
					if (depth_z < directional_lights.data[i].shadow_split_offsets.x) {
						// Adjust shadow blur with reference to the first one to reduce the discrepancy between them.
						BIAS_FUNC(v, 1)
						pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
						pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.x - directional_lights.data[i].shadow_split_offsets.x * 0.1, directional_lights.data[i].shadow_split_offsets.x, depth_z);
						blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.y;
					} else if (depth_z < directional_lights.data[i].shadow_split_offsets.y) {
						BIAS_FUNC(v, 2)
						pssm_coord = (directional_lights.data[i].shadow_matrix3 * v);
						pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.y - directional_lights.data[i].shadow_split_offsets.y * 0.1, directional_lights.data[i].shadow_split_offsets.y, depth_z);
						blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.z;
					} else if (depth_z < directional_lights.data[i].shadow_split_offsets.z) {
						BIAS_FUNC(v, 3)
						pssm_coord = (directional_lights.data[i].shadow_matrix4 * v);
						pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.z - directional_lights.data[i].shadow_split_offsets.z * 0.1, directional_lights.data[i].shadow_split_offsets.z, depth_z);
						blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.w;
					} else {
						// If no blend, same coord will be used (divide by z will result in same value, and already cached).
						pssm_blend = 0.0;
						blur_factor2 = 1.0;
					}

					pssm_coord /= pssm_coord.w;

					float shadow2 = sample_directional_pcf_shadow(directional_shadow_atlas, scene_data.directional_shadow_pixel_size * directional_lights.data[i].soft_shadow_scale * (blur_factor2 + (1.0 - blur_factor2) * float(directional_lights.data[i].blend_splits)), pssm_coord, scene_data.taa_frame_count);
					shadow = mix(shadow, shadow2, pssm_blend);
				}

				// Done with negative values for performance.
				shadow = mix(shadow, 1.0, smoothstep(directional_lights.data[i].fade_from, directional_lights.data[i].fade_to, vertex.z));

#ifdef USE_VERTEX_LIGHTING
				diffuse_light *= mix(1.0, shadow, diffuse_light_interp.a);
				specular_light *= mix(1.0, shadow, specular_light_interp.a);
#endif
#undef BIAS_FUNC
			}

			if (i < 4) {
				shadow0 |= uint(clamp(shadow * 255.0, 0.0, 255.0)) << (i * 8);
			} else {
				shadow1 |= uint(clamp(shadow * 255.0, 0.0, 255.0)) << ((i - 4) * 8);
			}
		}
#endif // SHADOWS_DISABLED

#if !defined(USE_VERTEX_LIGHTING)
		for (uint i = 0; i < sc_directional_lights(); i++) {
			if (!bool(directional_lights.data[i].mask & instances.data[draw_call.instance_index].layer_mask)) {
				// Not covered by the mask.
				continue;
			}

			// We're not doing light transmittance.
			float shadow = 1.0;
#ifndef SHADOWS_DISABLED
			if (i < 4) {
				shadow = float(shadow0 >> (i * 8) & 0xFF) / 255.0;
			} else {
				shadow = float(shadow1 >> ((i - 4) * 8) & 0xFF) / 255.0;
			}

			shadow = mix(1.0, shadow, directional_lights.data[i].shadow_opacity);
#endif
			blur_shadow(shadow);

			vec3 tint = vec3(1.0);
#ifdef DEBUG_DRAW_PSSM_SPLITS
			if (-vertex.z < directional_lights.data[i].shadow_split_offsets.x) {
				tint = vec3(1.0, 0.0, 0.0);
			} else if (-vertex.z < directional_lights.data[i].shadow_split_offsets.y) {
				tint = vec3(0.0, 1.0, 0.0);
			} else if (-vertex.z < directional_lights.data[i].shadow_split_offsets.z) {
				tint = vec3(0.0, 0.0, 1.0);
			} else {
				tint = vec3(1.0, 1.0, 0.0);
			}
			tint = mix(tint, vec3(1.0), shadow);
			shadow = 1.0;
#endif

			float size_A = sc_use_light_soft_shadows() ? directional_lights.data[i].size : 0.0;
			light_compute(normal, directional_lights.data[i].direction, view, size_A,
					directional_lights.data[i].color * directional_lights.data[i].energy * tint,
					true, shadow, f0, orms, 1.0, albedo, alpha,
#ifdef LIGHT_BACKLIGHT_USED
					backlight,
#endif
#ifdef LIGHT_RIM_USED
					rim, rim_tint,
#endif
#ifdef LIGHT_CLEARCOAT_USED
					clearcoat, clearcoat_roughness, normalize(normal_interp),
#endif
#ifdef LIGHT_ANISOTROPY_USED
					binormal, tangent, anisotropy,
#endif
					diffuse_light,
					specular_light);
		}
#endif
	}

#if !defined(USE_VERTEX_LIGHTING)
	vec3 vertex_ddx = dFdx(vertex);
	vec3 vertex_ddy = dFdy(vertex);
	uvec2 omni_indices = instances.data[draw_call.instance_index].omni_lights;
	for (uint i = 0; i < sc_omni_lights(); i++) {
		uint light_index = (i > 3) ? ((omni_indices.y >> ((i - 4) * 8)) & 0xFF) : ((omni_indices.x >> (i * 8)) & 0xFF);
		float shadow = light_process_omni_shadow(light_index, vertex, normal, scene_data.taa_frame_count);
		shadow = blur_shadow(shadow);

		light_process_omni(light_index, vertex, view, normal, vertex_ddx, vertex_ddy, f0, orms, shadow, albedo, alpha,
#ifdef LIGHT_BACKLIGHT_USED
				backlight,
#endif
#ifdef LIGHT_RIM_USED
				rim,
				rim_tint,
#endif
#ifdef LIGHT_CLEARCOAT_USED
				clearcoat, clearcoat_roughness, normalize(normal_interp),
#endif
#ifdef LIGHT_ANISOTROPY_USED
				tangent,
				binormal, anisotropy,
#endif
				diffuse_light, specular_light);
	}

	uvec2 spot_indices = instances.data[draw_call.instance_index].spot_lights;
	for (uint i = 0; i < sc_spot_lights(); i++) {
		uint light_index = (i > 3) ? ((spot_indices.y >> ((i - 4) * 8)) & 0xFF) : ((spot_indices.x >> (i * 8)) & 0xFF);
		float shadow = light_process_spot_shadow(light_index, vertex, normal, scene_data.taa_frame_count);
		shadow = blur_shadow(shadow);

		light_process_spot(light_index, vertex, view, normal, vertex_ddx, vertex_ddy, f0, orms, shadow, albedo, alpha,
#ifdef LIGHT_BACKLIGHT_USED
				backlight,
#endif
#ifdef LIGHT_RIM_USED
				rim,
				rim_tint,
#endif
#ifdef LIGHT_CLEARCOAT_USED
				clearcoat, clearcoat_roughness, normalize(normal_interp),
#endif
#ifdef LIGHT_ANISOTROPY_USED
				tangent,
				binormal, anisotropy,
#endif
				diffuse_light, specular_light);
	}
#endif // !USE_VERTEX_LIGHTING
}

#define compute_f0() \
	f0 = F0(metallic, specular, albedo);
#define compute_lights() \
	lights_process(albedo, alpha, view, vertex, normal, binormal, tangent, anisotropy, backlight, rim, rim_tint, clearcoat, clearcoat_roughness, orms, f0, diffuse_light, specular_light);
#else
#define compute_f0()
#define compute_lights()
#endif

// Lighting (not material).

#if !defined(MODE_RENDER_DEPTH) && !defined(MODE_RENDER_MATERIAL) && !defined(MODE_UNSHADED)
#define initialize_lights()               \
	diffuse_light = vec3(0.0, 0.0, 0.0);  \
	specular_light = vec3(0.0, 0.0, 0.0); \
	ambient_light = vec3(0.0, 0.0, 0.0);

#define finalize_ambient_light() \
	ambient_light *= albedo.rgb; \
	ambient_light *= ao;

#define convert_ambient_occlusion() \
	ao = mix(1.0, ao, ao_light_affect);

#define finalize_lights()            \
	diffuse_light *= albedo;         \
	diffuse_light *= ao;             \
	specular_light *= ao;            \
	diffuse_light *= 1.0 - metallic; \
	ambient_light *= 1.0 - metallic;
#else
#define initialize_lights()
#define finalize_ambient_light()
#define convert_ambient_occlusion()
#define finalize_lights()
#endif

// Light transmittance (SSS).

#if defined(LIGHT_TRANSMITTANCE_USED)
#define initialize_transmittance()   \
	transmittance_color = vec4(0.0); \
	transmittance_depth = 0.0;       \
	transmittance_boost = 0.0;
#if defined(SSS_MODE_SKIN)
#define set_transmittance_alpha() \
	transmittance_color.a = sss_strength;
#else
#define set_transmittance_alpha() \
	transmittance_color.a *= sss_strength;
#endif
#else
#define initialize_transmittance()
#define set_transmittance_alpha()
#endif

// Light anisotropy.

#if defined(LIGHT_ANISOTROPY_USED)
#define initialize_anisotropy() \
	anisotropy = 0.0;           \
	anisotropy_flow = vec2(1.0, 0.0);
#define compute_tangent_and_binormal_with_anisotropy()                                \
	if (anisotropy > 0.01) {                                                          \
		mat3 rot = mat3(tangent, binormal, normal);                                   \
		tangent = normalize(rot * vec3(anisotropy_flow.x, anisotropy_flow.y, 0.0));   \
		binormal = normalize(rot * vec3(-anisotropy_flow.y, anisotropy_flow.x, 0.0)); \
	}
#else
#define initialize_anisotropy()
#define compute_tangent_and_binormal_with_anisotropy()
#endif

// View.

#if defined(USE_MULTIVIEW)
#define initialize_eye_offset() \
	eye_offset = scene_data.eye_offset[ViewIndex].xyz;
#define initialize_view() \
	view = -normalize(vertex - eye_offset);
#else
#define initialize_eye_offset() \
	eye_offset = vec3(0.0, 0.0, 0.0);
#define initialize_view() \
	view = -normalize(vertex);
#endif

// Ambient light.

#if !defined(AMBIENT_LIGHT_DISABLED) && !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && !defined(USE_LIGHTMAP)
void ambient_light_process(vec3 normal, inout vec3 ambient_light) {
	if (scene_data.use_ambient_light) {
		ambient_light = scene_data.ambient_light_color_energy.rgb;

		if (sc_scene_use_ambient_cubemap()) {
			vec3 ambient_dir = scene_data.radiance_inverse_xform * normal;
#ifdef USE_RADIANCE_CUBEMAP_ARRAY
			vec3 cubemap_ambient = texture(samplerCubeArray(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec4(ambient_dir, MAX_ROUGHNESS_LOD)).rgb;
#else
			vec3 cubemap_ambient = textureLod(samplerCube(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), ambient_dir, MAX_ROUGHNESS_LOD).rgb;
#endif //USE_RADIANCE_CUBEMAP_ARRAY
			cubemap_ambient *= sc_luminance_multiplier();
			cubemap_ambient *= scene_data.IBL_exposure_normalization;
			ambient_light = mix(ambient_light, cubemap_ambient * scene_data.ambient_light_color_energy.a, scene_data.ambient_color_sky_mix);
		}
	}
}

#define apply_ambient_light_from_scene() \
	ambient_light_process(normal, ambient_light)
#else
#define apply_ambient_light_from_scene()
#endif

// Lightmap.

#if !defined(AMBIENT_LIGHT_DISABLED) && !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && defined(USE_LIGHTMAP)
// w0, w1, w2, and w3 are the four cubic B-spline basis functions
float w0(float a) {
	return (1.0 / 6.0) * (a * (a * (-a + 3.0) - 3.0) + 1.0);
}

float w1(float a) {
	return (1.0 / 6.0) * (a * a * (3.0 * a - 6.0) + 4.0);
}

float w2(float a) {
	return (1.0 / 6.0) * (a * (a * (-3.0 * a + 3.0) + 3.0) + 1.0);
}

float w3(float a) {
	return (1.0 / 6.0) * (a * a * a);
}

// g0 and g1 are the two amplitude functions
float g0(float a) {
	return w0(a) + w1(a);
}

float g1(float a) {
	return w2(a) + w3(a);
}

// h0 and h1 are the two offset functions
float h0(float a) {
	return -1.0 + w1(a) / (w0(a) + w1(a));
}

float h1(float a) {
	return 1.0 + w3(a) / (w2(a) + w3(a));
}

vec4 textureArray_bicubic(texture2DArray tex, vec3 uv, vec2 texture_size) {
	vec2 texel_size = vec2(1.0) / texture_size;

	uv.xy = uv.xy * texture_size + vec2(0.5);

	vec2 iuv = floor(uv.xy);
	vec2 fuv = fract(uv.xy);

	float g0x = g0(fuv.x);
	float g1x = g1(fuv.x);
	float h0x = h0(fuv.x);
	float h1x = h1(fuv.x);
	float h0y = h0(fuv.y);
	float h1y = h1(fuv.y);

	vec2 p0 = (vec2(iuv.x + h0x, iuv.y + h0y) - vec2(0.5)) * texel_size;
	vec2 p1 = (vec2(iuv.x + h1x, iuv.y + h0y) - vec2(0.5)) * texel_size;
	vec2 p2 = (vec2(iuv.x + h0x, iuv.y + h1y) - vec2(0.5)) * texel_size;
	vec2 p3 = (vec2(iuv.x + h1x, iuv.y + h1y) - vec2(0.5)) * texel_size;

	return (g0(fuv.y) * (g0x * texture(sampler2DArray(tex, SAMPLER_LINEAR_CLAMP), vec3(p0, uv.z)) + g1x * texture(sampler2DArray(tex, SAMPLER_LINEAR_CLAMP), vec3(p1, uv.z)))) +
			(g1(fuv.y) * (g0x * texture(sampler2DArray(tex, SAMPLER_LINEAR_CLAMP), vec3(p2, uv.z)) + g1x * texture(sampler2DArray(tex, SAMPLER_LINEAR_CLAMP), vec3(p3, uv.z))));
}

void lightmap_process(vec3 normal, vec2 uv2, inout vec3 ambient_light) {
	if (bool(instances.data[draw_call.instance_index].flags & INSTANCE_FLAGS_USE_LIGHTMAP_CAPTURE)) {
		// TODO: Move flag to specialization constant.
		uint index = instances.data[draw_call.instance_index].gi_offset;

		vec3 wnormal = mat3(scene_data.inv_view_matrix) * normal;
		const float c1 = 0.429043;
		const float c2 = 0.511664;
		const float c3 = 0.743125;
		const float c4 = 0.886227;
		const float c5 = 0.247708;
		ambient_light += (c1 * lightmap_captures.data[index].sh[8].rgb * (wnormal.x * wnormal.x - wnormal.y * wnormal.y) +
								 c3 * lightmap_captures.data[index].sh[6].rgb * wnormal.z * wnormal.z +
								 c4 * lightmap_captures.data[index].sh[0].rgb -
								 c5 * lightmap_captures.data[index].sh[6].rgb +
								 2.0 * c1 * lightmap_captures.data[index].sh[4].rgb * wnormal.x * wnormal.y +
								 2.0 * c1 * lightmap_captures.data[index].sh[7].rgb * wnormal.x * wnormal.z +
								 2.0 * c1 * lightmap_captures.data[index].sh[5].rgb * wnormal.y * wnormal.z +
								 2.0 * c2 * lightmap_captures.data[index].sh[3].rgb * wnormal.x +
								 2.0 * c2 * lightmap_captures.data[index].sh[1].rgb * wnormal.y +
								 2.0 * c2 * lightmap_captures.data[index].sh[2].rgb * wnormal.z) *
				scene_data.emissive_exposure_normalization;

	} else if (bool(instances.data[draw_call.instance_index].flags & INSTANCE_FLAGS_USE_LIGHTMAP)) {
		// TODO: Move flag to specialization constant and SH as well.
		bool uses_sh = bool(instances.data[draw_call.instance_index].flags & INSTANCE_FLAGS_USE_SH_LIGHTMAP);
		uint ofs = instances.data[draw_call.instance_index].gi_offset & 0xFFFF;
		uint slice = instances.data[draw_call.instance_index].gi_offset >> 16;
		vec3 uvw;
		uvw.xy = uv2 * instances.data[draw_call.instance_index].lightmap_uv_scale.zw + instances.data[draw_call.instance_index].lightmap_uv_scale.xy;
		uvw.z = float(slice);

		if (uses_sh) {
			// SH textures use 4 times more data.
			uvw.z *= 4.0;
			vec3 lm_light_l0;
			vec3 lm_light_l1n1;
			vec3 lm_light_l1_0;
			vec3 lm_light_l1p1;

			if (sc_use_lightmap_bicubic_filter()) {
				lm_light_l0 = textureArray_bicubic(lightmap_textures[ofs], uvw + vec3(0.0, 0.0, 0.0), lightmaps.data[ofs].light_texture_size).rgb;
				lm_light_l1n1 = (textureArray_bicubic(lightmap_textures[ofs], uvw + vec3(0.0, 0.0, 1.0), lightmaps.data[ofs].light_texture_size).rgb - vec3(0.5)) * 2.0;
				lm_light_l1_0 = (textureArray_bicubic(lightmap_textures[ofs], uvw + vec3(0.0, 0.0, 2.0), lightmaps.data[ofs].light_texture_size).rgb - vec3(0.5)) * 2.0;
				lm_light_l1p1 = (textureArray_bicubic(lightmap_textures[ofs], uvw + vec3(0.0, 0.0, 3.0), lightmaps.data[ofs].light_texture_size).rgb - vec3(0.5)) * 2.0;
			} else {
				lm_light_l0 = textureLod(sampler2DArray(lightmap_textures[ofs], SAMPLER_LINEAR_CLAMP), uvw + vec3(0.0, 0.0, 0.0), 0.0).rgb;
				lm_light_l1n1 = (textureLod(sampler2DArray(lightmap_textures[ofs], SAMPLER_LINEAR_CLAMP), uvw + vec3(0.0, 0.0, 1.0), 0.0).rgb - vec3(0.5)) * 2.0;
				lm_light_l1_0 = (textureLod(sampler2DArray(lightmap_textures[ofs], SAMPLER_LINEAR_CLAMP), uvw + vec3(0.0, 0.0, 2.0), 0.0).rgb - vec3(0.5)) * 2.0;
				lm_light_l1p1 = (textureLod(sampler2DArray(lightmap_textures[ofs], SAMPLER_LINEAR_CLAMP), uvw + vec3(0.0, 0.0, 3.0), 0.0).rgb - vec3(0.5)) * 2.0;
			}

			vec3 n = normalize(lightmaps.data[ofs].normal_xform * normal);
			float exposure_normalization = lightmaps.data[ofs].exposure_normalization;

			ambient_light += lm_light_l0 * exposure_normalization;
			ambient_light += lm_light_l1n1 * n.y * (lm_light_l0 * exposure_normalization * 4.0);
			ambient_light += lm_light_l1_0 * n.z * (lm_light_l0 * exposure_normalization * 4.0);
			ambient_light += lm_light_l1p1 * n.x * (lm_light_l0 * exposure_normalization * 4.0);
		} else {
			if (sc_use_lightmap_bicubic_filter()) {
				ambient_light += textureArray_bicubic(lightmap_textures[ofs], uvw, lightmaps.data[ofs].light_texture_size).rgb * lightmaps.data[ofs].exposure_normalization;
			} else {
				ambient_light += textureLod(sampler2DArray(lightmap_textures[ofs], SAMPLER_LINEAR_CLAMP), uvw, 0.0).rgb * lightmaps.data[ofs].exposure_normalization;
			}
		}
	}
}

#define apply_lightmap() \
	lightmap_process(normal, uv2, ambient_light);
#else
#define apply_lightmap()
#endif

// Custom radiance.

#if defined(CUSTOM_RADIANCE_USED) && !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && !defined(USE_LIGHTMAP)
#define initialize_custom_radiance() \
	custom_radiance = vec4(0.0);
#define apply_custom_radiance() \
	specular_light = mix(specular_light, custom_radiance.rgb, custom_radiance.a);
#else
#define initialize_custom_radiance()
#define apply_custom_radiance()
#endif

// Custom irradiance.

#if defined(CUSTOM_IRRADIANCE_USED) && !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && !defined(USE_LIGHTMAP)
#define initialize_custom_irradiance() \
	custom_irradiance = vec4(0.0);
#define apply_custom_irradiance() \
	ambient_light = mix(ambient_light, custom_irradiance.rgb, custom_irradiance.a);
#else
#define initialize_custom_irradiance()
#define apply_custom_irradiance()
#endif

// Light backlight.

#if defined(LIGHT_BACKLIGHT_USED) && !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED)
#define initialize_light_backlight() \
	backlight = vec3(0.0);
#else
#define initialize_light_backlight()
#endif

// Light rim.

#if defined(LIGHT_RIM_USED) && !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED)
#define initialize_light_rim() \
	rim = 0.0;                 \
	rim_tint = 0.0;
#else
#define initialize_light_rim()
#endif

// Light clearcoat.

#if defined(LIGHT_CLEARCOAT_USED) && !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED) && !defined(USE_LIGHTMAP)

void light_clearcoat_process(vec3 view, float clearcoat, float clearcoat_roughnesss, inout vec3 ambient_light, inout vec3 specular_light) {
	if (sc_scene_use_reflection_cubemap()) {
		// We want to use the geometric normal, not the one affected by the normal map.
		vec3 n = normalize(normal_interp);
		float NoV = max(dot(n, view), 0.0001);
		vec3 ref_vec = reflect(-view, n);
		ref_vec = mix(ref_vec, n, clearcoat_roughness * clearcoat_roughness);

		// The clear coat layer assumes an IOR of 1.5 (4% reflectance).
		float Fc = clearcoat * (0.04 + 0.96 * SchlickFresnel(NoV));
		float attenuation = 1.0 - Fc;
		ambient_light *= attenuation;
		specular_light *= attenuation;

		float horizon = min(1.0 + dot(ref_vec, normal), 1.0);
		ref_vec = scene_data.radiance_inverse_xform * ref_vec;
		float roughness_lod = mix(0.001, 0.1, sqrt(clearcoat_roughness)) * MAX_ROUGHNESS_LOD;

#ifdef USE_RADIANCE_CUBEMAP_ARRAY
		float lod, blend;
		blend = modf(roughness_lod, lod);
		vec3 clearcoat_light = texture(samplerCubeArray(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec4(ref_vec, lod)).rgb;
		clearcoat_light = mix(clearcoat_light, texture(samplerCubeArray(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec4(ref_vec, lod + 1)).rgb, blend);
#else
		vec3 clearcoat_light = textureLod(samplerCube(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), ref_vec, roughness_lod).rgb;
#endif

		specular_light += clearcoat_light * horizon * horizon * Fc * scene_data.ambient_light_color_energy.a;
	}
}

#define initialize_light_clearcoat() \
	clearcoat = 0.0;                 \
	clearcoat_roughness = 0.0;
#define apply_light_clearcoat() \
	light_clearcoat_process(view, clearcoat, clearcoat_roughnesss, ambient_light, specular_light);
#else
#define initialize_light_clearcoat()
#define apply_light_clearcoat()
#endif

// Reflections.

#if !defined(AMBIENT_LIGHT_DISABLED) && !defined(MODE_RENDER_DEPTH) && !defined(MODE_UNSHADED)

void reflection_probes_process(vec3 vertex, vec3 view, vec3 normal, vec3 binormal, vec3 tangent, float roughness, inout vec3 specular_light, inout vec3 ambient_light) {
	if (sc_reflection_probes() > 0) {
		vec4 reflection_accum = vec4(0.0, 0.0, 0.0, 0.0);
		vec4 ambient_accum = vec4(0.0, 0.0, 0.0, 0.0);

#if defined(LIGHT_ANISOTROPY_USED)
		// https://google.github.io/filament/Filament.html#lighting/imagebasedlights/anisotropy
		vec3 anisotropic_direction = anisotropy >= 0.0 ? binormal : tangent;
		vec3 anisotropic_tangent = cross(anisotropic_direction, view);
		vec3 anisotropic_normal = cross(anisotropic_tangent, anisotropic_direction);
		vec3 bent_normal = normalize(mix(normal, anisotropic_normal, abs(anisotropy) * clamp(5.0 * roughness, 0.0, 1.0)));
#else
		vec3 bent_normal = normal;
#endif
		vec3 ref_vec = normalize(reflect(-view, bent_normal));
		ref_vec = mix(ref_vec, bent_normal, roughness * roughness);

		uvec2 reflection_indices = instances.data[draw_call.instance_index].reflection_probes;
		for (uint i = 0; i < sc_reflection_probes(); i++) {
			uint ref_index = (i > 3) ? ((reflection_indices.y >> ((i - 4) * 8)) & 0xFF) : ((reflection_indices.x >> (i * 8)) & 0xFF);
			reflection_process(ref_index, vertex, ref_vec, bent_normal, roughness, ambient_light, specular_light, ambient_accum, reflection_accum);
		}

		if (reflection_accum.a > 0.0) {
			specular_light = reflection_accum.rgb / reflection_accum.a;
		}

#if !defined(USE_LIGHTMAP)
		if (ambient_accum.a > 0.0) {
			ambient_light = ambient_accum.rgb / ambient_accum.a;
		}
#endif
	}
}

void reflection_cubemap_process(vec3 view, vec3 normal, vec3 binormal, vec3 tangent, float roughness, float anisotropy, inout vec3 specular_light) {
	if (sc_scene_use_reflection_cubemap()) {
#if defined(LIGHT_ANISOTROPY_USED)
		// https://google.github.io/filament/Filament.html#lighting/imagebasedlights/anisotropy
		vec3 anisotropic_direction = anisotropy >= 0.0 ? binormal : tangent;
		vec3 anisotropic_tangent = cross(anisotropic_direction, view);
		vec3 anisotropic_normal = cross(anisotropic_tangent, anisotropic_direction);
		vec3 bent_normal = normalize(mix(normal, anisotropic_normal, abs(anisotropy) * clamp(5.0 * roughness, 0.0, 1.0)));
		vec3 ref_vec = reflect(-view, bent_normal);
		ref_vec = mix(ref_vec, bent_normal, roughness * roughness);
#else
		vec3 ref_vec = reflect(-view, normal);
		ref_vec = mix(ref_vec, normal, roughness * roughness);
#endif

		float horizon = min(1.0 + dot(ref_vec, normal), 1.0);
		ref_vec = scene_data.radiance_inverse_xform * ref_vec;

#if defined(USE_RADIANCE_CUBEMAP_ARRAY)
		float lod, blend;
		blend = modf(sqrt(roughness) * MAX_ROUGHNESS_LOD, lod);
		specular_light = texture(samplerCubeArray(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec4(ref_vec, lod)).rgb;
		specular_light = mix(specular_light, texture(samplerCubeArray(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec4(ref_vec, lod + 1)).rgb, blend);
#else
		specular_light = textureLod(samplerCube(radiance_cubemap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), ref_vec, sqrt(roughness) * MAX_ROUGHNESS_LOD).rgb;
#endif

		specular_light *= sc_luminance_multiplier();
		specular_light *= scene_data.IBL_exposure_normalization;
		specular_light *= horizon * horizon;
		specular_light *= scene_data.ambient_light_color_energy.a;
	}
}

void reflection_specular_light_process(vec3 normal, vec3 view, vec3 f0, vec3 albedo, float roughness, float specular, float metallic, inout vec3 specular_light) {
#if defined(DIFFUSE_TOON)
	// Simplify shading for toon.
	specular_light *= specular * metallic * albedo * 2.0;
#else
	// Scales the specular reflections, needs to be computed before lighting happens,
	// but after environment, GI, and reflection probes are added.
	// Environment brdf approximation (Lazarov 2013)
	// See https://www.unrealengine.com/en-US/blog/physically-based-shading-on-mobile
	const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
	const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
	vec4 r = roughness * c0 + c1;
	float ndotv = clamp(dot(normal, view), 0.0, 1.0);
	float a004 = min(r.x * r.x, exp2(-9.28 * ndotv)) * r.x + r.y;
	vec2 env = vec2(-1.04, 1.04) * a004 + r.zw;
	specular_light *= env.x * f0 + env.y * clamp(50.0 * f0.g, metallic, 1.0);
#endif
}

#define compute_reflection_probes() \
	reflection_probes_process(vertex, view, normal, binormal, tangent, roughness, specular_light, ambient_light);
#define compute_reflection_cubemap() \
	reflection_cubemap_process(view, normal, binormal, tangent, roughness, anisotropy, specular_light);
#define compute_reflection_specular_light() \
	reflection_specular_light_process(normal, view, f0, albedo, roughness, specular, metallic, specular_light)
#else
#define compute_reflection_probes()
#define compute_reflection_cubemap()
#define compute_reflection_specular_light()
#endif

// Single render target (common).
// On mobile we use a UNORM buffer with 10bpp which results in a range from 0.0 - 1.0 resulting in HDR breaking
// We divide by sc_luminance_multiplier to support a range from 0.0 - 2.0 both increasing precision on bright and darker images

#if !defined(MODE_RENDER_DEPTH) && !defined(MODE_RENDER_MATERIAL)
#define FRAGMENT_COLOR_USED

layout(location = 0) out vec4 frag_color;

#define write_frag_color()                                             \
	frag_color.rgb = frag_color_value.rgb / sc_luminance_multiplier(); \
	frag_color.a = frag_color_value.a;
#else
#define write_frag_color()
#endif

// Premul alpha.

#if !defined(MODE_RENDER_DEPTH) && !defined(MODE_RENDER_MATERIAL) && defined(PREMUL_ALPHA_USED)
#define initialize_premul_alpha() \
	premul_alpha = 1.0;
#define apply_premul_alpha() \
	frag_color.rgb *= premul_alpha;
#else
#define initialize_premul_alpha()
#define apply_premul_alpha()
#endif

// Light vertex.

#if defined(LIGHT_VERTEX_USED)
#define initialize_light_vertex() \
	light_vertex = vertex;
#define set_vertex_from_light_vertex() \
	vertex = light_vertex;
#else
#define initialize_light_vertex()
#define set_vertex_from_light_vertex()
#endif

// Unshaded.

#if defined(MODE_UNSHADED) && defined(FRAGMENT_COLOR_USED)
#define write_frag_color_value_if_unshaded() \
	frag_color_value = vec4(albedo, alpha);
#else
#define write_frag_color_value_if_unshaded()
#endif

// Shaded.

#if !defined(MODE_UNSHADED) && defined(FRAGMENT_COLOR_USED)
#define write_frag_color_value_if_shaded() \
	frag_color_value = vec4(emission + ambient_light + diffuse_light + specular_light, alpha);
#else
#define write_frag_color_value_if_shaded()
#endif

// Fog.

#if !defined(FOG_DISABLED) && defined(FRAGMENT_COLOR_USED)
#define apply_fog_to_frag_color_value() \
	frag_color_value.rgb = mix(frag_color_value.rgb, fog.rgb, fog.a);
#else
#define apply_fog_to_frag_color_value()
#endif

// Material mode.

#if defined(MODE_RENDER_MATERIAL)
layout(location = 0) out vec4 albedo_output_buffer;
layout(location = 1) out vec4 normal_output_buffer;
layout(location = 2) out vec4 orm_output_buffer;
layout(location = 3) out vec4 emission_output_buffer;
layout(location = 4) out float depth_output_buffer;

#define write_material_buffers()                                     \
	albedo_output_buffer = vec4(albedo, alpha);                      \
	normal_output_buffer = vec4(normal * 0.5 + 0.5, 0.0);            \
	orm_output_buffer = vec4(ao, roughness, metallic, sss_strength); \
	emission_output_buffer = vec4(emission, 0.0);                    \
	depth_output_buffer = -vertex.z;
#else
#define write_material_buffers()
#endif

// Double precision.

#if defined(USE_DOUBLE_PRECISION)
#define clear_translation_if_double_precision() \
	read_model_matrix[0][3] = 0.0;              \
	read_model_matrix[1][3] = 0.0;              \
	read_model_matrix[2][3] = 0.0;              \
	inv_view_matrix[0][3] = 0.0;                \
	inv_view_matrix[1][3] = 0.0;                \
	inv_view_matrix[2][3] = 0.0;
#else
#define clear_translation_if_double_precision()
#endif

// Alpha checks (when not using shadow to opacity).

#if !defined(USE_SHADOW_TO_OPACITY) && defined(ALPHA_SCISSOR_USED)
#define alpha_scissor_check()            \
	if (alpha < alpha_scissor_threshold) \
		discard;
#else
#define alpha_scissor_check()
#endif

// Alpha hash.

#if !defined(USE_SHADOW_TO_OPACITY) && defined(ALPHA_HASH_USED)
#define initialize_alpha_hash() \
	alpha_hash_scale = 1.0;
#define alpha_hash_check()                                                                    \
	vec3 object_pos = (inverse(read_model_matrix) * inv_view_matrix * vec4(vertex, 1.0)).xyz; \
	if (alpha < compute_alpha_hash_threshold(object_pos, alpha_hash_scale))                   \
		discard;
#else
#define initialize_alpha_hash()
#define alpha_hash_check()
#endif

// Alpha scissor or hash when not using edge antialiasing.

#if !defined(USE_SHADOW_TO_OPACITY) && !defined(ALPHA_ANTIALIASING_EDGE_USED) && (defined(ALPHA_SCISSOR_USED) || defined(ALPHA_HASH_USED))
#define clear_alpha_scissor_or_hash_if_not_using_edge_antialiasing() \
	alpha = 1.0;
#else
#define clear_alpha_scissor_or_hash_if_not_using_edge_antialiasing()
#endif

// Alpha scissor when using edge antialasing.

#if !defined(USE_SHADOW_TO_OPACITY) && defined(ALPHA_ANTIALIASING_EDGE_USED) && defined(ALPHA_SCISSOR_USED)
#define adjust_edge_antialiasing_if_using_alpha_scissor() \
	alpha_antialiasing_edge = clamp(alpha_scissor_threshold + alpha_antialiasing_edge, 0.0, 1.0);
#else
#define adjust_edge_antialiasing_if_using_alpha_scissor()
#endif

// Alpha antialiasing edge.

#if !defined(USE_SHADOW_TO_OPACITY) && defined(ALPHA_ANTIALIASING_EDGE_USED)
#define initialize_alpha_antialiasing_edge() \
	alpha_antialiasing_edge = 0.0;           \
	alpha_texture_coordinate = vec2(0.0, 0.0);
#define set_alpha_if_using_edge_antialiasing() \
	alpha = compute_alpha_antialiasing_edge(alpha, alpha_texture_coordinate, alpha_antialiasing_edge);
#else
#define initialize_alpha_antialiasing_edge()
#define set_alpha_if_using_edge_antialiasing()
#endif

// Opaque prepass alpha check.

#if !defined(USE_SHADOW_TO_OPACITY) && (defined(MODE_RENDER_DEPTH) || defined(USE_OPAQUE_PREPASS) || defined(ALPHA_ANTIALIASING_EDGE_USED))
#define opaque_prepass_alpha_check()                 \
	if (alpha < scene_data.opaque_prepass_threshold) \
		discard;
#else
#define opaque_prepass_alpha_check()
#endif

// Clip alpha.

#if defined(ENABLE_CLIP_ALPHA)
#define clip_alpha_check()
if (albedo.a < 0.99)
	discard;
#else
#define clip_alpha_check()
#endif

// Shadow to opacity.

#if defined(USE_SHADOW_TO_OPACITY) && !defined(MODE_RENDER_DEPTH)
#define apply_shadow_to_opacity() \
	alpha = min(alpha, clamp(length(ambient_light), 0.0, 1.0));
#else
#define apply_shadow_to_opacity()
#endif

// Alpha scissor (shadow to opacity).

#if defined(USE_SHADOW_TO_OPACITY) && !defined(MODE_RENDER_DEPTH) && defined(ALPHA_SCISSOR_USED)
#define alpha_scissor_check_if_shadow_to_opacity() \
	if (alpha < alpha_scissor_threshold)           \
		discard;
#else
#define alpha_scissor_check_if_shadow_to_opacity()
#endif

// Emissive exposure normalization.
// Used in regular draw pass and when drawing SDFs for SDFGI and materials for VoxelGI.

#if !defined(MODE_UNSHADED)
#define apply_emission_exposure_normalization() \
	emission *= scene_data.emissive_exposure_normalization;
#else
#define apply_emission_exposure_normalization()
#endif

void main() {
	// Early exit checks.
	ubershader_check_culling();
	dual_paraboloid_check_clip();

	// Common variables. If initialization is skipped, no instructions will be generated on the SPIR-V.
	vec3 vertex;
	vec2 uv;
	vec2 uv2;
	vec4 color;
	vec3 albedo;
	float alpha;
	float alpha_scissor_threshold;
	vec3 emission;
	vec3 normal;
	vec3 binormal;
	vec3 tangent;
	vec3 specular_light;
	vec3 diffuse_light;
	vec3 ambient_light;
	vec3 light_vertex;
	uint orms;
	float ao;
	float ao_light_affect;
	float metallic;
	float specular;
	float roughness;
	float sss_strength;
	vec4 frag_color_value;
	vec4 diffuse_buffer_value;
	vec4 specular_buffer_value;
	float premul_alpha;
	vec4 fog;
	vec3 view;
	vec3 eye_offset;
	vec3 normal_map;
	float normal_map_depth;
	mat3 model_normal_matrix;
	mat4 read_model_matrix;
	mat4 read_view_matrix;
	mat4 inv_view_matrix;
	vec2 read_viewport_size;
	vec2 screen_uv;
	float rim;
	float rim_tint;
	float clearcoat;
	float clearcoat_roughness;
	float anisotropy;
	vec2 anisotropy_flow;
	vec3 backlight;
	vec4 custom_radiance;
	vec4 custom_irradiance;
	vec4 transmittance_color;
	float transmittance_depth;
	float transmittance_boost;
	float alpha_hash_scale;
	float alpha_antialiasing_edge;
	vec2 alpha_texture_coordinate;
	vec3 f0;

	// Common (or presumed to be) initialization to all variants.
	vertex = vertex_interp;
	albedo = vec3(1.0);
	alpha = 1.0;
	sss_strength = 0.0;
	read_model_matrix = instances.data[draw_call.instance_index].transform;
	read_view_matrix = scene_data.view_matrix;
	inv_view_matrix = scene_data.inv_view_matrix;
	read_viewport_size = scene_data.viewport_size;
	screen_uv = gl_FragCoord.xy * scene_data.screen_pixel_size;

	if (bool(instances.data[draw_call.instance_index].flags & INSTANCE_FLAGS_NON_UNIFORM_SCALE)) {
		model_normal_matrix = transpose(inverse(mat3(read_model_matrix)));
	} else {
		model_normal_matrix = mat3(read_model_matrix);
	}

	// Initialize features for each variant.
	initialize_normal();
	initialize_uv();
	initialize_uv2();
	initialize_color();
	initialize_binormal_and_tangent();
	initialize_normal_map();
	initialize_material_parameters();
	initialize_alpha_scissor_threshold();
	initialize_fog();
	initialize_lights();
	initialize_eye_offset();
	initialize_view();
	initialize_premul_alpha();
	initialize_light_vertex();
	initialize_transmittance();
	initialize_alpha_hash();
	initialize_alpha_antialiasing_edge();
	initialize_custom_radiance();
	initialize_custom_irradiance();
	initialize_light_backlight();
	initialize_light_rim();

	// Transform some of the inputs according to the variant.
	check_normal_side();
	clear_translation_if_double_precision();

	// User shader code.
	{
#CODE : FRAGMENT
	}

	// Compute attributes again after user shader code.
	set_vertex_from_light_vertex();
	initialize_view();
	set_transmittance_alpha();

	// Alpha discard checks.
	alpha_scissor_check();
	alpha_hash_check();
	clear_alpha_scissor_or_hash_if_not_using_edge_antialiasing();
	adjust_edge_antialiasing_if_using_alpha_scissor();
	set_alpha_if_using_edge_antialiasing();
	opaque_prepass_alpha_check();
	clip_alpha_check();

	// Compute normals, fog and decals.
	compute_normal_from_normal_map();
	compute_tangent_and_binormal_with_anisotropy();
	compute_fog();
	compute_decals();

	// Modify attributes before lighting.
	apply_roughness_limiter();
	apply_emission_exposure_normalization();

	// Compute lighting.
	compute_reflection_cubemap();
	apply_custom_radiance();
	apply_ambient_light_from_scene();
	apply_custom_irradiance();
	apply_light_clearcoat();
	apply_lightmap();
	compute_reflection_probes();
	finalize_ambient_light();
	convert_ambient_occlusion();
	compute_f0();
	compute_reflection_specular_light();
	apply_vertex_lighting();
	pack_orms();
	compute_lights();
	finalize_lights();

	// Shadow to opacity.
	apply_shadow_to_opacity();
	alpha_scissor_check_if_shadow_to_opacity();

	// Write to fragment color.
	write_frag_color_value_if_unshaded();
	write_frag_color_value_if_shaded();
	apply_fog_to_frag_color_value();
	write_frag_color();
	apply_premul_alpha();

	// Material target.
	write_material_buffers();

	//
	// Optimization snippets:
	//   Packing and unpacking fog, presumably to save on VGPRs.
	//   fog = vec4(unpackHalf2x16(fog_rg), unpackHalf2x16(fog_ba));
	//   uint fog_rg = packHalf2x16(fog.rg);
	//   uint fog_ba = packHalf2x16(fog.ba);
}
