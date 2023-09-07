/**************************************************************************/
/*  taa.cpp                                                               */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "taa.h"
#include "servers/rendering/renderer_rd/effects/copy_effects.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

TAA::TAA() {
	Vector<String> taa_modes;
	taa_modes.push_back("\n#define MODE_TAA_RESOLVE");
	taa_shader.initialize(taa_modes);
	shader_version = taa_shader.version_create();
	pipeline = RD::get_singleton()->compute_pipeline_create(taa_shader.version_get_shader(shader_version, 0));
	constants_buffer = RD::get_singleton()->uniform_buffer_create(sizeof(TAAConstants));
}

TAA::~TAA() {
	RD::get_singleton()->free(constants_buffer);

	taa_shader.version_free(shader_version);
}

void TAA::resolve(RID p_frame, RID p_temp, RID p_depth, RID p_prev_depth, RID p_velocity, RID p_prev_velocity, RID p_history, Size2 p_resolution, float p_z_near, float p_z_far, const Projection &p_reprojection, const Projection &p_prev_reprojection, Vector2 p_jitter) {
	UniformSetCacheRD *uniform_set_cache = UniformSetCacheRD::get_singleton();
	ERR_FAIL_NULL(uniform_set_cache);
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	ERR_FAIL_NULL(material_storage);

	RID shader = taa_shader.version_get_shader(shader_version, 0);
	ERR_FAIL_COND(shader.is_null());

	RID default_sampler = material_storage->sampler_rd_get_default(RS::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RS::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	TAAResolvePushConstant push_constant;
	push_constant.resolution[0] = p_resolution.width;
	push_constant.resolution[1] = p_resolution.height;
	push_constant.jitter[0] = p_jitter.x;
	push_constant.jitter[1] = p_jitter.y;
	push_constant.disocclusion_threshold = 0.025f;
	push_constant.disocclusion_scale = 10.0f;

	TAAConstants constants;
	RendererRD::MaterialStorage::store_camera(p_reprojection, constants.reprojection_matrix);
	RendererRD::MaterialStorage::store_camera(p_prev_reprojection, constants.last_reprojection_matrix);
	RD::get_singleton()->buffer_update(constants_buffer, 0, sizeof(TAAConstants), &constants, RD::BARRIER_MASK_COMPUTE);

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipeline);

	RD::Uniform u_frame_source(RD::UNIFORM_TYPE_IMAGE, 0, { p_frame });
	RD::Uniform u_depth(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, { default_sampler, p_depth });
	RD::Uniform u_prev_depth(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, { default_sampler, p_prev_depth });
	RD::Uniform u_velocity(RD::UNIFORM_TYPE_IMAGE, 3, { p_velocity });
	RD::Uniform u_prev_velocity(RD::UNIFORM_TYPE_IMAGE, 4, { p_prev_velocity });
	RD::Uniform u_history(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 5, { default_sampler, p_history });
	RD::Uniform u_frame_dest(RD::UNIFORM_TYPE_IMAGE, 6, { p_temp });
	RD::Uniform u_reprojection_buffer(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 7, { constants_buffer });

	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(shader, 0, u_frame_source, u_depth, u_prev_depth, u_velocity, u_prev_velocity, u_history, u_frame_dest, u_reprojection_buffer), 0);
	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(TAAResolvePushConstant));
	RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_resolution.width, p_resolution.height, 1);
	RD::get_singleton()->compute_list_end();
}

void TAA::process(Ref<RenderSceneBuffersRD> p_render_buffers, RD::DataFormat p_format, float p_z_near, float p_z_far, const Projection &p_reprojection, Vector2 p_jitter) {
	if (!p_render_buffers->has_previous_internal_texture()) {
		return;
	}

	uint32_t view_count = p_render_buffers->get_view_count();
	Size2i internal_size = p_render_buffers->get_internal_size();

	RD::get_singleton()->draw_command_begin_label("TAA");

	for (uint32_t v = 0; v < view_count; v++) {
		RID current_color = p_render_buffers->get_internal_texture(v);
		RID previous_color = p_render_buffers->get_previous_internal_texture(v);
		RID velocity_buffer = p_render_buffers->get_velocity_buffer(false, v);
		RID prev_velocity_buffer = p_render_buffers->get_previous_velocity_buffer(v);
		RID depth_texture = p_render_buffers->get_depth_texture(v);
		RID prev_depth_texture = p_render_buffers->get_previous_depth_texture(v);

		// Advance to the next color texture and use it as the output of the TAA resolve.
		p_render_buffers->advance_color_buffer();
		p_render_buffers->ensure_color();
		RID next_color = p_render_buffers->get_internal_texture(v);

		resolve(current_color, next_color, depth_texture, prev_depth_texture, velocity_buffer, prev_velocity_buffer, previous_color, Size2(internal_size.x, internal_size.y), p_z_near, p_z_far, p_reprojection, last_reprojection, p_jitter);
	}

	RD::get_singleton()->draw_command_end_label();

	last_reprojection = p_reprojection;
}
