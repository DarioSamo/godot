/**************************************************************************/
/*  fsr.h                                                                 */
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

#ifndef FSR2_RD_H
#define FSR2_RD_H

#include "../storage_rd/render_scene_buffers_rd.h"

#include <ffx_fsr2.h>

namespace RendererRD {

class FSR2 {
public:
	struct Parameters {
		Ref<RenderSceneBuffersRD> render_buffers;
		RID color;
		RID depth;
		RID velocity;
		RID output;
		float z_near = 0.0f;
		float z_far = 0.0f;
		float fovy = 0.0f;
		Vector2 jitter;
		float delta_time = 0.0f;
		bool reset_accumulation = false;
	};

	FSR2();
	~FSR2();
	void destroy();
	FfxResource get_resource(RID p_texture, const wchar_t *p_name = nullptr, FfxResourceStates p_state = FFX_RESOURCE_STATE_COMPUTE_READ);
	void upscale(const Parameters &p_params);
private:
	Vector<uint8_t> scratch_data;
	FfxFsr2Context fsr_context;
	FfxFsr2ContextDescription fsr_desc;
	Size2i render_size;
	Size2i display_size;
	bool fsr_initialized;
	bool fsr_created;
};

} // namespace RendererRD

#endif // FSR2_RD_H
