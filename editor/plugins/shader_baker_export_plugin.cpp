/**************************************************************************/
/*  shader_baker_export_plugin.cpp                                        */
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

#include "shader_baker_export_plugin.h"

#include "core/config/project_settings.h"
#include "drivers/vulkan/rendering_shader_container_vulkan.h"
#include "servers/rendering/renderer_rd/forward_clustered/scene_shader_forward_clustered.h"
#include "servers/rendering/renderer_rd/forward_mobile/scene_shader_forward_mobile.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"

#ifdef D3D12_ENABLED
#include "drivers/d3d12/rendering_shader_container_d3d12.h"
#include <Windows.h>
#endif

// TODO:
// - Optimized embedded shader export by finding out how to group and wait for the tasks.

String ShaderBakerExportPlugin::get_name() const {
	return "ShaderBaker";
}

bool ShaderBakerExportPlugin::_initialize_container_format(const Ref<EditorExportPlatform> &p_platform, const Vector<String> &p_features) {
	String driver = GLOBAL_GET("rendering/rendering_device/driver." + p_platform->get_os_name().to_lower());
	if (driver.is_empty()) {
		driver = GLOBAL_GET("rendering/rendering_device/driver");
	}

	if (driver == "vulkan") {
		shader_container_format = memnew(RenderingShaderContainerFormatVulkan);
#ifdef D3D12_ENABLED
	} else if (driver == "d3d12") {
		if (lib_d3d12 == nullptr) {
			lib_d3d12 = LoadLibraryW(L"D3D12.dll");
			ERR_FAIL_NULL_V_MSG(lib_d3d12, false, "Unable to load D3D12.dll.");
		}

		constexpr uint32_t required_shader_model = 0x60; // D3D_SHADER_MODEL_6_0
		RenderingShaderContainerFormatD3D12 *shader_container_format_d3d12 = memnew(RenderingShaderContainerFormatD3D12);
		shader_container_format_d3d12->set_lib_d3d12(lib_d3d12);
		shader_container_format_d3d12->set_shader_model(required_shader_model);
		shader_container_format = shader_container_format_d3d12;
#endif
	} else if (driver == "metal") {
		DEV_ASSERT(false && "Unimplemented.");
		return false;
	} else {
		// Unknown driver, shaders can't be baked for it.
		return false;
	}

	return true;
}

bool ShaderBakerExportPlugin::_begin_customize_resources(const Ref<EditorExportPlatform> &p_platform, const Vector<String> &p_features) {
	RendererRD::MaterialStorage *singleton = RendererRD::MaterialStorage::get_singleton();
	if (singleton == nullptr) {
		// Shader baker should only work when a RendererRD driver is active, as the embedded shaders won't be found otherwise.
		return false;
	}

	bool initialized = _initialize_container_format(p_platform, p_features);
	if (!initialized) {
		return false;
	}

	// TODO: Renderer-specific groups that are enabled at runtime should get enabled here.

	ShaderRD::shaders_embedded_set_lock();
	const ShaderRD::ShaderVersionPairSet &pair_set = ShaderRD::shaders_embedded_set_get();
	for (Pair<ShaderRD *, RID> pair : pair_set) {
		_customize_shader_version(pair.first, pair.second);
	}

	ShaderRD::shaders_embedded_set_unlock();

	return true;
}

void ShaderBakerExportPlugin::_end_customize_resources() {
	for (const ShaderGroupItem &group_item : shader_group_items) {
		// Wait for all shader compilation tasks of the group to be finished.
		for (WorkerThreadPool::TaskID task_id : group_item.variant_tasks) {
			WorkerThreadPool::get_singleton()->wait_for_task_completion(task_id);
		}

		WorkResult work_result;
		{
			MutexLock lock(shader_work_results_mutex);
			work_result = shader_work_results[group_item.cache_path];
		}

		PackedByteArray cache_file_bytes = ShaderRD::save_shader_cache_bytes(group_item.variants, work_result.variant_data);
		add_file(group_item.cache_path, cache_file_bytes, false);
	}

	shader_paths_processed.clear();
	shader_work_results.clear();
	shader_group_items.clear();
}

Ref<Resource> ShaderBakerExportPlugin::_customize_resource(const Ref<Resource> &p_resource, const String &p_path) {
	RendererRD::MaterialStorage *singleton = RendererRD::MaterialStorage::get_singleton();
	DEV_ASSERT(singleton != nullptr);

	Material *material = Object::cast_to<Material>(*p_resource);
	if (material != nullptr) {
		RID material_rid = material->get_rid();
		if (material_rid.is_valid()) {
			RendererRD::MaterialStorage::ShaderData *shader_data = singleton->material_get_shader_data(material_rid);
			if (shader_data != nullptr) {
				Pair<ShaderRD *, RID> shader_version_pair = shader_data->get_native_shader_and_version();
				if (shader_version_pair.first != nullptr) {
					_customize_shader_version(shader_version_pair.first, shader_version_pair.second);
				}
			}
		}
	}

	return Ref<Resource>();
}

uint64_t ShaderBakerExportPlugin::_get_customization_configuration_hash() const {
	// TODO: Always forces everything to be re-checked. This can be disabled later.
	uint64_t hash = OS::get_singleton()->get_ticks_usec();
	return hash;
}

void ShaderBakerExportPlugin::_customize_shader_version(ShaderRD *p_shader, RID p_version) {
	const int64_t variant_count = p_shader->get_variant_count();
	const int64_t group_count = p_shader->get_group_count();
	LocalVector<ShaderGroupItem> group_items;
	group_items.resize(group_count);

	RBSet<uint32_t> groups_to_compile;
	for (int64_t i = 0; i < group_count; i++) {
		if (!p_shader->is_group_enabled(i)) {
			continue;
		}

		String cache_file_path = p_shader->version_get_cache_file_path(p_version, i);
		if (shader_paths_processed.has(cache_file_path)) {
			continue;
		}

		shader_paths_processed.insert(cache_file_path);
		groups_to_compile.insert(i);

		String cache_path = p_shader->version_get_cache_file_path(p_version, i);
		group_items[i].cache_path = cache_path;
		group_items[i].variants = p_shader->get_group_to_variants(i);

		{
			MutexLock lock(shader_work_results_mutex);
			shader_work_results[cache_path].variant_data.resize(variant_count);
		}
	}

	for (int64_t i = 0; i < variant_count; i++) {
		int group = p_shader->get_variant_to_group(i);
		if (!p_shader->is_variant_enabled(i) || !groups_to_compile.has(group)) {
			continue;
		}

		WorkItem work_item;
		work_item.cache_path = group_items[group].cache_path;
		work_item.shader_name = p_shader->get_name();
		work_item.stage_sources = p_shader->version_build_variant_stage_sources(p_version, i);
		work_item.variant = i;

		WorkerThreadPool::TaskID task_id = WorkerThreadPool::get_singleton()->add_template_task(this, &ShaderBakerExportPlugin::_process_work_item, work_item, &work_item);
		group_items[group].variant_tasks.push_back(task_id);
	}

	for (uint32_t i : groups_to_compile) {
		shader_group_items.push_back(group_items[i]);
	}
}

void ShaderBakerExportPlugin::_process_work_item(WorkItem p_work_item) {
	// Compile SPIR-V data.
	Vector<RD::ShaderStageSPIRVData> spirv_data = ShaderRD::compile_stages(p_work_item.stage_sources);
	ERR_FAIL_COND_MSG(spirv_data.is_empty(), "Unable to retrieve SPIR-V data for shader");

	RD::ShaderReflection shader_refl;
	Error err = RenderingDeviceCommons::reflect_spirv(spirv_data, shader_refl);
	ERR_FAIL_COND_MSG(err != OK, "Unable to reflect SPIR-V data that was compiled");

	Ref<RenderingShaderContainer> shader_container = shader_container_format->create_container();
	shader_container->set_from_shader_reflection(p_work_item.shader_name, shader_refl);

	// Compile shader binary from SPIR-V.
	bool code_compiled = shader_container->set_code_from_spirv(spirv_data, {});
	ERR_FAIL_COND_MSG(!code_compiled, vformat("Failed to compile code to native for SPIR-V."));

	PackedByteArray shader_bytes = shader_container->to_bytes();
	{
		MutexLock lock(shader_work_results_mutex);
		shader_work_results[p_work_item.cache_path].variant_data.ptrw()[p_work_item.variant] = shader_bytes;
	}
}

ShaderBakerExportPlugin::ShaderBakerExportPlugin() {
	// Do nothing.
}

ShaderBakerExportPlugin::~ShaderBakerExportPlugin() {
	if (shader_container_format != nullptr) {
		memdelete(shader_container_format);
	}

#ifdef D3D12_ENABLED
	if (lib_d3d12) {
		FreeLibrary((HMODULE)(lib_d3d12));
	}
#endif
}
