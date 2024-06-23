package main

import "core:fmt"
import glfw "vendor:glfw"
import vk   "vendor:vulkan"

import "core:strings"
import "core:os"
import win "core:sys/windows"
import "base:runtime"
import glm "core:math/linalg/glsl"


WIDTH :: 800
HEIGHT :: 600

MAX_FRAMES_IN_FLIGHT :: 2
current_frame: u32 = 0

Vertex :: struct {
	pos:   glm.vec2,
	color: glm.vec3
}

VulkanRenderer :: struct {
	window: glfw.WindowHandle,
	instance: vk.Instance,
	debug_messenger: vk.DebugUtilsMessengerEXT,
	physical_device: vk.PhysicalDevice,
	device: vk.Device,
	graphics_queue: vk.Queue,
	present_queue: vk.Queue,
	surface: vk.SurfaceKHR,
	swap_chain: vk.SwapchainKHR,
	swap_chain_images: [dynamic]vk.Image,
	swap_chain_image_format: vk.Format,
	swap_chain_extent: vk.Extent2D,
	swap_chain_image_views: [dynamic]vk.ImageView,
	swap_chain_framebuffers: [dynamic]vk.Framebuffer,
	render_pass: vk.RenderPass,
	pipeline_layout: vk.PipelineLayout,
	graphics_pipeline: vk.Pipeline,
	command_pool: vk.CommandPool,
	command_buffers: [dynamic]vk.CommandBuffer,
	image_available_semaphores: [dynamic]vk.Semaphore,
	render_finished_semaphores: [dynamic]vk.Semaphore,
	in_flight_fences: [dynamic]vk.Fence,
}

vr: VulkanRenderer
framebuffer_resized: b32 = false

validation_layers := []cstring{
	"VK_LAYER_KHRONOS_validation"
}

device_extensions := []cstring{
	"VK_KHR_swapchain"
}

vertex_shader_bytecode   :: #load("./shaders/vert.spv")
fragment_shader_bytecode :: #load("./shaders/frag.spv")

when ODIN_DEBUG {
	enable_validation_layer := true
} else {
	enable_validation_layer := false
}

QueueFamilyIndices :: struct {
	graphicsFamily: u32,
	has_graphics_family: b32,
	presentFamily: u32,
	has_present_family: b32,
}

SwapChainSupportDetails :: struct {
	capatilities: vk.SurfaceCapabilitiesKHR,
	formats: [dynamic]vk.SurfaceFormatKHR,
	present_modes: [dynamic]vk.PresentModeKHR,
}

vertices: []Vertex = {
	{{0, -0.5}, {1.0, 0.0, 0.0}},
	{{0.5, 0.5}, {0.0, 1.0, 0.0}},
	{{-0.5, 0.5}, {0.0, 0.0, 1.0}}
}

get_binding_description :: proc() -> vk.VertexInputBindingDescription {
	binding_description: vk.VertexInputBindingDescription

	binding_description.binding = 0 // array index
	binding_description.stride = size_of(Vertex) // number of bytes to the next
	binding_description.inputRate = vk.VertexInputRate.VERTEX

	return binding_description
}

get_attribute_descriptions :: proc() -> [2]vk.VertexInputAttributeDescription {
	attribute_descriptions: [2]vk.VertexInputAttributeDescription

	attribute_descriptions[0].binding = 0
	attribute_descriptions[0].location = 0
	attribute_descriptions[0].format = vk.Format.R32G32_SFLOAT
	attribute_descriptions[0].offset = 0 // pos offset is 0, check if this is correct

	attribute_descriptions[1].binding = 0
	attribute_descriptions[1].location = 1
	attribute_descriptions[1].format = vk.Format.R32G32B32_SFLOAT
	attribute_descriptions[1].offset = size_of(glm.vec2) // color offset is 8? it should start after the pos, check if this is correct

	return attribute_descriptions
}

indices_is_complete :: proc (indices: QueueFamilyIndices) -> b32 {
	return indices.has_graphics_family && indices.has_present_family
}

create_instance :: proc() {
	// create vulkan instance

	if (enable_validation_layer && !check_validation_layer_support()) {
		fmt.println("validation layers requested, but not available!")
	}
	app_info: vk.ApplicationInfo
	app_info.sType = vk.StructureType.APPLICATION_INFO
	app_info.pApplicationName = "Hello"
	app_info.applicationVersion = vk.MAKE_VERSION(1, 0, 0)
	app_info.pEngineName = "No Engine"
	app_info.engineVersion = vk.MAKE_VERSION(1, 0, 0)
	app_info.apiVersion = vk.API_VERSION_1_0

	create_info := vk.InstanceCreateInfo{}
	create_info.sType = vk.StructureType.INSTANCE_CREATE_INFO
	create_info.pApplicationInfo = &app_info

	glfw_extensions : []cstring = glfw.GetRequiredInstanceExtensions()
	
	create_info.enabledExtensionCount = cast(u32)len(glfw_extensions)
	create_info.ppEnabledExtensionNames = raw_data(glfw_extensions)


	debug_create_info := vk.DebugUtilsMessengerCreateInfoEXT{}

	if enable_validation_layer {
		create_info.enabledLayerCount = u32(len(validation_layers))
		create_info.ppEnabledLayerNames = raw_data(validation_layers)

		populate_debug_messenger_create_info(&debug_create_info)
	}

	if vk.CreateInstance(&create_info, nil, &vr.instance) != vk.Result.SUCCESS {
		fmt.println("Failed to create instance!")
		return
	}
}

check_validation_layer_support :: proc() -> bool {
	layer_count: u32
	vk.EnumerateInstanceLayerProperties(&layer_count, nil)

	available_layers := make([]vk.LayerProperties, layer_count)
	vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(available_layers))


	for layer in validation_layers {
		layer_found:bool = false

		for property in available_layers {
			layer_name := property.layerName
			if layer == strings.unsafe_string_to_cstring(string(layer_name[:])) {
				layer_found = true
				break
			}
		}

		if (!layer_found) {
			return false
		}
	}

	return true
}

pick_physical_device :: proc() {
	// pick a physical device
	device_count: u32
	vk.EnumeratePhysicalDevices(vr.instance, &device_count, nil)

	// if there is none we should stop
	if device_count == 0 {
		fmt.println("Failed to find GPUs with Vulkan support!")
	}

	// otherwise we want to allocate an array (devices) with all devices handles
	devices :[]vk.PhysicalDevice = make([]vk.PhysicalDevice, device_count)
	vk.EnumeratePhysicalDevices(vr.instance, &device_count, raw_data(devices))

	// pick the device we want
	for d in devices {
		if is_device_suitable(d) {
			vr.physical_device = d
			break
		}
	}


	if vr.physical_device == nil {
		fmt.println("Failed to find a suitable GPU!")
		return
	}
}


create_sync_objects :: proc() {
	resize(&vr.image_available_semaphores, MAX_FRAMES_IN_FLIGHT)
	resize(&vr.render_finished_semaphores, MAX_FRAMES_IN_FLIGHT)
	resize(&vr.in_flight_fences, MAX_FRAMES_IN_FLIGHT)
	
	semaphore_info: vk.SemaphoreCreateInfo
	semaphore_info.sType = vk.StructureType.SEMAPHORE_CREATE_INFO

	fence_info: vk.FenceCreateInfo
	fence_info.sType = vk.StructureType.FENCE_CREATE_INFO
	fence_info.flags = vk.FenceCreateFlags{.SIGNALED}

	for i := 0; i < MAX_FRAMES_IN_FLIGHT; i += 1 {
		if  vk.CreateSemaphore(vr.device, &semaphore_info, nil, &vr.image_available_semaphores[i]) != vk.Result.SUCCESS ||
			vk.CreateSemaphore(vr.device, &semaphore_info, nil, &vr.render_finished_semaphores[i]) != vk.Result.SUCCESS ||
			vk.CreateFence(vr.device, &fence_info, nil, &vr.in_flight_fences[i]) != vk.Result.SUCCESS {
				fmt.println("Failed to create semaphores!")
			}		
	}

}


record_command_buffer :: proc(command_buffer: vk.CommandBuffer, image_index: u32) {
	begin_info: vk.CommandBufferBeginInfo
	begin_info.sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO
	/* begin_info.flags = 0 */
	/* begin_info.pInheritanceInfo = nil */

	if vk.BeginCommandBuffer(command_buffer, &begin_info) != vk.Result.SUCCESS {
		fmt.println("Failed to begin recording command buffer!")
	}


	render_pass_info: vk.RenderPassBeginInfo
	render_pass_info.sType = vk.StructureType.RENDER_PASS_BEGIN_INFO
	render_pass_info.renderPass = vr.render_pass
	render_pass_info.framebuffer = vr.swap_chain_framebuffers[image_index]
	render_pass_info.renderArea.offset = {0, 0}
	render_pass_info.renderArea.extent = vr.swap_chain_extent

	clear_color:= vk.ClearValue{
		color = { float32 = {0.0, 0.0, 0.0, 1.0}}
	}
	
	render_pass_info.clearValueCount = 1
	render_pass_info.pClearValues = &clear_color

	vk.CmdBeginRenderPass(command_buffer, &render_pass_info, vk.SubpassContents.INLINE)

	vk.CmdBindPipeline(command_buffer, vk.PipelineBindPoint.GRAPHICS, vr.graphics_pipeline)

	viewport: vk.Viewport
	viewport.x = 0.0
	viewport.y = 0.0
	viewport.width = f32(vr.swap_chain_extent.width)
	viewport.height = f32(vr.swap_chain_extent.height)
	viewport.minDepth = 0.0
	viewport.maxDepth = 1.0
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

	scissor: vk.Rect2D
	scissor.offset = {0, 0}
	scissor.extent = vr.swap_chain_extent
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

	vk.CmdDraw(command_buffer, 3, 1, 0, 0)
	vk.CmdEndRenderPass(command_buffer)

	if vk.EndCommandBuffer(command_buffer) != vk.Result.SUCCESS {
		fmt.println("Failed to record command buffer!")
	}
}

create_command_buffers :: proc() {
	resize(&vr.command_buffers, MAX_FRAMES_IN_FLIGHT)
	alloc_info :vk.CommandBufferAllocateInfo
	alloc_info.sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO
	alloc_info.commandPool = vr.command_pool
	alloc_info.level = vk.CommandBufferLevel.PRIMARY
	alloc_info.commandBufferCount = u32(len(vr.command_buffers))

	if vk.AllocateCommandBuffers(vr.device, &alloc_info, raw_data(vr.command_buffers)) != vk.Result.SUCCESS {
		fmt.println("Failed to allocate command buffers!")
	}
}

create_command_pool :: proc() {
	queue_family_indices := find_queue_families(vr.physical_device)

	pool_info: vk.CommandPoolCreateInfo
	pool_info.sType = vk.StructureType.COMMAND_POOL_CREATE_INFO
	pool_info.flags = vk.CommandPoolCreateFlags{.RESET_COMMAND_BUFFER}
	pool_info.queueFamilyIndex = queue_family_indices.graphicsFamily

	if vk.CreateCommandPool(vr.device, &pool_info, nil, &vr.command_pool) != vk.Result.SUCCESS {
		fmt.println("Failed to create command pool!")
	}
}


create_framebuffers :: proc() {
	resize(&vr.swap_chain_framebuffers, len(vr.swap_chain_image_views))

	for i := 0; i < len(vr.swap_chain_image_views); i += 1 {
		attachments: []vk.ImageView = {
			vr.swap_chain_image_views[i]
		}

		framebuffer_info : vk.FramebufferCreateInfo
		framebuffer_info.sType = vk.StructureType.FRAMEBUFFER_CREATE_INFO
		framebuffer_info.renderPass = vr.render_pass
		framebuffer_info.attachmentCount = 1
		framebuffer_info.pAttachments = raw_data(attachments)
		framebuffer_info.width = vr.swap_chain_extent.width
		framebuffer_info.height = vr.swap_chain_extent.height
		framebuffer_info.layers = 1

		if vk.CreateFramebuffer(vr.device, &framebuffer_info, nil, &vr.swap_chain_framebuffers[i]) != vk.Result.SUCCESS {
			fmt.println("Failed to create framebuffer")
		}
	}
}

create_render_pass :: proc() {
	color_attachment: vk.AttachmentDescription
	color_attachment.format = vr.swap_chain_image_format
	color_attachment.samples = {._1}
	color_attachment.loadOp = vk.AttachmentLoadOp.CLEAR
	color_attachment.storeOp = vk.AttachmentStoreOp.STORE
	color_attachment.stencilLoadOp = vk.AttachmentLoadOp.DONT_CARE
	color_attachment.stencilStoreOp = vk.AttachmentStoreOp.DONT_CARE
	color_attachment.initialLayout = vk.ImageLayout.UNDEFINED
	color_attachment.finalLayout = vk.ImageLayout.PRESENT_SRC_KHR

	color_attachment_ref: vk.AttachmentReference
	color_attachment_ref.attachment = 0
	color_attachment_ref.layout = vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL

	subpass: vk.SubpassDescription
	subpass.pipelineBindPoint = vk.PipelineBindPoint.GRAPHICS
	subpass.colorAttachmentCount = 1
	subpass.pColorAttachments = &color_attachment_ref

	dependency: vk.SubpassDependency
	dependency.srcSubpass = vk.SUBPASS_EXTERNAL
	dependency.dstSubpass = 0
	dependency.srcStageMask = vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	/* dependency.srcAccessMask = vk.AccessFlags{.INDIRECT_COMMAND_READ} */
	dependency.dstStageMask = vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	dependency.dstAccessMask = vk.AccessFlags{.COLOR_ATTACHMENT_WRITE}

	render_pass_info: vk.RenderPassCreateInfo
	render_pass_info.sType = vk.StructureType.RENDER_PASS_CREATE_INFO
	render_pass_info.attachmentCount = 1
	render_pass_info.pAttachments = &color_attachment
	render_pass_info.subpassCount = 1
	render_pass_info.pSubpasses = &subpass
	render_pass_info.dependencyCount = 1
	render_pass_info.pDependencies = &dependency

	if vk.CreateRenderPass(vr.device, &render_pass_info, nil, &vr.render_pass) != vk.Result.SUCCESS {
		fmt.println("Failed to create render pass!")
	}
}

create_graphics_pipeline :: proc() {
	vert_shader_module: vk.ShaderModule = create_shader_module(vertex_shader_bytecode)
	frag_shader_module: vk.ShaderModule = create_shader_module(fragment_shader_bytecode)

	vertex_shader_stage_info := vk.PipelineShaderStageCreateInfo{}
	vertex_shader_stage_info.sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO
	vertex_shader_stage_info.stage = vk.ShaderStageFlags{.VERTEX}
	vertex_shader_stage_info.module = vert_shader_module
	vertex_shader_stage_info.pName = "main"

	frag_shader_stage_info := vk.PipelineShaderStageCreateInfo{}
	frag_shader_stage_info.sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO
	frag_shader_stage_info.stage = vk.ShaderStageFlags{.FRAGMENT}
	frag_shader_stage_info.module = frag_shader_module
	frag_shader_stage_info.pName = "main"

	shaders_stage : []vk.PipelineShaderStageCreateInfo = {vertex_shader_stage_info, frag_shader_stage_info}

	binding_description := get_binding_description()
	attribute_descriptions := get_attribute_descriptions()

	vertex_input_info: vk.PipelineVertexInputStateCreateInfo
	vertex_input_info.sType = vk.StructureType.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
	vertex_input_info.vertexBindingDescriptionCount = 1
	vertex_input_info.vertexAttributeDescriptionCount = 1
	vertex_input_info.pVertexBindingDescriptions = &binding_description
	vertex_input_info.pVertexAttributeDescriptions = raw_data(attribute_descriptions[:])

	input_assembly: vk.PipelineInputAssemblyStateCreateInfo
	input_assembly.sType = vk.StructureType.PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
	input_assembly.topology = vk.PrimitiveTopology.TRIANGLE_LIST
	input_assembly.primitiveRestartEnable = false
	
	/* viewport: vk.Viewport = vk.Viewport{} */
	/* viewport.x = 0.0 */
	/* viewport.y = 0.0 */
	/* viewport.width = f32(swap_chain_extent.width) */
	/* viewport.height = f32(swap_chain_extent.height) */
	/* viewport.minDepth = 0.0 */
	/* viewport.maxDepth = 1.0 */

	/* scissor: vk.Rect2D = vk.Rect2D{} */
	/* scissor.offset = {0,0} */
	/* scissor.extent = swap_chain_extent */

	viewport := vk.Viewport{0, 0, f32(vr.swap_chain_extent.width), f32(vr.swap_chain_extent.height), 0, 1}
    scissor := vk.Rect2D{
        {0,0},
        vr.swap_chain_extent,
    }

    /* pvsci : vk.PipelineViewportStateCreateInfo */
    /* pvsci.sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO */
    /* pvsci.viewportCount = 1 */
    /* pvsci.pViewports    = &viewport */
    /* pvsci.scissorCount  = 1 */
    /* pvsci.pScissors     = &scissor */


	viewport_state: vk.PipelineViewportStateCreateInfo
	viewport_state.sType = vk.StructureType.PIPELINE_VIEWPORT_STATE_CREATE_INFO
	viewport_state.viewportCount = 1
	viewport_state.pViewports    = &viewport
	viewport_state.scissorCount  = 1
	viewport_state.pScissors     = &scissor

	rasterizer: vk.PipelineRasterizationStateCreateInfo
	rasterizer.sType = vk.StructureType.PIPELINE_RASTERIZATION_STATE_CREATE_INFO
	rasterizer.depthClampEnable        = false
	rasterizer.rasterizerDiscardEnable = false
    rasterizer.polygonMode             = vk.PolygonMode.FILL
    rasterizer.lineWidth               = 1.0
    rasterizer.cullMode                = vk.CullModeFlags{.BACK}
    rasterizer.frontFace               = .CLOCKWISE
    rasterizer.depthBiasEnable         = false

	multisampling: vk.PipelineMultisampleStateCreateInfo
	multisampling.sType = vk.StructureType.PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
	multisampling.sampleShadingEnable = false
	multisampling.rasterizationSamples = vk.SampleCountFlags{._1}
	/* multisampling.minSampleShading = 1.0 // Optional */
	/* multisampling.pSampleMask = nil // Optional */
	/* multisampling.alphaToCoverageEnable = false // Optional */
	/* multisampling.alphaToOneEnable = false // Optional */

	color_blend_attachment: vk.PipelineColorBlendAttachmentState
	color_blend_attachment.blendEnable         = true
	color_blend_attachment.srcColorBlendFactor = vk.BlendFactor.SRC_ALPHA // Optional
	color_blend_attachment.dstColorBlendFactor = vk.BlendFactor.ONE_MINUS_SRC_ALPHA // Optional
	color_blend_attachment.colorBlendOp        = vk.BlendOp.ADD // Optional
	color_blend_attachment.srcAlphaBlendFactor = vk.BlendFactor.ONE // Optional
	color_blend_attachment.dstAlphaBlendFactor = vk.BlendFactor.ZERO // Optional
	color_blend_attachment.alphaBlendOp        = vk.BlendOp.ADD // Optional
	color_blend_attachment.colorWriteMask      = { .R, .G, .B, .A }

	color_blending: vk.PipelineColorBlendStateCreateInfo
	color_blending.sType = vk.StructureType.PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
	color_blending.logicOpEnable = false
	/* color_blending.logicOp = vk.LogicOp.COPY // Optional */
	color_blending.attachmentCount = 1;
	color_blending.pAttachments = &color_blend_attachment;
	/* color_blending.blendConstants[1] = 0.0 // Optional */
	/* color_blending.blendConstants[1] = 0.0 // Optional */
	/* color_blending.blendConstants[2] = 0.0 // Optional */
	/* color_blending.blendConstants[3] = 0.0 // Optional */

	dinamic_states := []vk.DynamicState{
		vk.DynamicState.VIEWPORT,
		vk.DynamicState.SCISSOR
	}

	dynamic_state :vk.PipelineDynamicStateCreateInfo
	dynamic_state.sType = vk.StructureType.PIPELINE_DYNAMIC_STATE_CREATE_INFO
	dynamic_state.dynamicStateCount = u32(len(dinamic_states))
	dynamic_state.pDynamicStates = raw_data(dinamic_states)
	
	pipeline_layout_info: vk.PipelineLayoutCreateInfo
	pipeline_layout_info.sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO
	pipeline_layout_info.setLayoutCount = 0
	/* pipeline_layout_info.pSetLayouts nil */

	if vk.CreatePipelineLayout(vr.device, &pipeline_layout_info, nil, &vr.pipeline_layout) != vk.Result.SUCCESS {
		fmt.println("Failed to create pipeline layout!")
	}

	pipeline_info: vk.GraphicsPipelineCreateInfo
    pipeline_info.sType = vk.StructureType.GRAPHICS_PIPELINE_CREATE_INFO
    pipeline_info.stageCount = 2
    pipeline_info.pStages = raw_data(shaders_stage)
    pipeline_info.pVertexInputState = &vertex_input_info
    pipeline_info.pInputAssemblyState = &input_assembly
    pipeline_info.pViewportState = &viewport_state
    pipeline_info.pRasterizationState = &rasterizer
    pipeline_info.pMultisampleState = &multisampling
    pipeline_info.pColorBlendState = &color_blending
    pipeline_info.pDynamicState = &dynamic_state
    pipeline_info.layout = vr.pipeline_layout
    pipeline_info.renderPass = vr.render_pass
    pipeline_info.subpass = 0
    /* pipeline_info.basePipelineHandle = 0 */

    if vk.CreateGraphicsPipelines(vr.device, 0, 1, &pipeline_info, nil, &vr.graphics_pipeline) != vk.Result.SUCCESS {
        fmt.println("failed to create graphics pipeline!")
    }
	
	vk.DestroyShaderModule(vr.device, frag_shader_module, nil)
	vk.DestroyShaderModule(vr.device, vert_shader_module, nil)
}

create_shader_module :: proc(code: []u8) -> vk.ShaderModule {
	create_info :vk.ShaderModuleCreateInfo
	create_info.sType = .SHADER_MODULE_CREATE_INFO
	create_info.codeSize = len(code)
	create_info.pCode = cast(^u32) raw_data(code)

	shader_module: vk.ShaderModule
	if vk.CreateShaderModule(vr.device, &create_info, nil, &shader_module) != vk.Result.SUCCESS {
		fmt.println("Failed to create shader module!")
	}

	return shader_module
}

create_image_views :: proc() {
	resize(&vr.swap_chain_image_views, len(vr.swap_chain_images))

	for i := 0; i < len(vr.swap_chain_images); i += 1 {
		create_info := vk.ImageViewCreateInfo{}
		create_info.sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO
		create_info.image = vr.swap_chain_images[i]
		create_info.viewType = vk.ImageViewType.D2
		create_info.format = vr.swap_chain_image_format
		create_info.components.r = vk.ComponentSwizzle.IDENTITY
		create_info.components.g = vk.ComponentSwizzle.IDENTITY
		create_info.components.b = vk.ComponentSwizzle.IDENTITY
		create_info.components.a = vk.ComponentSwizzle.IDENTITY
		create_info.subresourceRange.aspectMask = vk.ImageAspectFlags{.COLOR}
		create_info.subresourceRange.baseMipLevel = 0
		create_info.subresourceRange.levelCount = 1
		create_info.subresourceRange.baseArrayLayer = 0
		create_info.subresourceRange.layerCount = 1

		if vk.CreateImageView(vr.device, &create_info, nil, &vr.swap_chain_image_views[i]) != vk.Result.SUCCESS {
			fmt.println("Failed to create image views!")
		}
	}


}

populate_debug_messenger_create_info :: proc(create_info: ^vk.DebugUtilsMessengerCreateInfoEXT){
	create_info.sType = vk.StructureType.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
	create_info.messageSeverity = vk.DebugUtilsMessageSeverityFlagsEXT{.VERBOSE, .WARNING, .ERROR}
	create_info.messageType = vk.DebugUtilsMessageTypeFlagsEXT{.GENERAL, .VALIDATION, .PERFORMANCE}
	create_info.pfnUserCallback = debug_callback
}

debug_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr) -> b32
{
	context = runtime.default_context()
	fmt.println(pCallbackData.pMessage)
	return false
}

setup_debug_messenger :: proc() {
	if !enable_validation_layer do return

	create_info := vk.DebugUtilsMessengerCreateInfoEXT{}
	populate_debug_messenger_create_info(&create_info)

	/* if vk.CreateDebugUtilsMessengerEXT(instance, &create_info, nil, &debug_messenger) != vk.Result.SUCCESS { */
	/* 	fmt.println("Failed to set up messenger!") */
	/* } */
}

cleanup_swap_chain :: proc() {
	for framebuffer in vr.swap_chain_framebuffers {
		vk.DestroyFramebuffer(vr.device, framebuffer, nil)
	}

	
	for image_view in vr.swap_chain_image_views {
		vk.DestroyImageView(vr.device, image_view, nil)
	}

	vk.DestroySwapchainKHR(vr.device, vr.swap_chain, nil)
}

recreate_swap_chain :: proc() {
	width, height := glfw.GetFramebufferSize(vr.window)

	for width == 0 || height == 0 {
		width, height = glfw.GetFramebufferSize(vr.window)
		glfw.WaitEvents()
	}
	vk.DeviceWaitIdle(vr.device)

	cleanup_swap_chain()

	create_swap_chain()
	create_image_views()
	create_framebuffers()
}

create_swap_chain :: proc() {
	swap_chain_support: SwapChainSupportDetails = query_swap_chain_support(vr.physical_device)
	surface_format := choose_swap_surface_format(swap_chain_support.formats[:])
	present_mode := choose_swap_present_mode(swap_chain_support.present_modes[:])
	extent := choose_swap_extent(swap_chain_support.capatilities)

	/* However, simply sticking to this minimum means that we may sometimes have to wait on the driver to complete internal operations before we can acquire another image to render to. Therefore it is recommended to request at least one more image than the minimum */
	image_count: u32 = swap_chain_support.capatilities.minImageCount + 1

	if swap_chain_support.capatilities.maxImageCount > 0 && image_count > swap_chain_support.capatilities.maxImageCount {
		image_count = swap_chain_support.capatilities.maxImageCount
	}

	create_info := vk.SwapchainCreateInfoKHR{}
	create_info.sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR
	create_info.surface = vr.surface
	create_info.minImageCount = image_count
	create_info.imageFormat = surface_format.format
	create_info.imageColorSpace = surface_format.colorSpace
	create_info.imageExtent = extent
	// The imageArrayLayers specifies the amount of layers each image consists of. This is always 1
	create_info.imageArrayLayers = 1
	// Specifies what kind of operations we'll use the images in the swap chain for
	create_info.imageUsage = vk.ImageUsageFlags{.COLOR_ATTACHMENT}

	indices := find_queue_families(vr.physical_device)
	queue_family_indices: []u32 = {indices.graphicsFamily, indices.presentFamily}

	if indices.graphicsFamily != indices.presentFamily {
		create_info.imageSharingMode = vk.SharingMode.CONCURRENT
		create_info.queueFamilyIndexCount = 2
		create_info.pQueueFamilyIndices = raw_data(queue_family_indices)
	} else {
		create_info.imageSharingMode = vk.SharingMode.EXCLUSIVE
		/* create_info.queueFamilyIndexCount = 0 */
		/* create_info.pQueueFamilyIndices = nil */
	}

	create_info.preTransform = swap_chain_support.capatilities.currentTransform
	create_info.compositeAlpha = vk.CompositeAlphaFlagsKHR{.OPAQUE}
	create_info.presentMode = present_mode
	create_info.clipped = true
	create_info.oldSwapchain = 0

	if vk.CreateSwapchainKHR(vr.device, &create_info, nil, &vr.swap_chain) != vk.Result.SUCCESS {
		fmt.println("Failed to create swap chain!")
	}

	vk.GetSwapchainImagesKHR(vr.device, vr.swap_chain, &image_count, nil)
	resize(&vr.swap_chain_images, int(image_count))
	/* swap_chain_images.resize() */
	vk.GetSwapchainImagesKHR(vr.device, vr.swap_chain, &image_count, raw_data(vr.swap_chain_images))


	vr.swap_chain_image_format = surface_format.format
	vr.swap_chain_extent = extent
}

create_surface :: proc () {
	create_info: vk.Win32SurfaceCreateInfoKHR
	create_info.sType = vk.StructureType.WIN32_SURFACE_CREATE_INFO_KHR
	create_info.hwnd = glfw.GetWin32Window(vr.window)
	create_info.hinstance = win.GetCurrentProcess()

	if vk.CreateWin32SurfaceKHR(vr.instance, &create_info, nil, &vr.surface) != vk.Result.SUCCESS {
		fmt.println("Failed to create window surface")
	}
}

create_logical_device :: proc() {
	indices: QueueFamilyIndices = find_queue_families(vr.physical_device)
	
	// logical device - device queue
	// describes the number o queues we want for a singule queue family
	// we just care about graphics capabilites

	queue_create_infos: [dynamic]vk.DeviceQueueCreateInfo
	defer delete(queue_create_infos)
	unique_queue_families : map[u32]bool = make(map[u32]bool)
	defer delete(unique_queue_families)
	unique_queue_families[indices.graphicsFamily] = true
	unique_queue_families[indices.presentFamily] = true

	/* set priorities to queues to influence the scheduling of command buffer execution using floating point numbers between 0.0 and 1.0. This is required even if there is only a single queue: */
	queue_priority: f32 = 1.0

	for queue_family in unique_queue_families {
		queue_create_info : vk.DeviceQueueCreateInfo = vk.DeviceQueueCreateInfo{}
		queue_create_info.sType = vk.StructureType.DEVICE_QUEUE_CREATE_INFO
		queue_create_info.queueFamilyIndex = queue_family
		queue_create_info.queueCount = 1
		queue_create_info.pQueuePriorities = &queue_priority
		append(&queue_create_infos, queue_create_info)
	}

	device_features: vk.PhysicalDeviceFeatures

	create_info: vk.DeviceCreateInfo
	create_info.sType = vk.StructureType.DEVICE_CREATE_INFO
	create_info.pQueueCreateInfos = raw_data(queue_create_infos)
	create_info.pEnabledFeatures = &device_features
	create_info.queueCreateInfoCount = u32(len(queue_create_infos))
	create_info.pQueueCreateInfos = raw_data(queue_create_infos)
	create_info.enabledExtensionCount = u32(len(device_extensions))
	create_info.ppEnabledExtensionNames = raw_data(device_extensions)


	if vk.CreateDevice(vr.physical_device, &create_info, nil, &vr.device) != vk.Result.SUCCESS {
		fmt.println("Failed to create logical device!")
		return
	}

	vk.GetDeviceQueue(vr.device, indices.graphicsFamily, 0, &vr.graphics_queue)
	vk.GetDeviceQueue(vr.device, indices.presentFamily, 0 , &vr.present_queue)
}


is_device_suitable :: proc(p_device: vk.PhysicalDevice) -> b32 {
	indices: QueueFamilyIndices = find_queue_families(p_device)

	extensions_supported: b32 = check_device_extension_support(p_device)


	swap_chain_adequate : b32 = false

	if extensions_supported {
		swap_chain_support : SwapChainSupportDetails = query_swap_chain_support(p_device)
		swap_chain_adequate = !(len(swap_chain_support.formats) == 0) && !(len(swap_chain_support.present_modes) == 0)
	}

	return indices_is_complete(indices) && extensions_supported && swap_chain_adequate
}

// try to pick the best swap format, but if its not possible just pick the first in the list
choose_swap_surface_format :: proc(available_formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for available_format in available_formats {
		if available_format.format == vk.Format.B8G8R8A8_SRGB && available_format.colorSpace == vk.ColorSpaceKHR.SRGB_NONLINEAR {
			return available_format
		}
	}

	return available_formats[0]
}

// try to pick mailbox present mode, if its not possible pick fifo mode
choose_swap_present_mode :: proc(available_present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	for available_present_mode in available_present_modes {
		if available_present_mode == vk.PresentModeKHR.MAILBOX {
			return available_present_mode
		}
	}
	
	return vk.PresentModeKHR.FIFO
}

// adjust the resolution between glfw and vulkan
choose_swap_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) {
		return capabilities.currentExtent
	} else {
		width, height := glfw.GetFramebufferSize(vr.window)

		actual_extent: vk.Extent2D = {u32(width), u32(height)}

		actual_extent.width  = clamp(actual_extent.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width)
		actual_extent.height = clamp(actual_extent.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height)

		return actual_extent
	}
}

check_device_extension_support :: proc(p_device: vk.PhysicalDevice) -> b32 {
	extension_count: u32
	vk.EnumerateDeviceExtensionProperties(p_device, nil, &extension_count, nil)

	available_extensions :[]vk.ExtensionProperties = make([]vk.ExtensionProperties, extension_count)
	vk.EnumerateDeviceExtensionProperties(p_device, nil, &extension_count, raw_data(available_extensions))

	found_all: b32 = true
	for dev_e in device_extensions {
		found: b32 = false


		for extension in available_extensions {
			a := extension.extensionName
			extension_name := string(a[:len(dev_e)])

			if dev_e == strings.unsafe_string_to_cstring(extension_name) {
				found = true
			}
		}

		if !found {
			found_all = false
		}

	}

	return found_all
}

query_swap_chain_support :: proc(p_device: vk.PhysicalDevice) -> SwapChainSupportDetails {
	details: SwapChainSupportDetails

	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(p_device, vr.surface, &details.capatilities)

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(p_device, vr.surface, &format_count, nil)

	if format_count != 0 {
		resize(&details.formats, int(format_count))
		/* details.formats.resize(format_count) */
		vk.GetPhysicalDeviceSurfaceFormatsKHR(p_device, vr.surface, &format_count, raw_data(details.formats))
	}

	present_mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(p_device, vr.surface, &present_mode_count, nil)

	if present_mode_count != 0 {
		resize(&details.present_modes, int(present_mode_count))
		vk.GetPhysicalDeviceSurfacePresentModesKHR(p_device, vr.surface, &present_mode_count, raw_data(details.present_modes))
	}

	return details
}

find_queue_families :: proc(p_device: vk.PhysicalDevice) -> QueueFamilyIndices {
	indices: QueueFamilyIndices

	queue_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(p_device, &queue_count, nil)

	queueFamilies :[]vk.QueueFamilyProperties = make([]vk.QueueFamilyProperties, queue_count)
	vk.GetPhysicalDeviceQueueFamilyProperties(p_device, &queue_count, raw_data(queueFamilies))


	for queue_family, i in queueFamilies
	{
		if vk.QueueFlag.GRAPHICS in queue_family.queueFlags {
			indices.graphicsFamily = u32(i)
			indices.has_graphics_family = true
		}

		// check if has surface support
		present_support: b32 = false
		vk.GetPhysicalDeviceSurfaceSupportKHR(p_device, u32(i), vr.surface, &present_support)

		if present_support {
			indices.presentFamily = u32(i)
			indices.has_present_family = true
		}

		if indices_is_complete(indices) {
			break;
		}
	}



	return indices
}


draw_frame :: proc () {
	vk.WaitForFences(vr.device, 1, &vr.in_flight_fences[current_frame], true, max(u64))
	vk.ResetFences(vr.device, 1, &vr.in_flight_fences[current_frame])

	image_index: u32
	result := vk.AcquireNextImageKHR(vr.device, vr.swap_chain, max(u64), vr.image_available_semaphores[current_frame], 0, &image_index)

	if result == vk.Result.ERROR_OUT_OF_DATE_KHR {
		recreate_swap_chain()
		return
	} else if result != vk.Result.SUCCESS && result != vk.Result.SUBOPTIMAL_KHR {
		fmt.println("Failed to acquire swap chain image!")
	}

	// Only reset the fence if we are submitting work
	vk.ResetFences(vr.device, 1, &vr.in_flight_fences[current_frame])

	vk.ResetCommandBuffer(vr.command_buffers[current_frame], vk.CommandBufferResetFlags{.RELEASE_RESOURCES})
	record_command_buffer(vr.command_buffers[current_frame], image_index)

	submit_info: vk.SubmitInfo
	submit_info.sType = vk.StructureType.SUBMIT_INFO
	submit_info.waitSemaphoreCount = 1
	submit_info.pWaitSemaphores = &vr.image_available_semaphores[current_frame]
	submit_info.pWaitDstStageMask = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit_info.commandBufferCount = 1
	submit_info.pCommandBuffers = &vr.command_buffers[current_frame]
	submit_info.signalSemaphoreCount = 1
	submit_info.pSignalSemaphores = &vr.render_finished_semaphores[current_frame]

	if vk.QueueSubmit(vr.graphics_queue, 1, &submit_info, vr.in_flight_fences[current_frame]) != vk.Result.SUCCESS {
		fmt.println("Failed to submit draw command buffer!")
	}

	present_info :vk.PresentInfoKHR
	present_info.sType = vk.StructureType.PRESENT_INFO_KHR
	present_info.waitSemaphoreCount = 1
	present_info.pWaitSemaphores = &vr.render_finished_semaphores[current_frame]
	present_info.swapchainCount = 1
	present_info.pSwapchains = &vr.swap_chain
	present_info.pImageIndices = &image_index

	result = vk.QueuePresentKHR(vr.present_queue, &present_info)

	if result == vk.Result.ERROR_OUT_OF_DATE_KHR || result == vk.Result.SUBOPTIMAL_KHR {
		framebuffer_resized = false
		recreate_swap_chain()
		/* return */
	} else if result != vk.Result.SUCCESS {
		fmt.println("Failed to present swap chain image!")
	}

	// By using the modulo (%) operator, we ensure that the frame index loops around after every MAX_FRAMES_IN_FLIGHT enqueued frames.
	current_frame = (current_frame + 1) % MAX_FRAMES_IN_FLIGHT

}

cleanup :: proc() {
	cleanup_swap_chain()
	
	for i := 0; i < MAX_FRAMES_IN_FLIGHT; i += 1 {
		vk.DestroySemaphore(vr.device, vr.render_finished_semaphores[i], nil)
		vk.DestroySemaphore(vr.device, vr.image_available_semaphores[i], nil)
		vk.DestroyFence(vr.device, vr.in_flight_fences[i], nil)
	}

	vk.DestroyCommandPool(vr.device, vr.command_pool, nil)
	
	vk.DestroyPipeline(vr.device, vr.graphics_pipeline, nil)
	vk.DestroyPipelineLayout(vr.device, vr.pipeline_layout, nil)
	vk.DestroyRenderPass(vr.device, vr.render_pass, nil)

	vk.DestroyDevice(vr.device, nil)

	/* if enable_validation_layer { */
		
	/* } */
	
	vk.DestroySurfaceKHR(vr.instance, vr.surface, nil)
	vk.DestroyInstance(vr.instance, nil)
	
	glfw.DestroyWindow(vr.window)
	
	glfw.Terminate()
}


read_file :: proc (path: string) -> string {
	data, ok := os.read_entire_file(path)
	defer delete(data)

	if !ok {
		fmt.println("Failed to open file!")
	}

	return string(data)
}


// odin requirement
get_proc_address :: proc(p: rawptr, name: cstring)
{
	(cast(^rawptr)p)^ = glfw.GetInstanceProcAddress((^vk.Instance)(&vr.instance)^, name);
}
