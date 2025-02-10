/**************************************************************************/
/*  rendering_shader_container_vulkan.cpp                                 */
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

#include "rendering_shader_container_vulkan.h"

#include "thirdparty/misc/smolv.h"

// RenderingShaderContainerVulkan

const uint32_t RenderingShaderContainerVulkan::FORMAT_VERSION = 1;

uint32_t RenderingShaderContainerVulkan::_format() const {
	return 0x43565053;
}

uint32_t RenderingShaderContainerVulkan::_format_version() const {
	return FORMAT_VERSION;
}

bool RenderingShaderContainerVulkan::_set_code_from_spirv(const Vector<RenderingDeviceCommons::ShaderStageSPIRVData> &p_spirv) {
	smolv::ByteArray smolv_bytes;
	PackedByteArray code_bytes;
	shaders.resize(p_spirv.size());
	for (int64_t i = 0; i < p_spirv.size(); i++) {
		// smolv::Encode does not clear the array on its own. It is necessary to do this manually if capacity is reused between stages.
		smolv_bytes.clear();

		// Encode into smolv.
		bool smolv_encoded = smolv::Encode(p_spirv[i].spirv.ptr(), p_spirv[i].spirv.size(), smolv_bytes, smolv::kEncodeFlagStripDebugInfo);
		ERR_FAIL_COND_V_MSG(!smolv_encoded, false, "Failed to compress SPIR-V into smolv.");

		code_bytes.resize(smolv_bytes.size());
		memcpy(code_bytes.ptrw(), smolv_bytes.data(), code_bytes.size());

		RenderingShaderContainer::Shader &shader = shaders.ptrw()[i];
		uint32_t compressed_size = 0;
		shader.code_decompressed_size = code_bytes.size();
		shader.code_compressed_bytes.resize(code_bytes.size());

		bool compressed = compress_code(code_bytes.ptr(), code_bytes.size(), shader.code_compressed_bytes.ptrw(), &compressed_size, &shader.code_compression_flags);
		ERR_FAIL_COND_V_MSG(!compressed, false, vformat("Failed to compress native code to native for SPIR-V #%d.", i));

		shader.code_compressed_bytes.resize(compressed_size);
	}

	return true;
}

// RenderingShaderContainerFormatVulkan

Ref<RenderingShaderContainer> RenderingShaderContainerFormatVulkan::create_container() const {
	return memnew(RenderingShaderContainerVulkan);
}

RenderingShaderContainerFormatVulkan::RenderingShaderContainerFormatVulkan() {}

RenderingShaderContainerFormatVulkan::~RenderingShaderContainerFormatVulkan() {}
