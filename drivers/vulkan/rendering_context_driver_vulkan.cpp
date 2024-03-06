/**************************************************************************/
/*  rendering_context_driver_vulkan.cpp                                   */
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

#ifdef VULKAN_ENABLED

#include "rendering_context_driver_vulkan.h"

#include "vk_enum_string_helper.h"

#include "core/config/project_settings.h"
#include "core/version.h"

#include "rendering_device_driver_vulkan.h"
#include "vulkan_hooks.h"

// Note: symbols are not available in MinGW and old MSVC import libraries.
// GUID values from https://github.com/microsoft/DirectX-Headers/blob/7a9f4d06911d30eecb56a4956dab29dcca2709ed/include/directx/d3d12.idl#L5877-L5881
const GUID CLSID_D3D12DeviceFactoryGodot = { 0x114863bf, 0xc386, 0x4aee, { 0xb3, 0x9d, 0x8f, 0x0b, 0xbb, 0x06, 0x29, 0x55 } };
const GUID CLSID_D3D12DebugGodot = { 0xf2352aeb, 0xdd84, 0x49fe, { 0xb9, 0x7b, 0xa9, 0xdc, 0xfd, 0xcc, 0x1b, 0x4f } };
const GUID CLSID_D3D12SDKConfigurationGodot = { 0x7cda6aca, 0xa03e, 0x49c8, { 0x94, 0x58, 0x03, 0x34, 0xd2, 0x0e, 0x07, 0xce } };

RenderingContextDriverVulkan::RenderingContextDriverVulkan() {
	// Empty constructor.
}

RenderingContextDriverVulkan::~RenderingContextDriverVulkan() {
	if (debug_messenger != VK_NULL_HANDLE && functions.DestroyDebugUtilsMessengerEXT != nullptr) {
		functions.DestroyDebugUtilsMessengerEXT(instance, debug_messenger, nullptr);
	}

	if (debug_report != VK_NULL_HANDLE && functions.DestroyDebugReportCallbackEXT != nullptr) {
		functions.DestroyDebugReportCallbackEXT(instance, debug_report, nullptr);
	}

	if (instance != VK_NULL_HANDLE) {
		vkDestroyInstance(instance, nullptr);
	}

#ifdef WINDOWS_ENABLED
	if (d3d12_device_factory != nullptr) {
		d3d12_device_factory->Release();
	}

	if (dxgi_factory != nullptr) {
		dxgi_factory->Release();
	}

	if (lib_d3d12) {
		FreeLibrary(lib_d3d12);
	}

	if (lib_dxgi) {
		FreeLibrary(lib_dxgi);
	}
#endif
}

Error RenderingContextDriverVulkan::_initialize_vulkan_version() {
	// https://www.khronos.org/registry/vulkan/specs/1.2-extensions/man/html/VkApplicationInfo.html#_description
	// For Vulkan 1.0 vkEnumerateInstanceVersion is not available, including not in the loader we compile against on Android.
	typedef VkResult(VKAPI_PTR * _vkEnumerateInstanceVersion)(uint32_t *);
	_vkEnumerateInstanceVersion func = (_vkEnumerateInstanceVersion)vkGetInstanceProcAddr(nullptr, "vkEnumerateInstanceVersion");
	if (func != nullptr) {
		uint32_t api_version;
		VkResult res = func(&api_version);
		if (res == VK_SUCCESS) {
			instance_api_version = api_version;
		} else {
			// According to the documentation this shouldn't fail with anything except a memory allocation error
			// in which case we're in deep trouble anyway.
			ERR_FAIL_V(ERR_CANT_CREATE);
		}
	} else {
		print_line("vkEnumerateInstanceVersion not available, assuming Vulkan 1.0.");
		instance_api_version = VK_API_VERSION_1_0;
	}

	return OK;
}

void RenderingContextDriverVulkan::_register_requested_instance_extension(const CharString &p_extension_name, bool p_required) {
	ERR_FAIL_COND(requested_instance_extensions.has(p_extension_name));
	requested_instance_extensions[p_extension_name] = p_required;
}

Error RenderingContextDriverVulkan::_initialize_instance_extensions() {
	enabled_instance_extension_names.clear();

	// The surface extension and the platform-specific surface extension are core requirements.
	_register_requested_instance_extension(VK_KHR_SURFACE_EXTENSION_NAME, true);
	if (_get_platform_surface_extension()) {
		_register_requested_instance_extension(_get_platform_surface_extension(), true);
	}

	if (_use_validation_layers()) {
		_register_requested_instance_extension(VK_EXT_DEBUG_REPORT_EXTENSION_NAME, false);
	}

	// This extension allows us to use the properties2 features to query additional device capabilities.
	_register_requested_instance_extension(VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME, false);

	// Only enable debug utils in verbose mode or DEV_ENABLED.
	// End users would get spammed with messages of varying verbosity due to the
	// mess that thirdparty layers/extensions and drivers seem to leave in their
	// wake, making the Windows registry a bottomless pit of broken layer JSON.
#ifdef DEV_ENABLED
	bool want_debug_utils = true;
#else
	bool want_debug_utils = OS::get_singleton()->is_stdout_verbose();
#endif
	if (want_debug_utils) {
		_register_requested_instance_extension(VK_EXT_DEBUG_UTILS_EXTENSION_NAME, false);
	}

	// Load instance extensions that are available.
	uint32_t instance_extension_count = 0;
	VkResult err = vkEnumerateInstanceExtensionProperties(nullptr, &instance_extension_count, nullptr);
	ERR_FAIL_COND_V(err != VK_SUCCESS && err != VK_INCOMPLETE, ERR_CANT_CREATE);
	ERR_FAIL_COND_V_MSG(instance_extension_count == 0, ERR_CANT_CREATE, "No instance extensions were found.");

	TightLocalVector<VkExtensionProperties> instance_extensions;
	instance_extensions.resize(instance_extension_count);
	err = vkEnumerateInstanceExtensionProperties(nullptr, &instance_extension_count, instance_extensions.ptr());
	if (err != VK_SUCCESS && err != VK_INCOMPLETE) {
		ERR_FAIL_V(ERR_CANT_CREATE);
	}

#ifdef DEV_ENABLED
	for (uint32_t i = 0; i < instance_extension_count; i++) {
		print_verbose(String("VULKAN: Found instance extension ") + String::utf8(instance_extensions[i].extensionName) + String("."));
	}
#endif

	// Enable all extensions that are supported and requested.
	for (uint32_t i = 0; i < instance_extension_count; i++) {
		CharString extension_name(instance_extensions[i].extensionName);
		if (requested_instance_extensions.has(extension_name)) {
			enabled_instance_extension_names.insert(extension_name);
		}
	}

	// Now check our requested extensions.
	for (KeyValue<CharString, bool> &requested_extension : requested_instance_extensions) {
		if (!enabled_instance_extension_names.has(requested_extension.key)) {
			if (requested_extension.value) {
				ERR_FAIL_V_MSG(ERR_BUG, String("Required extension ") + String::utf8(requested_extension.key) + String(" not found."));
			} else {
				print_verbose(String("Optional extension ") + String::utf8(requested_extension.key) + String(" not found."));
			}
		}
	}

	return OK;
}

Error RenderingContextDriverVulkan::_find_validation_layers(TightLocalVector<const char *> &r_layer_names) const {
	r_layer_names.clear();

	uint32_t instance_layer_count = 0;
	VkResult err = vkEnumerateInstanceLayerProperties(&instance_layer_count, nullptr);
	ERR_FAIL_COND_V(err != VK_SUCCESS, ERR_CANT_CREATE);
	if (instance_layer_count > 0) {
		TightLocalVector<VkLayerProperties> layer_properties;
		layer_properties.resize(instance_layer_count);
		err = vkEnumerateInstanceLayerProperties(&instance_layer_count, layer_properties.ptr());
		ERR_FAIL_COND_V(err != VK_SUCCESS, ERR_CANT_CREATE);

		// Preferred set of validation layers.
		const std::initializer_list<const char *> preferred = { "VK_LAYER_KHRONOS_validation" };

		// Alternative (deprecated, removed in SDK 1.1.126.0) set of validation layers.
		const std::initializer_list<const char *> lunarg = { "VK_LAYER_LUNARG_standard_validation" };

		// Alternative (deprecated, removed in SDK 1.1.121.1) set of validation layers.
		const std::initializer_list<const char *> google = { "VK_LAYER_GOOGLE_threading", "VK_LAYER_LUNARG_parameter_validation", "VK_LAYER_LUNARG_object_tracker", "VK_LAYER_LUNARG_core_validation", "VK_LAYER_GOOGLE_unique_objects" };

		// Verify all the layers of the list are present.
		for (const std::initializer_list<const char *> &list : { preferred, lunarg, google }) {
			bool layers_found = false;
			for (const char *layer_name : list) {
				layers_found = false;

				for (const VkLayerProperties &properties : layer_properties) {
					if (!strcmp(properties.layerName, layer_name)) {
						layers_found = true;
						break;
					}
				}

				if (!layers_found) {
					break;
				}
			}

			if (layers_found) {
				r_layer_names.reserve(list.size());
				for (const char *layer_name : list) {
					r_layer_names.push_back(layer_name);
				}

				break;
			}
		}
	}

	return OK;
}

VKAPI_ATTR VkBool32 VKAPI_CALL RenderingContextDriverVulkan::_debug_messenger_callback(VkDebugUtilsMessageSeverityFlagBitsEXT p_message_severity, VkDebugUtilsMessageTypeFlagsEXT p_message_type, const VkDebugUtilsMessengerCallbackDataEXT *p_callback_data, void *p_user_data) {
	// This error needs to be ignored because the AMD allocator will mix up memory types on IGP processors.
	if (strstr(p_callback_data->pMessage, "Mapping an image with layout") != nullptr && strstr(p_callback_data->pMessage, "can result in undefined behavior if this memory is used by the device") != nullptr) {
		return VK_FALSE;
	}
	// This needs to be ignored because Validator is wrong here.
	if (strstr(p_callback_data->pMessage, "Invalid SPIR-V binary version 1.3") != nullptr) {
		return VK_FALSE;
	}
	// This needs to be ignored because Validator is wrong here.
	if (strstr(p_callback_data->pMessage, "Shader requires flag") != nullptr) {
		return VK_FALSE;
	}

	// This needs to be ignored because Validator is wrong here.
	if (strstr(p_callback_data->pMessage, "SPIR-V module not valid: Pointer operand") != nullptr && strstr(p_callback_data->pMessage, "must be a memory object") != nullptr) {
		return VK_FALSE;
	}

	if (p_callback_data->pMessageIdName && strstr(p_callback_data->pMessageIdName, "UNASSIGNED-CoreValidation-DrawState-ClearCmdBeforeDraw") != nullptr) {
		return VK_FALSE;
	}

	String type_string;
	switch (p_message_type) {
		case (VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT):
			type_string = "GENERAL";
			break;
		case (VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT):
			type_string = "VALIDATION";
			break;
		case (VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT):
			type_string = "PERFORMANCE";
			break;
		case (VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT & VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT):
			type_string = "VALIDATION|PERFORMANCE";
			break;
	}

	String objects_string;
	if (p_callback_data->objectCount > 0) {
		objects_string = "\n\tObjects - " + String::num_int64(p_callback_data->objectCount);
		for (uint32_t object = 0; object < p_callback_data->objectCount; ++object) {
			objects_string +=
					"\n\t\tObject[" + String::num_int64(object) + "]" +
					" - " + string_VkObjectType(p_callback_data->pObjects[object].objectType) +
					", Handle " + String::num_int64(p_callback_data->pObjects[object].objectHandle);

			if (p_callback_data->pObjects[object].pObjectName != nullptr && strlen(p_callback_data->pObjects[object].pObjectName) > 0) {
				objects_string += ", Name \"" + String(p_callback_data->pObjects[object].pObjectName) + "\"";
			}
		}
	}

	String labels_string;
	if (p_callback_data->cmdBufLabelCount > 0) {
		labels_string = "\n\tCommand Buffer Labels - " + String::num_int64(p_callback_data->cmdBufLabelCount);
		for (uint32_t cmd_buf_label = 0; cmd_buf_label < p_callback_data->cmdBufLabelCount; ++cmd_buf_label) {
			labels_string +=
					"\n\t\tLabel[" + String::num_int64(cmd_buf_label) + "]" +
					" - " + p_callback_data->pCmdBufLabels[cmd_buf_label].pLabelName +
					"{ ";

			for (int color_idx = 0; color_idx < 4; ++color_idx) {
				labels_string += String::num(p_callback_data->pCmdBufLabels[cmd_buf_label].color[color_idx]);
				if (color_idx < 3) {
					labels_string += ", ";
				}
			}

			labels_string += " }";
		}
	}

	String error_message(type_string +
			" - Message Id Number: " + String::num_int64(p_callback_data->messageIdNumber) +
			" | Message Id Name: " + p_callback_data->pMessageIdName +
			"\n\t" + p_callback_data->pMessage +
			objects_string + labels_string);

	// Convert VK severity to our own log macros.
	switch (p_message_severity) {
		case VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT:
			print_verbose(error_message);
			break;
		case VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT:
			print_line(error_message);
			break;
		case VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT:
			WARN_PRINT(error_message);
			break;
		case VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT:
			ERR_PRINT(error_message);
			CRASH_COND_MSG(Engine::get_singleton()->is_abort_on_gpu_errors_enabled(), "Crashing, because abort on GPU errors is enabled.");
			break;
		case VK_DEBUG_UTILS_MESSAGE_SEVERITY_FLAG_BITS_MAX_ENUM_EXT:
			break; // Shouldn't happen, only handling to make compilers happy.
	}

	return VK_FALSE;
}

VKAPI_ATTR VkBool32 VKAPI_CALL RenderingContextDriverVulkan::_debug_report_callback(VkDebugReportFlagsEXT p_flags, VkDebugReportObjectTypeEXT p_object_type, uint64_t p_object, size_t p_location, int32_t p_message_code, const char *p_layer_prefix, const char *p_message, void *p_user_data) {
	String debug_message = String("Vulkan Debug Report: object - ") + String::num_int64(p_object) + "\n" + p_message;

	switch (p_flags) {
		case VK_DEBUG_REPORT_DEBUG_BIT_EXT:
		case VK_DEBUG_REPORT_INFORMATION_BIT_EXT:
			print_line(debug_message);
			break;
		case VK_DEBUG_REPORT_WARNING_BIT_EXT:
		case VK_DEBUG_REPORT_PERFORMANCE_WARNING_BIT_EXT:
			WARN_PRINT(debug_message);
			break;
		case VK_DEBUG_REPORT_ERROR_BIT_EXT:
			ERR_PRINT(debug_message);
			break;
	}

	return VK_FALSE;
}

Error RenderingContextDriverVulkan::_initialize_instance() {
	Error err;
	TightLocalVector<const char *> enabled_extension_names;
	enabled_extension_names.reserve(enabled_instance_extension_names.size());
	for (const CharString &extension_name : enabled_instance_extension_names) {
		enabled_extension_names.push_back(extension_name.ptr());
	}

	// We'll set application version to the Vulkan version we're developing against, even if our instance is based on an older Vulkan
	// version, devices can still support newer versions of Vulkan. The exception is when we're on Vulkan 1.0, we should not set this
	// to anything but 1.0. Note that this value is only used by validation layers to warn us about version issues.
	uint32_t application_api_version = instance_api_version == VK_API_VERSION_1_0 ? VK_API_VERSION_1_0 : VK_API_VERSION_1_2;

	CharString cs = GLOBAL_GET("application/config/name").operator String().utf8();
	VkApplicationInfo app_info = {};
	app_info.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
	app_info.pApplicationName = cs.get_data();
	app_info.pEngineName = VERSION_NAME;
	app_info.engineVersion = VK_MAKE_VERSION(VERSION_MAJOR, VERSION_MINOR, VERSION_PATCH);
	app_info.apiVersion = application_api_version;

	TightLocalVector<const char *> enabled_layer_names;
	if (_use_validation_layers()) {
		err = _find_validation_layers(enabled_layer_names);
		ERR_FAIL_COND_V(err != OK, err);
	}

	VkInstanceCreateInfo instance_info = {};
	instance_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
	instance_info.pApplicationInfo = &app_info;
	instance_info.enabledExtensionCount = enabled_extension_names.size();
	instance_info.ppEnabledExtensionNames = enabled_extension_names.ptr();
	instance_info.enabledLayerCount = enabled_layer_names.size();
	instance_info.ppEnabledLayerNames = enabled_layer_names.ptr();

	// This is info for a temp callback to use during CreateInstance. After the instance is created, we use the instance-based function to register the final callback.
	VkDebugUtilsMessengerCreateInfoEXT debug_messenger_create_info = {};
	VkDebugReportCallbackCreateInfoEXT debug_report_callback_create_info = {};
	const bool has_debug_utils_extension = enabled_instance_extension_names.has(VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
	const bool has_debug_report_extension = enabled_instance_extension_names.has(VK_EXT_DEBUG_REPORT_EXTENSION_NAME);
	if (has_debug_utils_extension) {
		debug_messenger_create_info.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
		debug_messenger_create_info.pNext = nullptr;
		debug_messenger_create_info.flags = 0;
		debug_messenger_create_info.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
		debug_messenger_create_info.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
		debug_messenger_create_info.pfnUserCallback = _debug_messenger_callback;
		debug_messenger_create_info.pUserData = this;
		instance_info.pNext = &debug_messenger_create_info;
	} else if (has_debug_report_extension) {
		debug_report_callback_create_info.sType = VK_STRUCTURE_TYPE_DEBUG_REPORT_CALLBACK_CREATE_INFO_EXT;
		debug_report_callback_create_info.flags = VK_DEBUG_REPORT_INFORMATION_BIT_EXT | VK_DEBUG_REPORT_WARNING_BIT_EXT | VK_DEBUG_REPORT_PERFORMANCE_WARNING_BIT_EXT | VK_DEBUG_REPORT_ERROR_BIT_EXT | VK_DEBUG_REPORT_DEBUG_BIT_EXT;
		debug_report_callback_create_info.pfnCallback = _debug_report_callback;
		debug_report_callback_create_info.pUserData = this;
		instance_info.pNext = &debug_report_callback_create_info;
	}

	err = _create_vulkan_instance(&instance_info, &instance);
	ERR_FAIL_COND_V(err != OK, err);

#ifdef USE_VOLK
	volkLoadInstance(instance);
#endif

	// Physical device.
	if (enabled_instance_extension_names.has(VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME)) {
		functions.GetPhysicalDeviceFeatures2 = PFN_vkGetPhysicalDeviceFeatures2(vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2"));
		functions.GetPhysicalDeviceProperties2 = PFN_vkGetPhysicalDeviceProperties2(vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceProperties2"));

		// In Vulkan 1.0, the functions might be accessible under their original extension names.
		if (functions.GetPhysicalDeviceFeatures2 == nullptr) {
			functions.GetPhysicalDeviceFeatures2 = PFN_vkGetPhysicalDeviceFeatures2(vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceFeatures2KHR"));
		}

		if (functions.GetPhysicalDeviceProperties2 == nullptr) {
			functions.GetPhysicalDeviceProperties2 = PFN_vkGetPhysicalDeviceProperties2(vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceProperties2KHR"));
		}
	}

	// Device.
	functions.GetDeviceProcAddr = PFN_vkGetDeviceProcAddr(vkGetInstanceProcAddr(instance, "vkGetDeviceProcAddr"));

	// Surfaces.
	functions.GetPhysicalDeviceSurfaceSupportKHR = PFN_vkGetPhysicalDeviceSurfaceSupportKHR(vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceSurfaceSupportKHR"));
	functions.GetPhysicalDeviceSurfaceFormatsKHR = PFN_vkGetPhysicalDeviceSurfaceFormatsKHR(vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceSurfaceFormatsKHR"));
	functions.GetPhysicalDeviceSurfaceCapabilitiesKHR = PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR(vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"));
	functions.GetPhysicalDeviceSurfacePresentModesKHR = PFN_vkGetPhysicalDeviceSurfacePresentModesKHR(vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceSurfacePresentModesKHR"));

	// Debug utils and report.
	if (has_debug_utils_extension) {
		// Setup VK_EXT_debug_utils function pointers always (we use them for debug labels and names).
		functions.CreateDebugUtilsMessengerEXT = (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");
		functions.DestroyDebugUtilsMessengerEXT = (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT");
		functions.CmdBeginDebugUtilsLabelEXT = (PFN_vkCmdBeginDebugUtilsLabelEXT)vkGetInstanceProcAddr(instance, "vkCmdBeginDebugUtilsLabelEXT");
		functions.CmdEndDebugUtilsLabelEXT = (PFN_vkCmdEndDebugUtilsLabelEXT)vkGetInstanceProcAddr(instance, "vkCmdEndDebugUtilsLabelEXT");
		functions.SetDebugUtilsObjectNameEXT = (PFN_vkSetDebugUtilsObjectNameEXT)vkGetInstanceProcAddr(instance, "vkSetDebugUtilsObjectNameEXT");

		if (!functions.debug_util_functions_available()) {
			ERR_FAIL_V_MSG(ERR_CANT_CREATE, "GetProcAddr: Failed to init VK_EXT_debug_utils\nGetProcAddr: Failure");
		}

		VkResult res = functions.CreateDebugUtilsMessengerEXT(instance, &debug_messenger_create_info, nullptr, &debug_messenger);
		switch (res) {
			case VK_SUCCESS:
				break;
			case VK_ERROR_OUT_OF_HOST_MEMORY:
				ERR_FAIL_V_MSG(ERR_CANT_CREATE, "CreateDebugUtilsMessengerEXT: out of host memory\nCreateDebugUtilsMessengerEXT Failure");
				break;
			default:
				ERR_FAIL_V_MSG(ERR_CANT_CREATE, "CreateDebugUtilsMessengerEXT: unknown failure\nCreateDebugUtilsMessengerEXT Failure");
				break;
		}
	} else if (has_debug_report_extension) {
		functions.CreateDebugReportCallbackEXT = (PFN_vkCreateDebugReportCallbackEXT)vkGetInstanceProcAddr(instance, "vkCreateDebugReportCallbackEXT");
		functions.DebugReportMessageEXT = (PFN_vkDebugReportMessageEXT)vkGetInstanceProcAddr(instance, "vkDebugReportMessageEXT");
		functions.DestroyDebugReportCallbackEXT = (PFN_vkDestroyDebugReportCallbackEXT)vkGetInstanceProcAddr(instance, "vkDestroyDebugReportCallbackEXT");

		if (!functions.debug_report_functions_available()) {
			ERR_FAIL_V_MSG(ERR_CANT_CREATE, "GetProcAddr: Failed to init VK_EXT_debug_report\nGetProcAddr: Failure");
		}

		VkResult res = functions.CreateDebugReportCallbackEXT(instance, &debug_report_callback_create_info, nullptr, &debug_report);
		switch (res) {
			case VK_SUCCESS:
				break;
			case VK_ERROR_OUT_OF_HOST_MEMORY:
				ERR_FAIL_V_MSG(ERR_CANT_CREATE, "CreateDebugReportCallbackEXT: out of host memory\nCreateDebugReportCallbackEXT Failure");
				break;
			default:
				ERR_FAIL_V_MSG(ERR_CANT_CREATE, "CreateDebugReportCallbackEXT: unknown failure\nCreateDebugReportCallbackEXT Failure");
				break;
		}
	}

	return OK;
}

Error RenderingContextDriverVulkan::_initialize_devices() {
	if (VulkanHooks::get_singleton() != nullptr) {
		VkPhysicalDevice physical_device;
		bool device_retrieved = VulkanHooks::get_singleton()->get_physical_device(&physical_device);
		ERR_FAIL_COND_V(!device_retrieved, ERR_CANT_CREATE);

		// When a hook is active, pretend the device returned by the hook is the only device available.
		driver_devices.resize(1);
		physical_devices.resize(1);
		device_queue_families.resize(1);
		physical_devices[0] = physical_device;

	} else {
		uint32_t physical_device_count = 0;
		VkResult err = vkEnumeratePhysicalDevices(instance, &physical_device_count, nullptr);
		ERR_FAIL_COND_V(err != VK_SUCCESS, ERR_CANT_CREATE);
		ERR_FAIL_COND_V_MSG(physical_device_count == 0, ERR_CANT_CREATE, "vkEnumeratePhysicalDevices reported zero accessible devices.\n\nDo you have a compatible Vulkan installable client driver (ICD) installed?\nvkEnumeratePhysicalDevices Failure.");

		driver_devices.resize(physical_device_count);
		physical_devices.resize(physical_device_count);
		device_queue_families.resize(physical_device_count);
		err = vkEnumeratePhysicalDevices(instance, &physical_device_count, physical_devices.ptr());
		ERR_FAIL_COND_V(err != VK_SUCCESS, ERR_CANT_CREATE);
	}

	// Fill the list of driver devices with the properties from the physical devices.
	for (uint32_t i = 0; i < physical_devices.size(); i++) {
		VkPhysicalDeviceProperties props;
		vkGetPhysicalDeviceProperties(physical_devices[i], &props);

		Device &driver_device = driver_devices[i];
		driver_device.name = String::utf8(props.deviceName);
		driver_device.vendor = Vendor(props.vendorID);
		driver_device.type = DeviceType(props.deviceType);
		driver_device.id = props.deviceID;

		uint32_t queue_family_properties_count = 0;
		vkGetPhysicalDeviceQueueFamilyProperties(physical_devices[i], &queue_family_properties_count, nullptr);

		if (queue_family_properties_count > 0) {
			device_queue_families[i].properties.resize(queue_family_properties_count);
			vkGetPhysicalDeviceQueueFamilyProperties(physical_devices[i], &queue_family_properties_count, device_queue_families[i].properties.ptr());
		}
	}

	return OK;
}

#ifdef WINDOWS_ENABLED

Error RenderingContextDriverVulkan::_initialize_d3d12_device_factory() {
	uint32_t agility_sdk_version = GLOBAL_GET("rendering/rendering_device/d3d12/agility_sdk_version");
	String agility_sdk_path = String(".\\") + Engine::get_singleton()->get_architecture_name();

	lib_d3d12 = LoadLibraryW(L"D3D12.dll");
	ERR_FAIL_NULL_V(lib_d3d12, ERR_CANT_CREATE);

	lib_dxgi = LoadLibraryW(L"DXGI.dll");
	ERR_FAIL_NULL_V(lib_dxgi, ERR_CANT_CREATE);

	// Note: symbol is not available in MinGW import library.
	PFN_D3D12_GET_INTERFACE d3d_D3D12GetInterface = (PFN_D3D12_GET_INTERFACE)(void *)GetProcAddress(lib_d3d12, "D3D12GetInterface");
	if (!d3d_D3D12GetInterface) {
		return OK; // Fallback to the system loader.
	}

	ID3D12SDKConfiguration *sdk_config = nullptr;
	if (SUCCEEDED(d3d_D3D12GetInterface(CLSID_D3D12SDKConfigurationGodot, IID_PPV_ARGS(&sdk_config)))) {
		ID3D12SDKConfiguration1 *sdk_config1 = nullptr;
		if (SUCCEEDED(sdk_config->QueryInterface(&sdk_config1))) {
			if (SUCCEEDED(sdk_config1->CreateDeviceFactory(agility_sdk_version, agility_sdk_path.ascii().get_data(), IID_PPV_ARGS(&d3d12_device_factory)))) {
				d3d_D3D12GetInterface(CLSID_D3D12DeviceFactoryGodot, IID_PPV_ARGS(&d3d12_device_factory));
			} else if (SUCCEEDED(sdk_config1->CreateDeviceFactory(agility_sdk_version, ".\\", IID_PPV_ARGS(&d3d12_device_factory)))) {
				d3d_D3D12GetInterface(CLSID_D3D12DeviceFactoryGodot, IID_PPV_ARGS(&d3d12_device_factory));
			}
			sdk_config1->Release();
		}
		sdk_config->Release();
	}

	return OK;
}

Error RenderingContextDriverVulkan::_initialize_dxgi_devices() {
	typedef HRESULT(WINAPI * PFN_DXGI_CREATE_DXGI_FACTORY2)(UINT, REFIID, void **);
	PFN_DXGI_CREATE_DXGI_FACTORY2 dxgi_CreateDXGIFactory2 = (PFN_DXGI_CREATE_DXGI_FACTORY2)(void *)GetProcAddress(lib_dxgi, "CreateDXGIFactory2");
	ERR_FAIL_NULL_V(dxgi_CreateDXGIFactory2, ERR_CANT_CREATE);

	HRESULT res = dxgi_CreateDXGIFactory2(0, IID_PPV_ARGS(&dxgi_factory));
	ERR_FAIL_COND_V(!SUCCEEDED(res), ERR_CANT_CREATE);

	// Enumerate all possible adapters.
	LocalVector<IDXGIAdapter1 *> adapters;
	IDXGIAdapter1 *adapter = nullptr;
	do {
		adapter = create_dxgi_adapter(adapters.size());
		if (adapter != nullptr) {
			adapters.push_back(adapter);
		}
	} while (adapter != nullptr);

	ERR_FAIL_COND_V_MSG(adapters.is_empty(), ERR_CANT_CREATE, "Adapters enumeration reported zero accessible devices.");

	// Fill the device descriptions with the adapters.
	dxgi_driver_devices.resize(adapters.size());
	for (uint32_t i = 0; i < adapters.size(); ++i) {
		DXGI_ADAPTER_DESC1 desc = {};
		adapters[i]->GetDesc1(&desc);

		Device &device = dxgi_driver_devices[i];
		device.name = desc.Description;
		device.vendor = Vendor(desc.VendorId);
		device.id = desc.DeviceId;

		if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) {
			device.type = DEVICE_TYPE_CPU;
		} else {
			const bool has_dedicated_vram = desc.DedicatedVideoMemory > 0;
			device.type = has_dedicated_vram ? DEVICE_TYPE_DISCRETE_GPU : DEVICE_TYPE_INTEGRATED_GPU;
		}
	}

	// Release all created adapters.
	for (uint32_t i = 0; i < adapters.size(); ++i) {
		adapters[i]->Release();
	}

	IDXGIFactory5 *factory_5 = nullptr;
	res = dxgi_factory->QueryInterface(IID_PPV_ARGS(&factory_5));
	if (SUCCEEDED(res)) {
		// The type is important as in general, sizeof(bool) != sizeof(BOOL).
		BOOL feature_supported = FALSE;
		res = factory_5->CheckFeatureSupport(DXGI_FEATURE_PRESENT_ALLOW_TEARING, &feature_supported, sizeof(feature_supported));
		if (SUCCEEDED(res)) {
			tearing_supported = feature_supported;
		} else {
			ERR_PRINT("CheckFeatureSupport failed with error " + vformat("0x%08ux", (uint64_t)res) + ".");
		}
	}

	return OK;
}

#endif

bool RenderingContextDriverVulkan::_use_validation_layers() const {
	return Engine::get_singleton()->is_validation_layers_enabled();
}

Error RenderingContextDriverVulkan::_create_vulkan_instance(const VkInstanceCreateInfo *p_create_info, VkInstance *r_instance) {
	if (VulkanHooks::get_singleton() != nullptr) {
		return VulkanHooks::get_singleton()->create_vulkan_instance(p_create_info, r_instance) ? OK : ERR_CANT_CREATE;
	} else {
		VkResult err = vkCreateInstance(p_create_info, nullptr, r_instance);
		ERR_FAIL_COND_V_MSG(err == VK_ERROR_INCOMPATIBLE_DRIVER, ERR_CANT_CREATE,
				"Cannot find a compatible Vulkan installable client driver (ICD).\n\n"
				"vkCreateInstance Failure");
		ERR_FAIL_COND_V_MSG(err == VK_ERROR_EXTENSION_NOT_PRESENT, ERR_CANT_CREATE,
				"Cannot find a specified extension library.\n"
				"Make sure your layers path is set appropriately.\n"
				"vkCreateInstance Failure");
		ERR_FAIL_COND_V_MSG(err, ERR_CANT_CREATE,
				"vkCreateInstance failed.\n\n"
				"Do you have a compatible Vulkan installable client driver (ICD) installed?\n"
				"Please look at the Getting Started guide for additional information.\n"
				"vkCreateInstance Failure");
	}

	return OK;
}

Error RenderingContextDriverVulkan::initialize() {
	Error err;

#ifdef USE_VOLK
	if (volkInitialize() != VK_SUCCESS) {
		return FAILED;
	}
#endif

	err = _initialize_vulkan_version();
	ERR_FAIL_COND_V(err != OK, err);

	err = _initialize_instance_extensions();
	ERR_FAIL_COND_V(err != OK, err);

	err = _initialize_instance();
	ERR_FAIL_COND_V(err != OK, err);

	err = _initialize_devices();
	ERR_FAIL_COND_V(err != OK, err);

#ifdef WINDOWS_ENABLED
	err = _initialize_d3d12_device_factory();
	ERR_FAIL_COND_V(err != OK, err);

	err = _initialize_dxgi_devices();
	ERR_FAIL_COND_V(err != OK, err);
#endif

	return OK;
}

const RenderingContextDriver::Device &RenderingContextDriverVulkan::device_get(uint32_t p_device_index) const {
	DEV_ASSERT(p_device_index < driver_devices.size());
	return driver_devices[p_device_index];
}

uint32_t RenderingContextDriverVulkan::device_get_count() const {
	return driver_devices.size();
}

bool RenderingContextDriverVulkan::device_supports_present(uint32_t p_device_index, SurfaceID p_surface) const {
	DEV_ASSERT(p_device_index < physical_devices.size());

#ifdef WINDOWS_ENABLED
	// All devices should support presenting to any surface.
	return true;
#else
	// Check if any of the queues supported by the device supports presenting to the window's surface.
	const VkPhysicalDevice physical_device = physical_devices[p_device_index];
	const DeviceQueueFamilies &queue_families = device_queue_families[p_device_index];
	for (uint32_t i = 0; i < queue_families.properties.size(); i++) {
		if ((queue_families.properties[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && queue_family_supports_present(physical_device, i, p_surface)) {
			return true;
		}
	}

	return false;
#endif
}

RenderingDeviceDriver *RenderingContextDriverVulkan::driver_create() {
	return memnew(RenderingDeviceDriverVulkan(this));
}

void RenderingContextDriverVulkan::driver_free(RenderingDeviceDriver *p_driver) {
	memdelete(p_driver);
}

RenderingContextDriver::SurfaceID RenderingContextDriverVulkan::surface_create(const void *p_platform_data) {
	DEV_ASSERT(false && "Surface creation should not be called on the platform-agnostic version of the driver.");
	return SurfaceID();
}

void RenderingContextDriverVulkan::surface_set_size(SurfaceID p_surface, uint32_t p_width, uint32_t p_height) {
	Surface *surface = (Surface *)(p_surface);
	surface->width = p_width;
	surface->height = p_height;
	surface->needs_resize = true;
}

void RenderingContextDriverVulkan::surface_set_vsync_mode(SurfaceID p_surface, DisplayServer::VSyncMode p_vsync_mode) {
	Surface *surface = (Surface *)(p_surface);
	surface->vsync_mode = p_vsync_mode;
	surface->needs_resize = true;
}

DisplayServer::VSyncMode RenderingContextDriverVulkan::surface_get_vsync_mode(SurfaceID p_surface) const {
	Surface *surface = (Surface *)(p_surface);
	return surface->vsync_mode;
}

uint32_t RenderingContextDriverVulkan::surface_get_width(SurfaceID p_surface) const {
	Surface *surface = (Surface *)(p_surface);
	return surface->width;
}

uint32_t RenderingContextDriverVulkan::surface_get_height(SurfaceID p_surface) const {
	Surface *surface = (Surface *)(p_surface);
	return surface->height;
}

void RenderingContextDriverVulkan::surface_set_needs_resize(SurfaceID p_surface, bool p_needs_resize) {
	Surface *surface = (Surface *)(p_surface);
	surface->needs_resize = p_needs_resize;
}

bool RenderingContextDriverVulkan::surface_get_needs_resize(SurfaceID p_surface) const {
	Surface *surface = (Surface *)(p_surface);
	return surface->needs_resize;
}

void RenderingContextDriverVulkan::surface_destroy(SurfaceID p_surface) {
	Surface *surface = (Surface *)(p_surface);
#ifndef WINDOWS_ENABLED
	vkDestroySurfaceKHR(instance, surface->vk_surface, nullptr);
#endif
	memdelete(surface);
}

bool RenderingContextDriverVulkan::is_debug_utils_enabled() const {
	return enabled_instance_extension_names.has(VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
}

VkInstance RenderingContextDriverVulkan::instance_get() const {
	return instance;
}

VkPhysicalDevice RenderingContextDriverVulkan::physical_device_get(uint32_t p_device_index) const {
	DEV_ASSERT(p_device_index < physical_devices.size());
	return physical_devices[p_device_index];
}

uint32_t RenderingContextDriverVulkan::queue_family_get_count(uint32_t p_device_index) const {
	DEV_ASSERT(p_device_index < physical_devices.size());
	return device_queue_families[p_device_index].properties.size();
}

VkQueueFamilyProperties RenderingContextDriverVulkan::queue_family_get(uint32_t p_device_index, uint32_t p_queue_family_index) const {
	DEV_ASSERT(p_device_index < physical_devices.size());
	DEV_ASSERT(p_queue_family_index < queue_family_get_count(p_device_index));
	return device_queue_families[p_device_index].properties[p_queue_family_index];
}

bool RenderingContextDriverVulkan::queue_family_supports_present(VkPhysicalDevice p_physical_device, uint32_t p_queue_family_index, SurfaceID p_surface) const {
	DEV_ASSERT(p_physical_device != VK_NULL_HANDLE);
	DEV_ASSERT(p_surface != 0);

#ifdef WINDOWS_ENABLED
	// TODO: Return true if the queue supports graphics.
	return true;
#else
	Surface *surface = (Surface *)(p_surface);
	VkBool32 present_supported = false;
	VkResult err = vkGetPhysicalDeviceSurfaceSupportKHR(p_physical_device, p_queue_family_index, surface->vk_surface, &present_supported);
	return err == VK_SUCCESS && present_supported;
#endif
}

const RenderingContextDriverVulkan::Functions &RenderingContextDriverVulkan::functions_get() const {
	return functions;
}

#ifdef WINDOWS_ENABLED

IDXGIAdapter1 *RenderingContextDriverVulkan::create_dxgi_adapter(uint32_t p_adapter_index) const {
	IDXGIFactory6 *factory_6 = nullptr;
	HRESULT res = dxgi_factory->QueryInterface(IID_PPV_ARGS(&factory_6));

	// TODO: Use IDXCoreAdapterList, which gives more comprehensive information.
	IDXGIAdapter1 *adapter = nullptr;
	if (SUCCEEDED(res)) {
		if (factory_6->EnumAdapterByGpuPreference(p_adapter_index, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(&adapter)) == DXGI_ERROR_NOT_FOUND) {
			return nullptr;
		}
	} else {
		if (dxgi_factory->EnumAdapters1(p_adapter_index, &adapter) == DXGI_ERROR_NOT_FOUND) {
			return nullptr;
		}
	}

	return adapter;
}

ID3D12Device *RenderingContextDriverVulkan::create_d3d12_device(IDXGIAdapter1 *p_adapter) const {
	ID3D12Device *d3d12_device = nullptr;
	HRESULT res;
	if (d3d12_device_factory != nullptr) {
		res = d3d12_device_factory->CreateDevice(p_adapter, IID_PPV_ARGS(&d3d12_device));
	} else {
		PFN_D3D12_CREATE_DEVICE d3d_D3D12CreateDevice = (PFN_D3D12_CREATE_DEVICE)(void *)GetProcAddress(lib_d3d12, "D3D12CreateDevice");
		ERR_FAIL_NULL_V(d3d_D3D12CreateDevice, nullptr);

		res = d3d_D3D12CreateDevice(p_adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&d3d12_device));
	}

	ERR_FAIL_COND_V_MSG(!SUCCEEDED(res), nullptr, "D3D12CreateDevice failed with error " + vformat("0x%08ux", (uint64_t)res) + ".");

	return d3d12_device;
}

int32_t RenderingContextDriverVulkan::find_dxgi_adapter_for_device(uint32_t p_device_index) const {
	DEV_ASSERT(p_device_index < driver_devices.size());

	const Device &vulkan_device = driver_devices[p_device_index];
	for (uint32_t i = 0; i < dxgi_driver_devices.size(); i++) {
		if (vulkan_device.vendor == dxgi_driver_devices[i].vendor && vulkan_device.id == dxgi_driver_devices[i].id) {
			return i;
		}
	}

	ERR_FAIL_V_MSG(-1, "Unable to find a matching DXGI device for the Vulkan device.");
}

ID3D12DeviceFactory *RenderingContextDriverVulkan::device_factory_get() const {
	return d3d12_device_factory;
}

IDXGIFactory2 *RenderingContextDriverVulkan::dxgi_factory_get() const {
	return dxgi_factory;
}

bool RenderingContextDriverVulkan::get_tearing_supported() const {
	return tearing_supported;
}

#endif

#endif // VULKAN_ENABLED
