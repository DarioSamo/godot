/**************************************************************************/
/*  rendering_shader_container_metal.h                                    */
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

#pragma once

#import "sha256_digest.h"

#import "servers/rendering/rendering_device_driver.h"
#import "servers/rendering/rendering_shader_container.h"

struct ShaderCacheEntry;
class MetalDeviceProperties;

constexpr uint32_t R32UI_ALIGNMENT_CONSTANT_ID = 65535;

class RenderingShaderContainerFormatMetal;

class RenderingShaderContainerMetal : public RenderingShaderContainer {
	GDCLASS(RenderingShaderContainerMetal, RenderingShaderContainer);

public:
	struct HeaderData {
		enum Flags : uint32_t {
			NONE = 0,
			NEEDS_VIEW_MASK_BUFFER = 1 << 0,
			USES_ARGUMENT_BUFFERS = 1 << 1,
		};

		// The Metal language version specified when compiling SPIR-V to MSL.
		// Format is major * 10000 + minor * 100 + patch.
		uint32_t msl_version = UINT32_MAX;
		uint32_t flags = NONE;

		bool needs_view_mask_buffer() const {
			return flags & NEEDS_VIEW_MASK_BUFFER;
		}

		void set_needs_view_mask_buffer(bool p_value) {
			if (p_value) {
				flags |= NEEDS_VIEW_MASK_BUFFER;
			} else {
				flags &= ~NEEDS_VIEW_MASK_BUFFER;
			}
		}

		bool uses_argument_buffers() const {
			return flags & USES_ARGUMENT_BUFFERS;
		}

		void set_uses_argument_buffers(bool p_value) {
			if (p_value) {
				flags |= USES_ARGUMENT_BUFFERS;
			} else {
				flags &= ~USES_ARGUMENT_BUFFERS;
			}
		}
	};

	struct StageData {
		uint32_t vertex_input_binding_mask = 0;
		uint32_t is_position_invariant = 0;
		uint32_t supports_fast_math = 0;
		SHA256Digest hash;
		uint32_t source_size = 0;
		uint32_t library_size = 0;
		uint32_t push_constant_binding = UINT32_MAX; // Metal binding
	};

	struct BindingInfoData {
		uint32_t shader_stage = UINT32_MAX;
		uint32_t data_type = 0; // MTLDataTypeNone
		uint32_t index = 0;
		uint32_t access = 0; // MTLBindingAccessReadOnly
		uint32_t usage = 0; // MTLResourceUsage (none)
		uint32_t texture_type = 2; // MTLTextureType2D
		uint32_t image_format = 0;
		uint32_t array_length = 0;
		uint32_t is_multisampled = 0;
	};

	struct UniformData2 {
		static constexpr uint32_t STAGE_INDEX[RenderingDeviceCommons::SHADER_STAGE_MAX] = {
			0, // SHADER_STAGE_VERTEX
			1, // SHADER_STAGE_FRAGMENT
			0, // SHADER_STAGE_TESSELATION_CONTROL
			1, // SHADER_STAGE_TESSELATION_EVALUATION
			0, // SHADER_STAGE_COMPUTE
		};

		/// Specifies the stages the uniform data is
		/// used by the Metal shader.
		uint32_t active_stages = 0;
		BindingInfoData bindings[2];
		BindingInfoData bindings_secondary[2];

		_FORCE_INLINE_ uint32_t get_index_for_stage(RenderingDeviceCommons::ShaderStage p_stage) const {
			return STAGE_INDEX[p_stage];
		}

		_FORCE_INLINE_ BindingInfoData &get_binding_for_stage(RenderingDeviceCommons::ShaderStage p_stage) {
			BindingInfoData &info = bindings[get_index_for_stage(p_stage)];
			DEV_ASSERT(info.shader_stage == UINT32_MAX || info.shader_stage == p_stage);
			info.shader_stage = p_stage;
			return info;
		}

		_FORCE_INLINE_ BindingInfoData &get_secondary_binding_for_stage(RenderingDeviceCommons::ShaderStage p_stage) {
			BindingInfoData &info = bindings_secondary[get_index_for_stage(p_stage)];
			DEV_ASSERT(info.shader_stage == UINT32_MAX || info.shader_stage == p_stage);
			info.shader_stage = p_stage;
			return info;
		}
	};

	struct SpecializationData {
		uint32_t used_stages = 0;
	};

	HeaderData mtl_reflection_data; // compliment to reflection_data
	Vector<StageData> mtl_shaders; // compliment to shaders
	Vector<UniformData2> mtl_reflection_binding_set_uniforms_data; // compliment to reflection_binding_set_uniforms_data
	Vector<SpecializationData> mtl_reflection_specialization_data; // compliment to reflection_specialization_data

private:
	RenderingShaderContainerFormatMetal *owner = nullptr;
	bool export_mode = false;

	Error compile_metal_source(const char *p_source, const StageData &p_stage_data, Vector<uint8_t> r_binary_data);

public:
	static constexpr uint32_t FORMAT_VERSION = 1;

	RDD::ShaderID create_shader(const Vector<RDD::ImmutableSampler> &p_immutable_samplers);

	void set_owner(const RenderingShaderContainerFormatMetal *p_owner) { owner = (RenderingShaderContainerFormatMetal *)p_owner; }
	void set_export_mode(bool p_export_mode) { export_mode = p_export_mode; }

protected:
	virtual uint32_t _from_bytes_reflection_extra_data(const uint8_t *p_bytes) override;
	virtual uint32_t _from_bytes_reflection_binding_uniform_extra_data_start(const uint8_t *p_bytes) override;
	virtual uint32_t _from_bytes_reflection_binding_uniform_extra_data(const uint8_t *p_bytes, uint32_t p_index) override;
	virtual uint32_t _from_bytes_reflection_specialization_extra_data_start(const uint8_t *p_bytes) override;
	virtual uint32_t _from_bytes_reflection_specialization_extra_data(const uint8_t *p_bytes, uint32_t p_index) override;
	virtual uint32_t _from_bytes_shader_extra_data_start(const uint8_t *p_bytes) override;
	virtual uint32_t _from_bytes_shader_extra_data(const uint8_t *p_bytes, uint32_t p_index) override;

	virtual uint32_t _to_bytes_reflection_extra_data(uint8_t *p_bytes) const override;
	virtual uint32_t _to_bytes_reflection_binding_uniform_extra_data(uint8_t *p_bytes, uint32_t p_index) const override;
	virtual uint32_t _to_bytes_reflection_specialization_extra_data(uint8_t *p_bytes, uint32_t p_index) const override;
	virtual uint32_t _to_bytes_shader_extra_data(uint8_t *p_bytes, uint32_t p_index) const override;

	virtual uint32_t _format() const override;
	virtual uint32_t _format_version() const override;
	virtual bool _set_code_from_spirv(const Vector<RenderingDeviceCommons::ShaderStageSPIRVData> &p_spirv) override;

#pragma mark - Serialisation
};

class RenderingShaderContainerFormatMetal : public RenderingShaderContainerFormat {
	friend class RenderingShaderContainerMetal;

	bool export_mode = false;

	MetalDeviceProperties *device_properties = nullptr;

public:
	virtual Ref<RenderingShaderContainer> create_container() const override;
	virtual ShaderLanguageVersion get_shader_language_version() const override;
	virtual ShaderSpirvVersion get_shader_spirv_version() const override;
	RenderingShaderContainerFormatMetal(bool p_export = false);
	virtual ~RenderingShaderContainerFormatMetal() = default;
};
