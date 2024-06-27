package main

import "core:fmt"
import "core:strings"
import "core:os"
import win "core:sys/windows"
import "base:runtime"

import glfw "vendor:glfw"
import vk   "vendor:vulkan"

main :: proc() {
	init_window()
	init_vulkan()
	main_loop()
	cleanup()
}


init_window :: proc() {
	glfw.Init()
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	vr.window = glfw.CreateWindow(WIDTH, HEIGHT, "Vulkan", nil, nil)
	/* glfw.SetWindowUserPointer(vr.window, this) */
	glfw.SetFramebufferSizeCallback(vr.window, framebuffer_resize_callback)

	if vr.window == nil {
		glfw.Terminate()
		return
	}

	glfw.SetKeyCallback(vr.window, key_callback)
}


init_vulkan :: proc() {
	vk.load_proc_addresses(get_proc_address)

	create_instance()
	setup_debug_messenger()
	create_surface()
	pick_physical_device()
	create_logical_device()
	create_swap_chain()
	create_image_views()
	create_render_pass()
	create_graphics_pipeline()
	create_framebuffers()
	create_command_pool()
	create_vertex_buffer()
	create_command_buffers()
	create_sync_objects()
}

main_loop :: proc() {
	for !glfw.WindowShouldClose(vr.window) {
		glfw.PollEvents()
		draw_frame()
	}

	vk.DeviceWaitIdle(vr.device)
}



key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
		glfw.SetWindowShouldClose(window, glfw.TRUE)
	}
}


framebuffer_resize_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	/* context := runtime.default_context() */
	framebuffer_resized = true
}
