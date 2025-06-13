// Copyright 2016 Activision Publishing, Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the Software
// is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#[compute]

#version 450

#VERSION_DEFINES

#define BLOCK_SIZE 8

#include "../oct_inc.glsl"

layout(local_size_x = BLOCK_SIZE, local_size_y = BLOCK_SIZE, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_octmap;

layout(rgba16f, set = 1, binding = 0) uniform restrict writeonly image2D dest_octmap;

layout(push_constant, std430) uniform Params {
	uint size;
}
params;

void main() {
	uvec2 id = gl_GlobalInvocationID.xy;
	if (id.x < params.size && id.y < params.size) {
		vec2 uv = (vec2(id.xy) + vec2(0.5)) / vec2(params.size);
		imageStore(dest_octmap, ivec2(id), textureLod(source_octmap, uv, 0.0));
	}
}
