/**************************************************************************/
/*  fsr2.cpp                                                               */
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

#include "fsr2.h"

#include "../storage_rd/material_storage.h"
#include "../uniform_set_cache_rd.h"

#include <vk/ffx_fsr2_vk.h>

using namespace RendererRD;

FSR2::FSR2() {
	render_size = Size2i(0, 0);
	display_size = Size2i(0, 0);
	fsr_created = false;
	fsr_initialized = false;
}

FSR2::~FSR2() {
	destroy();
}

void FSR2::destroy() {
	if (fsr_created) {
		ffxFsr2ContextDestroy(&fsr_context);
		fsr_created = false;
	}
}

FfxResource FSR2::get_resource(RID p_texture, const wchar_t *p_name, FfxResourceStates p_state) {
	VkImage image = VkImage(RD::get_singleton()->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_VULKAN_IMAGE, p_texture));
	VkImageView image_view = VkImageView(RD::get_singleton()->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_VULKAN_IMAGE_VIEW, p_texture));
	VkFormat image_format = VkFormat(RD::get_singleton()->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_VULKAN_IMAGE_NATIVE_TEXTURE_FORMAT, p_texture));
	Size2i image_size = RD::get_singleton()->texture_size(p_texture);
	return ffxGetTextureResourceVK(&fsr_context, image, image_view, image_size.width, image_size.height, image_format, p_name, p_state);
}

void FSR2::upscale(const Parameters &p_params) {
	Size2i internal_size = p_params.render_buffers->get_internal_size();
	Size2i target_size = p_params.render_buffers->get_target_size();
	bool recreate_fsr = !fsr_created || (render_size != internal_size) || (display_size != target_size);
	if (recreate_fsr) {
		if (!fsr_initialized) {
			VkPhysicalDevice physical_device = reinterpret_cast<VkPhysicalDevice>(RD::get_singleton()->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_VULKAN_PHYSICAL_DEVICE));

			size_t scratch_size = ffxFsr2GetScratchMemorySizeVK(physical_device);
			scratch_data.resize(scratch_size);

			FfxErrorCode result = ffxFsr2GetInterfaceVK(&fsr_desc.callbacks, scratch_data.ptrw(), scratch_size, physical_device, vkGetDeviceProcAddr);
			fsr_initialized = (result == FFX_OK);
			ERR_FAIL_COND(!fsr_initialized);
		}

		if (fsr_initialized) {
			VkDevice device = VkDevice(RD::get_singleton()->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_VULKAN_DEVICE));
			render_size = internal_size;
			display_size = target_size;
			fsr_desc.flags = 0;
			fsr_desc.maxRenderSize.width = render_size.x;
			fsr_desc.maxRenderSize.height = render_size.y;
			fsr_desc.displaySize.width = display_size.x;
			fsr_desc.displaySize.height = display_size.y;
			fsr_desc.device = ffxGetDeviceVK(device);
			
			FfxErrorCode result = ffxFsr2ContextCreate(&fsr_context, &fsr_desc);
			fsr_created = (result == FFX_OK);
			ERR_FAIL_COND(!fsr_created);
		}
	}
	
	if (fsr_created) {
		// TODO: Previous resource states? See if Vulkan validation layer is throwing errors about it.
		// FIXME: Reactive buffer (animated textures).
		// FIXME: Transparency and composition buffer.
		VkCommandBuffer draw_command_buffer = VkCommandBuffer(RD::get_singleton()->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_VULKAN_DRAW_COMMAND_BUFFER));
		FfxFsr2DispatchDescription dispatch_desc = { 0 };
		dispatch_desc.commandList = ffxGetCommandListVK(draw_command_buffer);
		dispatch_desc.color = get_resource(p_params.color, L"color");
		dispatch_desc.depth = get_resource(p_params.depth, L"depth");
		dispatch_desc.motionVectors = get_resource(p_params.velocity, L"velocity");
		dispatch_desc.exposure = { 0 };
		dispatch_desc.reactive = { 0 };
		dispatch_desc.transparencyAndComposition = { 0 };
		dispatch_desc.output = get_resource(p_params.output, L"output");
		dispatch_desc.colorOpaqueOnly = { 0 };
		dispatch_desc.jitterOffset.x = p_params.jitter.x;
		dispatch_desc.jitterOffset.y = p_params.jitter.y;
		dispatch_desc.motionVectorScale.x = -float(internal_size.width);
		dispatch_desc.motionVectorScale.y = -float(internal_size.height);
		dispatch_desc.reset = p_params.reset_accumulation;
		dispatch_desc.renderSize.width = render_size.width;
		dispatch_desc.renderSize.height = render_size.height;
		dispatch_desc.enableSharpening = false;
		dispatch_desc.sharpness = p_params.render_buffers->get_fsr_sharpness();
		dispatch_desc.frameTimeDelta = p_params.delta_time;
		dispatch_desc.preExposure = 1.0f;
		dispatch_desc.cameraNear = p_params.z_near;
		dispatch_desc.cameraFar = p_params.z_far;
		dispatch_desc.cameraFovAngleVertical = p_params.fovy;
		dispatch_desc.viewSpaceToMetersFactor = 1.0f;
		dispatch_desc.enableAutoReactive = false;
		dispatch_desc.autoTcThreshold = 1.0f;
		dispatch_desc.autoTcScale = 1.0f;
		dispatch_desc.autoReactiveScale = 1.0f;
		dispatch_desc.autoReactiveMax = 1.0f;
		FfxErrorCode result = ffxFsr2ContextDispatch(&fsr_context, &dispatch_desc);
		ERR_FAIL_COND(result != FFX_OK);
	}
}
