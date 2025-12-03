// Sourced from https://github.com/LouisBavoil/ThreadGroupIDSwizzling/blob/master/ThreadGroupTilingX.hlsl

uvec2 swizzled_global_invocation_id() {
	const uint max_tile_width = 16;
	const uint thread_groups_in_perfect_tile = max_tile_width * gl_NumWorkGroups.y;
	const uint perfect_tiles = gl_NumWorkGroups.x / max_tile_width;
	const uint thread_group_id_flattened = gl_NumWorkGroups.x * gl_WorkGroupID.y + gl_WorkGroupID.x;
	const uint tile_id_current_thread_group = thread_group_id_flattened / thread_groups_in_perfect_tile;
	const uint local_thread_group_id_current_tile = thread_group_id_flattened % thread_groups_in_perfect_tile;
	uint local_thread_group_id_x_current_tile;
	uint local_thread_group_id_y_current_tile;
	const uint thread_groups_in_all_perfect_tiles = perfect_tiles * max_tile_width * gl_NumWorkGroups.y;
	if (thread_groups_in_all_perfect_tiles <= thread_group_id_flattened) {
		uint x_dimension_of_last_tile = gl_NumWorkGroups.x % max_tile_width;
		local_thread_group_id_y_current_tile = local_thread_group_id_current_tile / x_dimension_of_last_tile;
		local_thread_group_id_x_current_tile = local_thread_group_id_current_tile % x_dimension_of_last_tile;
	} else {
		local_thread_group_id_y_current_tile = local_thread_group_id_current_tile / max_tile_width;
		local_thread_group_id_x_current_tile = local_thread_group_id_current_tile % max_tile_width;
	}

	uint swizzled_thread_group_id_flattened = tile_id_current_thread_group * max_tile_width;
	swizzled_thread_group_id_flattened += local_thread_group_id_y_current_tile * gl_NumWorkGroups.x;
	swizzled_thread_group_id_flattened += local_thread_group_id_x_current_tile;

	uvec2 swizzled_thread_group_id;
	swizzled_thread_group_id.y = swizzled_thread_group_id_flattened / gl_NumWorkGroups.x;
	swizzled_thread_group_id.x = swizzled_thread_group_id_flattened % gl_NumWorkGroups.x;

	uvec2 swizzled_thread_id;
	swizzled_thread_id.x = gl_WorkGroupSize.x * swizzled_thread_group_id.x + gl_LocalInvocationID.x;
	swizzled_thread_id.y = gl_WorkGroupSize.y * swizzled_thread_group_id.y + gl_LocalInvocationID.y;
	return swizzled_thread_id;
}
