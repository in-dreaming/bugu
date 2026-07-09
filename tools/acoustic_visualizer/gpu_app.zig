const std = @import("std");
const gpu = @import("gpu_adapter");
const c = gpu.c;
const scene = @import("scene.zig");
const render_cpu = @import("render_cpu.zig");

pub const GpuApp = struct {
    window: c.GpuWindow = null,
    device: c.GpuDevice = null,
    surface: c.GpuSurface = null,
    format: c.GpuFormat = c.GPU_FORMAT_UNDEFINED,
    graphics_queue: c.GpuCommandQueue = null,
    compute_queue: c.GpuCommandQueue = null,
    compiler: c.GpuShaderCompiler = null,
    trace_program: c.GpuShaderProgram = null,
    draw_program: c.GpuShaderProgram = null,
    trace_pipeline: c.GpuComputePipeline = null,
    trace_binding: c.GpuComputeBinding = null,
    render_pipeline: c.GpuRenderPipeline = null,
    draw_layout: c.GpuPipelineLayout = null,
    descriptor_pool: c.GpuDescriptorPool = null,
    draw_set: c.GpuDescriptorSet = null,
    acoustic_buffer: c.GpuBufferHandle = .{ .index = 0, .generation = 0 },
    vertex_buffer: c.GpuBufferHandle = .{ .index = 0, .generation = 0 },
    graphics_support: bool = false,
    compute_support: bool = false,
    graphics_reason: [*:0]const u8 = "",
    compute_reason: [*:0]const u8 = "",

    pub fn init(app: *const scene.AppState, initial_data: []const f32) !GpuApp {
        var self: GpuApp = .{};
        try gpu.checkMsg(c.gpuPlatformInit(), "gpuPlatformInit");

        var win_desc = c.GpuWindowDesc{
            .title = "Bugu Acoustic Ray Visualizer",
            .width = scene.WINDOW_W,
            .height = scene.WINDOW_H,
            .fullscreen = false,
            .resizable = true,
            .vsync = true,
        };
        try gpu.checkMsg(c.gpuCreateWindow(&win_desc, &self.window), "gpuCreateWindow");

        var dev_desc = c.GpuDeviceDesc{
            .appName = "Bugu Acoustic Ray Visualizer",
            .adapterIndex = 0,
            .enableDebugLayer = false,
            .preferredBackend = c.GPU_BACKEND_DEFAULT,
        };
        try gpu.checkMsg(c.gpuCreateDevice(&dev_desc, &self.device), "gpuCreateDevice");

        var graphics_info: c.GpuQueueInfo = std.mem.zeroes(c.GpuQueueInfo);
        var compute_info: c.GpuQueueInfo = std.mem.zeroes(c.GpuQueueInfo);
        _ = c.gpuGetQueueInfo(self.device, c.GPU_QUEUE_TYPE_GRAPHICS, &graphics_info);
        _ = c.gpuGetQueueInfo(self.device, c.GPU_QUEUE_TYPE_COMPUTE, &compute_info);
        self.graphics_support = graphics_info.support != c.GPU_QUEUE_SUPPORT_UNAVAILABLE;
        self.compute_support = compute_info.support != c.GPU_QUEUE_SUPPORT_UNAVAILABLE;
        self.graphics_reason = if (graphics_info.reason != null) graphics_info.reason else "";
        self.compute_reason = if (compute_info.reason != null) compute_info.reason else "";

        try gpu.checkMsg(
            c.gpuCreateSurface(self.device, self.window, c.GPU_SURFACE_TYPE_VULKAN, &self.surface),
            "gpuCreateSurface",
        );
        self.format = c.gpuSurfaceGetPreferredFormat(self.surface);
        try gpu.checkMsg(
            c.gpuSurfaceConfigure(self.surface, scene.WINDOW_W, scene.WINDOW_H, self.format, true),
            "gpuSurfaceConfigure",
        );
        try gpu.checkMsg(c.gpuGetQueue(self.device, c.GPU_QUEUE_TYPE_GRAPHICS, &self.graphics_queue), "graphics queue");
        try gpu.checkMsg(c.gpuGetQueue(self.device, c.GPU_QUEUE_TYPE_COMPUTE, &self.compute_queue), "compute queue");
        try gpu.checkMsg(c.gpuCreateShaderCompiler(self.device, &self.compiler), "shader compiler");

        var trace_desc = c.GpuShaderCompileDesc{
            .sourcePath = "acoustic_trace.slang",
            .entryPoint = "traceMain",
            .fragmentEntryPoint = null,
            .target = c.GPU_SHADER_TARGET_SPIRV,
            .defineNames = null,
            .defineValues = null,
            .defineCount = 0,
        };
        try gpu.checkMsg(c.gpuCompileShader(self.compiler, &trace_desc, &self.trace_program), "compile trace");

        var draw_desc = c.GpuShaderCompileDesc{
            .sourcePath = "acoustic_draw.slang",
            .entryPoint = "vertexMain",
            .fragmentEntryPoint = "fragmentMain",
            .target = c.GPU_SHADER_TARGET_SPIRV,
            .defineNames = null,
            .defineValues = null,
            .defineCount = 0,
        };
        try gpu.checkMsg(c.gpuCompileShader(self.compiler, &draw_desc, &self.draw_program), "compile draw");

        var trace_pipeline_desc = c.GpuComputePipelineDesc{
            .program = self.trace_program,
            .label = "bugu_acoustic_trace",
        };
        try gpu.checkMsg(c.gpuCreateComputePipeline(self.device, &trace_pipeline_desc, &self.trace_pipeline), "trace pipeline");
        try gpu.checkMsg(c.gpuCreateComputeBinding(self.device, self.trace_pipeline, &self.trace_binding), "trace binding");

        var target_desc = c.GpuColorTargetDesc{ .format = self.format };
        var render_pipeline_desc = c.GpuRenderPipelineDesc{
            .program = self.draw_program,
            .primitiveTopology = c.GPU_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .targets = &target_desc,
            .targetCount = 1,
            .label = "bugu_acoustic_draw",
        };
        try gpu.checkMsg(c.gpuCreateRenderPipeline(self.device, &render_pipeline_desc, &self.render_pipeline), "render pipeline");
        try gpu.checkMsg(c.gpuReflectPipelineLayout(self.draw_program, &self.draw_layout), "draw layout");

        var pool_desc = c.GpuDescriptorPoolDesc{
            .maxSets = 8,
            .maxBindingsPerSet = 8,
        };
        try gpu.checkMsg(c.gpuCreateDescriptorPool(self.device, &pool_desc, &self.descriptor_pool), "descriptor pool");

        var acoustic_desc = c.GpuBufferDesc{
            .size = scene.FLOAT_COUNT * @sizeOf(f32),
            .elementSize = @sizeOf(f32),
            .usage = c.GPU_BUFFER_USAGE_UNORDERED_ACCESS | c.GPU_BUFFER_USAGE_COPY_SOURCE | c.GPU_BUFFER_USAGE_COPY_DEST,
            .label = "bugu_acoustic_visualizer_io",
        };
        try gpu.checkMsg(
            c.gpuCreateBufferInit(self.device, &acoustic_desc, initial_data.ptr, &self.acoustic_buffer),
            "acoustic buffer",
        );

        var vertex_desc = c.GpuBufferDesc{
            .size = render_cpu.MAX_VERTICES * @sizeOf(render_cpu.Vertex),
            .elementSize = @sizeOf(f32) * 4,
            .usage = c.GPU_BUFFER_USAGE_SHADER_RESOURCE | c.GPU_BUFFER_USAGE_COPY_DEST,
            .label = "bugu_acoustic_visualizer_vertices",
        };
        try gpu.checkMsg(c.gpuCreateBuffer(self.device, &vertex_desc, &self.vertex_buffer), "vertex buffer");
        try gpu.checkMsg(c.gpuAllocateDescriptorSet(self.descriptor_pool, self.draw_layout, 0, &self.draw_set), "draw set");

        var vertex_write = c.GpuDescriptorWrite{
            .type = c.GPU_DESCRIPTOR_WRITE_BUFFER,
            .buffer = self.vertex_buffer,
            .bufferOffset = 0,
            .bufferRange = render_cpu.MAX_VERTICES * @sizeOf(render_cpu.Vertex),
            .texture = .{ .index = 0, .generation = 0 },
            .sampler = .{ .index = 0, .generation = 0 },
        };
        try gpu.checkMsg(c.gpuUpdateDescriptorSetByName(self.draw_set, "gVertices", &vertex_write), "bind gVertices");
        _ = app;
        return self;
    }

    pub fn deinit(self: *GpuApp) void {
        if (self.graphics_queue != null) _ = c.gpuQueueWaitOnHost(self.graphics_queue);
        if (self.compute_queue != null) _ = c.gpuQueueWaitOnHost(self.compute_queue);
        if (self.draw_set != null) c.gpuFreeDescriptorSet(self.draw_set);
        if (self.device != null and c.gpuHandleIsValid(self.vertex_buffer)) _ = c.gpuDestroyBuffer(self.device, self.vertex_buffer);
        if (self.descriptor_pool != null) c.gpuDestroyDescriptorPool(self.descriptor_pool);
        if (self.draw_layout != null) c.gpuDestroyPipelineLayout(self.draw_layout);
        if (self.device != null and c.gpuHandleIsValid(self.acoustic_buffer)) _ = c.gpuDestroyBuffer(self.device, self.acoustic_buffer);
        if (self.device != null and self.render_pipeline != null) c.gpuDestroyRenderPipeline(self.device, self.render_pipeline);
        if (self.trace_binding != null) c.gpuDestroyComputeBinding(self.trace_binding);
        if (self.device != null and self.trace_pipeline != null) c.gpuDestroyComputePipeline(self.device, self.trace_pipeline);
        if (self.draw_program != null) c.gpuDestroyShaderProgram(self.draw_program);
        if (self.trace_program != null) c.gpuDestroyShaderProgram(self.trace_program);
        if (self.compiler != null) c.gpuDestroyShaderCompiler(self.compiler);
        if (self.surface != null) {
            _ = c.gpuSurfaceUnconfigure(self.surface);
            if (self.device != null) c.gpuDestroySurface(self.device, self.surface);
        }
        if (self.device != null) c.gpuDestroyDevice(self.device);
        if (self.window != null) c.gpuDestroyWindow(self.window);
        c.gpuPlatformShutdown();
        self.* = .{};
    }

    pub fn pollEvents(self: *GpuApp, app: *scene.AppState, quit: *bool) void {
        var ev: c.GpuPlatformEvent = undefined;
        while (c.gpuPollEvent(&ev)) {
            const payload = ev.unnamed_0;
            switch (ev.type) {
                c.GPU_PLATFORM_EVENT_QUIT => quit.* = true,
                c.GPU_PLATFORM_EVENT_RESIZE => {
                    app.width = if (payload.resize.width > 0) payload.resize.width else 1;
                    app.height = if (payload.resize.height > 0) payload.resize.height else 1;
                    _ = c.gpuSurfaceConfigure(self.surface, app.width, app.height, self.format, true);
                },
                c.GPU_PLATFORM_EVENT_KEY_DOWN => app.handleKey(payload.key.keycode, true, quit),
                c.GPU_PLATFORM_EVENT_KEY_UP => app.handleKey(payload.key.keycode, false, quit),
                c.GPU_PLATFORM_EVENT_MOUSE_BUTTON_DOWN => {
                    if (payload.mouse.button == 1) {
                        app.dragging_source = true;
                        app.source = app.screenToWorld(payload.mouse.x, payload.mouse.y);
                    }
                },
                c.GPU_PLATFORM_EVENT_MOUSE_BUTTON_UP => {
                    if (payload.mouse.button == 1) app.dragging_source = false;
                },
                c.GPU_PLATFORM_EVENT_MOUSE_MOVE => {
                    if (app.dragging_source) {
                        app.source = app.screenToWorld(payload.mouse.x, payload.mouse.y);
                    }
                },
                else => {},
            }
        }
    }

    pub fn traceAndReadback(self: *GpuApp, data: []f32) !void {
        try gpu.checkMsg(
            c.gpuUploadToBuffer(self.device, self.acoustic_buffer, data.ptr, data.len * @sizeOf(f32), 0),
            "upload acoustic",
        );

        const compute_encoder = c.gpuBeginCommandEncoder(self.device, self.compute_queue);
        if (compute_encoder == null) return error.GpuFailed;
        const compute_pass = c.gpuCmdBeginComputePass(compute_encoder);
        var res: c.GpuResult = c.GPU_SUCCESS;
        if (compute_pass != null) {
            res = c.gpuComputeBindingDispatch(self.trace_binding, compute_pass, "gAcoustic", self.acoustic_buffer, 2, 1, 1);
            c.gpuCmdEndComputePass(compute_pass);
        } else {
            res = c.GPU_ERROR_INTERNAL;
        }
        const compute_cmd = c.gpuFinishCommandEncoder(compute_encoder);
        try gpu.checkMsg(res, "compute dispatch");
        if (compute_cmd == null) return error.GpuFailed;
        var cmds = [_]c.GpuCommandBuffer{compute_cmd};
        try gpu.checkMsg(c.gpuQueueSubmit(self.compute_queue, 1, &cmds), "compute submit");
        _ = c.gpuQueueWaitOnHost(self.compute_queue);
        try gpu.checkMsg(
            c.gpuDownloadFromBuffer(self.device, self.acoustic_buffer, data.ptr, data.len * @sizeOf(f32), 0),
            "download acoustic",
        );
    }

    pub fn draw(self: *GpuApp, app: *const scene.AppState, vertices: []const render_cpu.Vertex, vertex_count: u32) !void {
        try gpu.checkMsg(
            c.gpuUploadToBuffer(self.device, self.vertex_buffer, vertices.ptr, vertex_count * @sizeOf(render_cpu.Vertex), 0),
            "upload vertices",
        );

        var backbuffer: c.GpuSurfaceTexture = null;
        const acquire = c.gpuSurfaceAcquireNextImage(self.surface, &backbuffer);
        if (acquire != c.GPU_SUCCESS) return;

        const encoder = c.gpuBeginCommandEncoder(self.device, self.graphics_queue);
        if (encoder == null) {
            c.gpuSurfaceTextureRelease(backbuffer);
            return;
        }

        var color_attachment = c.GpuRenderPassColorAttachment{
            .attachment = backbuffer,
            .textureHandle = .{ .index = 0, .generation = 0 },
            .viewHandle = .{ .index = 0, .generation = 0 },
            .mipLevel = 0,
            .loadOp = c.GPU_LOAD_OP_CLEAR,
            .storeOp = c.GPU_STORE_OP_STORE,
            .clearValue = .{ 0.02, 0.024, 0.028, 1.0 },
        };
        var pass_desc = c.GpuRenderPassDesc{
            .colorAttachmentCount = 1,
            .colorAttachments = &color_attachment,
            .depthAttachment = null,
        };
        const pass = c.gpuCmdBeginRenderPass(encoder, &pass_desc);
        if (pass != null) {
            c.gpuCmdBindRenderPipeline(pass, self.render_pipeline);
            c.gpuCmdBindDescriptorSetPass(pass, self.draw_layout, 0, self.draw_set);
            c.gpuCmdSetViewport(pass, 0.0, 0.0, @floatFromInt(app.width), @floatFromInt(app.height));
            c.gpuCmdDraw(pass, vertex_count, 1, 0, 0);
            c.gpuCmdEndRenderPass(pass);
        }
        const cmd = c.gpuFinishCommandEncoder(encoder);
        if (cmd != null) {
            var cmds = [_]c.GpuCommandBuffer{cmd};
            _ = c.gpuQueueSubmit(self.graphics_queue, 1, &cmds);
        }
        _ = c.gpuSurfacePresent(self.surface);
        c.gpuSurfaceTextureRelease(backbuffer);
    }
};
