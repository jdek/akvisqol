// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Vulkan 1.2 compute: SPIR-V with push descriptors, push constants, one
//! queue and a timeline semaphore for fences.
//!
//!   ZIMT_VULKAN_DEVICE=<index|name substring>  pick a device
//!   ZIMT_VULKAN_VALIDATION=1    validation layer; errors fail the next submit
//!   ZIMT_VULKAN_NO_HOST_MAP=1   keep every buffer device-local
const std = @import("std");
const builtin = @import("builtin");
const zimt = @import("root.zig");
const dynlib = @import("dynlib.zig");
const c = @import("vulkan_c");

const log = std.log.scoped(.zimt_vulkan);

const api_version_1_2: u32 = (1 << 22) | (2 << 12);
const spirv_magic: u32 = 0x07230203;
/// Largest staging buffer; bigger transfers go in chunks.
const staging_max: u64 = 32 << 20;

fn Pfn(comptime name: []const u8) type {
    return @typeInfo(@field(c, "PFN_" ++ name)).optional.child;
}

const GlobalFns = struct {
    vkEnumerateInstanceVersion: Pfn("vkEnumerateInstanceVersion"),
    vkEnumerateInstanceLayerProperties: Pfn("vkEnumerateInstanceLayerProperties"),
    vkCreateInstance: Pfn("vkCreateInstance"),
};

const InstanceFns = struct {
    vkDestroyInstance: Pfn("vkDestroyInstance"),
    vkEnumeratePhysicalDevices: Pfn("vkEnumeratePhysicalDevices"),
    vkGetPhysicalDeviceProperties2: Pfn("vkGetPhysicalDeviceProperties2"),
    vkGetPhysicalDeviceFeatures2: Pfn("vkGetPhysicalDeviceFeatures2"),
    vkGetPhysicalDeviceQueueFamilyProperties: Pfn("vkGetPhysicalDeviceQueueFamilyProperties"),
    vkGetPhysicalDeviceMemoryProperties: Pfn("vkGetPhysicalDeviceMemoryProperties"),
    vkEnumerateDeviceExtensionProperties: Pfn("vkEnumerateDeviceExtensionProperties"),
    vkCreateDevice: Pfn("vkCreateDevice"),
    vkGetDeviceProcAddr: Pfn("vkGetDeviceProcAddr"),
};

const DebugFns = struct {
    vkCreateDebugUtilsMessengerEXT: Pfn("vkCreateDebugUtilsMessengerEXT"),
    vkDestroyDebugUtilsMessengerEXT: Pfn("vkDestroyDebugUtilsMessengerEXT"),
};

const DeviceFns = struct {
    vkDestroyDevice: Pfn("vkDestroyDevice"),
    vkGetDeviceQueue: Pfn("vkGetDeviceQueue"),
    vkDeviceWaitIdle: Pfn("vkDeviceWaitIdle"),
    vkQueueWaitIdle: Pfn("vkQueueWaitIdle"),
    vkQueueSubmit: Pfn("vkQueueSubmit"),
    vkCreateCommandPool: Pfn("vkCreateCommandPool"),
    vkDestroyCommandPool: Pfn("vkDestroyCommandPool"),
    vkAllocateCommandBuffers: Pfn("vkAllocateCommandBuffers"),
    vkBeginCommandBuffer: Pfn("vkBeginCommandBuffer"),
    vkEndCommandBuffer: Pfn("vkEndCommandBuffer"),
    vkCreateBuffer: Pfn("vkCreateBuffer"),
    vkDestroyBuffer: Pfn("vkDestroyBuffer"),
    vkGetBufferMemoryRequirements: Pfn("vkGetBufferMemoryRequirements"),
    vkAllocateMemory: Pfn("vkAllocateMemory"),
    vkFreeMemory: Pfn("vkFreeMemory"),
    vkBindBufferMemory: Pfn("vkBindBufferMemory"),
    vkMapMemory: Pfn("vkMapMemory"),
    vkCreateShaderModule: Pfn("vkCreateShaderModule"),
    vkDestroyShaderModule: Pfn("vkDestroyShaderModule"),
    vkCreateDescriptorSetLayout: Pfn("vkCreateDescriptorSetLayout"),
    vkDestroyDescriptorSetLayout: Pfn("vkDestroyDescriptorSetLayout"),
    vkCreatePipelineLayout: Pfn("vkCreatePipelineLayout"),
    vkDestroyPipelineLayout: Pfn("vkDestroyPipelineLayout"),
    vkCreateComputePipelines: Pfn("vkCreateComputePipelines"),
    vkDestroyPipeline: Pfn("vkDestroyPipeline"),
    vkCmdBindPipeline: Pfn("vkCmdBindPipeline"),
    vkCmdPushDescriptorSetKHR: Pfn("vkCmdPushDescriptorSetKHR"),
    vkCmdPushConstants: Pfn("vkCmdPushConstants"),
    vkCmdDispatch: Pfn("vkCmdDispatch"),
    vkCmdPipelineBarrier: Pfn("vkCmdPipelineBarrier"),
    vkCmdCopyBuffer: Pfn("vkCmdCopyBuffer"),
    vkCmdFillBuffer: Pfn("vkCmdFillBuffer"),
    vkCreateSemaphore: Pfn("vkCreateSemaphore"),
    vkDestroySemaphore: Pfn("vkDestroySemaphore"),
    vkWaitSemaphores: Pfn("vkWaitSemaphores"),
    vkGetSemaphoreCounterValue: Pfn("vkGetSemaphoreCounterValue"),
};

fn loadFns(comptime T: type, out: *T, ctx: anytype, get: anytype) bool {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const f = get(ctx, name) orelse {
            log.debug("missing entry point {s}", .{name});
            return false;
        };
        @field(out, name) = @ptrCast(f);
    }
    return true;
}

const lib_names: []const [*:0]const u8 = switch (builtin.os.tag) {
    .windows => &.{"vulkan-1.dll"},
    .macos, .ios => &.{},
    else => &.{"libvulkan.so.1"},
};

var get_instance_proc_addr: Pfn("vkGetInstanceProcAddr") = undefined;
var global: GlobalFns = undefined;

fn loadLoader() bool {
    var lib, _ = dynlib.openFirst(lib_names) orelse return false;
    get_instance_proc_addr = lib.lookup(Pfn("vkGetInstanceProcAddr"), "vkGetInstanceProcAddr") orelse {
        lib.close();
        return false;
    };
    if (!loadFns(GlobalFns, &global, @as(c.VkInstance, null), get_instance_proc_addr)) {
        lib.close();
        return false;
    }
    return true;
}

fn env(name: [*:0]const u8) ?[]const u8 {
    return std.mem.span(std.c.getenv(name) orelse return null);
}

fn envFlag(name: [*:0]const u8) bool {
    const v = env(name) orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

const BufferRec = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    map: ?[*]u8,
    size: u64,
};

const KernelRec = struct {
    shader: c.VkShaderModule,
    set_layout: c.VkDescriptorSetLayout,
    layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
};

const Submission = struct {
    cb: c.VkCommandBuffer,
    value: u64,
};

const State = struct {
    allocator: std.mem.Allocator,
    instance: c.VkInstance,
    inst: InstanceFns,
    debug: ?DebugFns = null,
    messenger: c.VkDebugUtilsMessengerEXT = null,
    validation_errors: std.atomic.Value(u32) = .init(0),
    validation_seen: u32 = 0,
    physical: c.VkPhysicalDevice = null,
    family: u32 = 0,
    device: c.VkDevice = null,
    dev: DeviceFns = undefined,
    queue: c.VkQueue = null,
    pool: c.VkCommandPool = null,
    timeline: c.VkSemaphore = null,
    limits: c.VkPhysicalDeviceLimits = undefined,
    memory: c.VkPhysicalDeviceMemoryProperties = undefined,
    mapped_type: ?u32 = null,
    staging_type: u32 = 0,
    staging: ?*BufferRec = null,
    recording: c.VkCommandBuffer = null,
    /// Capacity covers all `cb_count`, so recycling can't fail.
    free_cbs: std.ArrayList(c.VkCommandBuffer) = .empty,
    cb_count: usize = 0,
};

fn state(d: *zimt.Device) *State {
    return @ptrCast(@alignCast(d.state));
}

fn ok(r: c.VkResult) bool {
    return r == c.VK_SUCCESS;
}

fn check(r: c.VkResult, what: []const u8) !void {
    if (ok(r)) return;
    if (r == c.VK_ERROR_OUT_OF_DEVICE_MEMORY or r == c.VK_ERROR_OUT_OF_HOST_MEMORY) return zimt.Error.OutOfMemory;
    log.err("{s} failed: VkResult {d}", .{ what, r });
    return zimt.Error.DeviceError;
}

fn debugCallback(
    severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    _: c.VkDebugUtilsMessageTypeFlagsEXT,
    data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT,
    user: ?*anyopaque,
) callconv(.c) c.VkBool32 {
    const st: *State = @ptrCast(@alignCast(user.?));
    const msg: [*:0]const u8 = if (data != null and data.*.pMessage != null) @ptrCast(data.*.pMessage) else "(no message)";
    if (severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT != 0) {
        _ = st.validation_errors.fetchAdd(1, .monotonic);
        log.err("validation: {s}", .{msg});
    } else if (severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT != 0) {
        log.warn("validation: {s}", .{msg});
    }
    return c.VK_FALSE;
}

fn checkValidation(st: *State) !void {
    const n = st.validation_errors.load(.monotonic);
    if (n == st.validation_seen) return;
    st.validation_seen = n;
    return zimt.Error.DeviceError;
}

pub fn open(d: *zimt.Device) !void {
    if (!dynlib.Once(loadLoader).call()) return zimt.Error.BackendUnavailable;
    var version: u32 = 0;
    if (!ok(global.vkEnumerateInstanceVersion(&version)) or version < api_version_1_2) {
        log.debug("loader supports Vulkan {d}.{d}, need 1.2", .{ version >> 22, (version >> 12) & 0x3ff });
        return zimt.Error.BackendUnavailable;
    }

    const st = try d.allocator.create(State);
    st.* = .{ .allocator = d.allocator, .instance = null, .inst = undefined };
    d.state = st;
    errdefer destroy(st);
    try createInstance(st);
    try pickDevice(st, d);
    try createDevice(st);
}

fn createInstance(st: *State) !void {
    const validation = envFlag("ZIMT_VULKAN_VALIDATION");
    const layer = "VK_LAYER_KHRONOS_validation";
    if (validation and !hasLayer(st.allocator, layer)) {
        log.err("ZIMT_VULKAN_VALIDATION is set but {s} is not installed (VK_LAYER_PATH?)", .{layer});
        return zimt.Error.BackendUnavailable;
    }
    const enables = [_]c.VkValidationFeatureEnableEXT{c.VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT};
    const features: c.VkValidationFeaturesEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_VALIDATION_FEATURES_EXT,
        .enabledValidationFeatureCount = enables.len,
        .pEnabledValidationFeatures = &enables,
    };
    const app: c.VkApplicationInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pEngineName = "zimt",
        .apiVersion = api_version_1_2,
    };
    const layers = [_][*:0]const u8{layer};
    const exts = [_][*:0]const u8{c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME};
    const info: c.VkInstanceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = if (validation) &features else null,
        .pApplicationInfo = &app,
        .enabledLayerCount = if (validation) layers.len else 0,
        .ppEnabledLayerNames = &layers,
        .enabledExtensionCount = if (validation) exts.len else 0,
        .ppEnabledExtensionNames = &exts,
    };
    const r = global.vkCreateInstance(&info, null, &st.instance);
    if (!ok(r)) {
        if (validation) log.err("vkCreateInstance with validation failed: VkResult {d}", .{r});
        log.debug("vkCreateInstance failed: VkResult {d}", .{r});
        return zimt.Error.BackendUnavailable;
    }
    if (!loadFns(InstanceFns, &st.inst, st.instance, get_instance_proc_addr)) {
        // `destroy` can't use a partial table.
        if (get_instance_proc_addr(st.instance, "vkDestroyInstance")) |f| @as(Pfn("vkDestroyInstance"), @ptrCast(f))(st.instance, null);
        st.instance = null;
        return zimt.Error.BackendUnavailable;
    }

    if (validation) {
        var dbg: DebugFns = undefined;
        if (!loadFns(DebugFns, &dbg, st.instance, get_instance_proc_addr)) {
            log.err("validation requested but VK_EXT_debug_utils is unavailable", .{});
            return zimt.Error.BackendUnavailable;
        }
        st.debug = dbg;
        const mi: c.VkDebugUtilsMessengerCreateInfoEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = debugCallback,
            .pUserData = st,
        };
        try check(dbg.vkCreateDebugUtilsMessengerEXT(st.instance, &mi, null, &st.messenger), "vkCreateDebugUtilsMessengerEXT");
    }
}

fn hasLayer(a: std.mem.Allocator, name: []const u8) bool {
    var n: u32 = 0;
    if (!ok(global.vkEnumerateInstanceLayerProperties(&n, null))) return false;
    const props = a.alloc(c.VkLayerProperties, n) catch return false;
    defer a.free(props);
    if (!ok(global.vkEnumerateInstanceLayerProperties(&n, props.ptr))) return false;
    for (props[0..n]) |p| if (std.mem.eql(u8, std.mem.sliceTo(&p.layerName, 0), name)) return true;
    return false;
}

const Candidate = struct {
    physical: c.VkPhysicalDevice,
    family: u32,
    rank: u8,
};

fn assess(st: *State, pd: c.VkPhysicalDevice, props: *const c.VkPhysicalDeviceProperties) union(enum) { ok: Candidate, unsuitable: []const u8 } {
    if (props.apiVersion < api_version_1_2) return .{ .unsuitable = "Vulkan < 1.2" };

    var timeline: c.VkPhysicalDeviceTimelineSemaphoreFeatures = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES };
    var features: c.VkPhysicalDeviceFeatures2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &timeline };
    st.inst.vkGetPhysicalDeviceFeatures2(pd, &features);
    if (timeline.timelineSemaphore != c.VK_TRUE) return .{ .unsuitable = "no timelineSemaphore" };

    var n: u32 = 0;
    if (!ok(st.inst.vkEnumerateDeviceExtensionProperties(pd, null, &n, null))) return .{ .unsuitable = "cannot list extensions" };
    const exts = st.allocator.alloc(c.VkExtensionProperties, n) catch return .{ .unsuitable = "out of memory" };
    defer st.allocator.free(exts);
    if (!ok(st.inst.vkEnumerateDeviceExtensionProperties(pd, null, &n, exts.ptr))) return .{ .unsuitable = "cannot list extensions" };
    for (exts[0..n]) |e| {
        if (std.mem.eql(u8, std.mem.sliceTo(&e.extensionName, 0), c.VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME)) break;
    } else return .{ .unsuitable = "no " ++ c.VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME };

    var families: [64]c.VkQueueFamilyProperties = undefined;
    var nf: u32 = families.len;
    st.inst.vkGetPhysicalDeviceQueueFamilyProperties(pd, &nf, &families);
    // Prefer a compute-only family.
    var family: ?u32 = null;
    for (families[0..nf], 0..) |f, i| {
        if (f.queueFlags & c.VK_QUEUE_COMPUTE_BIT == 0) continue;
        if (family == null or f.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) family = @intCast(i);
        if (f.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) break;
    }
    const rank: u8 = switch (props.deviceType) {
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 0,
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 1,
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 2,
        c.VK_PHYSICAL_DEVICE_TYPE_CPU => 4,
        else => 3,
    };
    return .{ .ok = .{ .physical = pd, .family = family orelse return .{ .unsuitable = "no compute queue" }, .rank = rank } };
}

fn deviceName(st: *State, pd: c.VkPhysicalDevice, buf: []u8) []const u8 {
    var driver: c.VkPhysicalDeviceDriverProperties = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
    var props: c.VkPhysicalDeviceProperties2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &driver };
    st.inst.vkGetPhysicalDeviceProperties2(pd, &props);
    const dev_name = std.mem.sliceTo(&props.properties.deviceName, 0);
    const drv_name = std.mem.sliceTo(&driver.driverName, 0);
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ dev_name, drv_name }) catch dev_name[0..@min(dev_name.len, buf.len)];
}

fn pickDevice(st: *State, d: *zimt.Device) !void {
    var n: u32 = 0;
    try check(st.inst.vkEnumeratePhysicalDevices(st.instance, &n, null), "vkEnumeratePhysicalDevices");
    const pds = try st.allocator.alloc(c.VkPhysicalDevice, n);
    defer st.allocator.free(pds);
    try check(st.inst.vkEnumeratePhysicalDevices(st.instance, &n, pds.ptr), "vkEnumeratePhysicalDevices");

    const want = env("ZIMT_VULKAN_DEVICE");
    const want_index = if (want) |w| std.fmt.parseInt(usize, w, 10) catch null else null;
    var best: ?Candidate = null;
    var name_buf: [256]u8 = undefined;
    for (pds[0..n], 0..) |pd, i| {
        var props: c.VkPhysicalDeviceProperties2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 };
        st.inst.vkGetPhysicalDeviceProperties2(pd, &props);
        const name = if (props.properties.apiVersion >= api_version_1_2)
            deviceName(st, pd, &name_buf)
        else
            std.mem.sliceTo(&props.properties.deviceName, 0);
        if (want) |w| {
            const match = if (want_index) |wi| wi == i else std.ascii.findIgnoreCase(name, w) != null;
            if (!match) continue;
        }
        switch (assess(st, pd, &props.properties)) {
            .unsuitable => |why| if (want != null)
                log.warn("ZIMT_VULKAN_DEVICE: {s} is unsuitable: {s}", .{ name, why })
            else
                log.debug("skipping {s}: {s}", .{ name, why }),
            .ok => |cand| if (best == null or cand.rank < best.?.rank) {
                best = cand;
            },
        }
        if (want != null and best != null) break;
    }
    const pick = best orelse {
        if (want) |w| log.warn("ZIMT_VULKAN_DEVICE={s}: no suitable device matches", .{w});
        return zimt.Error.BackendUnavailable;
    };
    st.physical = pick.physical;
    st.family = pick.family;
    d.name_len = deviceName(st, pick.physical, &d.name_buf).len;

    var props: c.VkPhysicalDeviceProperties2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 };
    st.inst.vkGetPhysicalDeviceProperties2(pick.physical, &props);
    st.limits = props.properties.limits;
    st.inst.vkGetPhysicalDeviceMemoryProperties(pick.physical, &st.memory);
    chooseMemory(st);
}

/// Host-mapped device memory only where it is most of the device's memory
/// (APUs, ReBAR, CPU drivers): a 256 MiB BAR window is too small and
/// shared with the display.
fn chooseMemory(st: *State) void {
    const m = &st.memory;
    var largest_local: u64 = 0;
    for (m.memoryHeaps[0..m.memoryHeapCount]) |h| {
        if (h.flags & c.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT != 0) largest_local = @max(largest_local, h.size);
    }
    const local = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    const host = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    st.mapped_type = null;
    if (!envFlag("ZIMT_VULKAN_NO_HOST_MAP")) {
        for (m.memoryTypes[0..m.memoryTypeCount], 0..) |t, i| {
            if (t.propertyFlags & (local | host) != (local | host)) continue;
            if (m.memoryHeaps[t.heapIndex].size * 2 < largest_local) continue;
            st.mapped_type = @intCast(i);
            break;
        }
    }
    var best_score: i32 = -1;
    for (m.memoryTypes[0..m.memoryTypeCount], 0..) |t, i| {
        if (t.propertyFlags & host != host) continue;
        var score: i32 = 0;
        if (t.propertyFlags & c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT != 0) score += 2;
        if (t.propertyFlags & local == 0) score += 1;
        if (score > best_score) {
            best_score = score;
            st.staging_type = @intCast(i);
        }
    }
}

fn createDevice(st: *State) !void {
    const family = st.family;
    const priority: f32 = 1.0;
    const queue_info: c.VkDeviceQueueCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    var timeline: c.VkPhysicalDeviceTimelineSemaphoreFeatures = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
        .timelineSemaphore = c.VK_TRUE,
    };
    const exts = [_][*:0]const u8{c.VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME};
    const info: c.VkDeviceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &timeline,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = exts.len,
        .ppEnabledExtensionNames = &exts,
    };
    const r = st.inst.vkCreateDevice(st.physical, &info, null, &st.device);
    if (!ok(r)) {
        log.debug("vkCreateDevice failed: VkResult {d}", .{r});
        return zimt.Error.BackendUnavailable;
    }
    const get = struct {
        fn f(s: *State, name: [:0]const u8) c.PFN_vkVoidFunction {
            return s.inst.vkGetDeviceProcAddr(s.device, name);
        }
    }.f;
    if (!loadFns(DeviceFns, &st.dev, st, get)) {
        // `destroy` can't use a partial table.
        if (get(st, "vkDestroyDevice")) |f| @as(Pfn("vkDestroyDevice"), @ptrCast(f))(st.device, null);
        st.device = null;
        return zimt.Error.BackendUnavailable;
    }
    st.dev.vkGetDeviceQueue(st.device, family, 0, &st.queue);

    const pool_info: c.VkCommandPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = family,
    };
    try check(st.dev.vkCreateCommandPool(st.device, &pool_info, null, &st.pool), "vkCreateCommandPool");

    const type_info: c.VkSemaphoreTypeCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
        .semaphoreType = c.VK_SEMAPHORE_TYPE_TIMELINE,
        .initialValue = 0,
    };
    const sem_info: c.VkSemaphoreCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &type_info };
    try check(st.dev.vkCreateSemaphore(st.device, &sem_info, null, &st.timeline), "vkCreateSemaphore");
}

fn destroy(st: *State) void {
    if (st.device != null) {
        _ = st.dev.vkDeviceWaitIdle(st.device);
        if (st.staging) |s| freeRec(st, s);
        if (st.timeline != null) st.dev.vkDestroySemaphore(st.device, st.timeline, null);
        // Frees every command buffer from it too.
        if (st.pool != null) st.dev.vkDestroyCommandPool(st.device, st.pool, null);
        st.dev.vkDestroyDevice(st.device, null);
    }
    st.free_cbs.deinit(st.allocator);
    if (st.messenger != null) st.debug.?.vkDestroyDebugUtilsMessengerEXT(st.instance, st.messenger, null);
    if (st.instance != null) st.inst.vkDestroyInstance(st.instance, null);
    st.allocator.destroy(st);
}

pub fn close(d: *zimt.Device) void {
    destroy(state(d));
}

fn idleIfBusy(d: *zimt.Device) void {
    const st = state(d);
    if (d.completed < d.submitted) _ = st.dev.vkQueueWaitIdle(st.queue);
}

fn entryPointName(words: []const u32) ?[*:0]const u8 {
    var i: usize = 5;
    while (i < words.len) {
        const len = words[i] >> 16;
        if (len == 0 or i + len > words.len) return null;
        // OpEntryPoint: model, id, name...
        if (words[i] & 0xffff == 15 and len > 3) return @ptrCast(&words[i + 3]);
        i += len;
    }
    return null;
}

pub fn kernel(d: *zimt.Device, comptime K: type, code: []const u8) !zimt.Kernel(K) {
    const st = state(d);
    const n_buf = comptime zimt.bufferCount(K);
    const lim = &st.limits;
    for (K.threads, lim.maxComputeWorkGroupSize) |t, max| if (t > max) {
        log.err("kernel '{s}': {any} threads/group exceeds maxComputeWorkGroupSize {any}", .{ K.name, K.threads, lim.maxComputeWorkGroupSize });
        return zimt.Error.DeviceError;
    };
    if (K.threads[0] * K.threads[1] * K.threads[2] > lim.maxComputeWorkGroupInvocations or
        n_buf > lim.maxPerStageDescriptorStorageBuffers or K.uniform_size > lim.maxPushConstantsSize)
    {
        log.err("kernel '{s}' exceeds device limits ({d} invocations, {d} storage buffers, {d} B push constants)", .{
            K.name, lim.maxComputeWorkGroupInvocations, lim.maxPerStageDescriptorStorageBuffers, lim.maxPushConstantsSize,
        });
        return zimt.Error.DeviceError;
    }
    if (code.len < 20 or code.len % 4 != 0 or std.mem.readInt(u32, code[0..4], .little) != spirv_magic) {
        log.err("kernel '{s}': code is not SPIR-V", .{K.name});
        return zimt.Error.DeviceError;
    }
    // @embedFile data is byte-aligned; SPIR-V must be word-aligned.
    const words = try st.allocator.alloc(u32, code.len / 4);
    defer st.allocator.free(words);
    @memcpy(std.mem.sliceAsBytes(words), code);
    const entry = entryPointName(words) orelse {
        log.err("kernel '{s}': SPIR-V has no entry point", .{K.name});
        return zimt.Error.DeviceError;
    };

    const rec = try st.allocator.create(KernelRec);
    rec.* = .{ .shader = null, .set_layout = null, .layout = null, .pipeline = null };
    errdefer destroyKernel(st, rec);
    const module_info: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = words.ptr,
    };
    try check(st.dev.vkCreateShaderModule(st.device, &module_info, null, &rec.shader), "vkCreateShaderModule");

    const bindings = comptime blk: {
        var b: [@max(n_buf, 1)]c.VkDescriptorSetLayoutBinding = undefined;
        var i: usize = 0;
        for (K.params) |p| switch (p.binding) {
            .buffer => |buf| {
                b[i] = .{
                    .binding = buf.vk_binding,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    .descriptorCount = 1,
                    .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
                };
                i += 1;
            },
            .uniform => {},
        };
        break :blk b;
    };
    const set_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR,
        .bindingCount = n_buf,
        .pBindings = &bindings,
    };
    try check(st.dev.vkCreateDescriptorSetLayout(st.device, &set_info, null, &rec.set_layout), "vkCreateDescriptorSetLayout");

    const range: c.VkPushConstantRange = .{ .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .offset = 0, .size = K.uniform_size };
    const layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &rec.set_layout,
        .pushConstantRangeCount = if (K.uniform_size > 0) 1 else 0,
        .pPushConstantRanges = &range,
    };
    try check(st.dev.vkCreatePipelineLayout(st.device, &layout_info, null, &rec.layout), "vkCreatePipelineLayout");

    const pipe_info: c.VkComputePipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = rec.shader,
            .pName = entry,
        },
        .layout = rec.layout,
    };
    try check(st.dev.vkCreateComputePipelines(st.device, null, 1, &pipe_info, null, &rec.pipeline), "vkCreateComputePipelines");
    return .{ .handle = @intFromPtr(rec), .module = 0 };
}

fn destroyKernel(st: *State, rec: *KernelRec) void {
    if (rec.pipeline != null) st.dev.vkDestroyPipeline(st.device, rec.pipeline, null);
    if (rec.layout != null) st.dev.vkDestroyPipelineLayout(st.device, rec.layout, null);
    if (rec.set_layout != null) st.dev.vkDestroyDescriptorSetLayout(st.device, rec.set_layout, null);
    if (rec.shader != null) st.dev.vkDestroyShaderModule(st.device, rec.shader, null);
    st.allocator.destroy(rec);
}

pub fn release(d: *zimt.Device, handle: usize, _: usize) void {
    idleIfBusy(d);
    destroyKernel(state(d), @ptrFromInt(handle));
}

/// A buffer in memory type `type_index`, mapped if host-visible.
fn allocRec(st: *State, size: u64, type_index: ?u32, local: bool) !*BufferRec {
    const rec = try st.allocator.create(BufferRec);
    errdefer st.allocator.destroy(rec);
    rec.* = .{ .buffer = null, .memory = null, .map = null, .size = size };
    const info: c.VkBufferCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };
    try check(st.dev.vkCreateBuffer(st.device, &info, null, &rec.buffer), "vkCreateBuffer");
    errdefer st.dev.vkDestroyBuffer(st.device, rec.buffer, null);
    var req: c.VkMemoryRequirements = undefined;
    st.dev.vkGetBufferMemoryRequirements(st.device, rec.buffer, &req);
    const t = type_index orelse blk: {
        // First allowed type with all wanted flags, else the first allowed.
        const want: u32 = if (local) c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT else 0;
        var any: ?u32 = null;
        for (st.memory.memoryTypes[0..st.memory.memoryTypeCount], 0..) |mt, i| {
            if (req.memoryTypeBits & (@as(u32, 1) << @intCast(i)) == 0) continue;
            if (mt.propertyFlags & want == want) break :blk @as(u32, @intCast(i));
            if (any == null) any = @intCast(i);
        }
        break :blk any orelse return zimt.Error.OutOfMemory;
    };
    if (req.memoryTypeBits & (@as(u32, 1) << @intCast(t)) == 0) return zimt.Error.OutOfMemory;
    const alloc_info: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = t,
    };
    try check(st.dev.vkAllocateMemory(st.device, &alloc_info, null, &rec.memory), "vkAllocateMemory");
    errdefer st.dev.vkFreeMemory(st.device, rec.memory, null);
    try check(st.dev.vkBindBufferMemory(st.device, rec.buffer, rec.memory, 0), "vkBindBufferMemory");
    if (st.memory.memoryTypes[t].propertyFlags & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT != 0) {
        var p: ?*anyopaque = null;
        try check(st.dev.vkMapMemory(st.device, rec.memory, 0, c.VK_WHOLE_SIZE, 0, &p), "vkMapMemory");
        rec.map = @ptrCast(p);
    }
    return rec;
}

fn freeRec(st: *State, rec: *BufferRec) void {
    st.dev.vkDestroyBuffer(st.device, rec.buffer, null);
    st.dev.vkFreeMemory(st.device, rec.memory, null);
    st.allocator.destroy(rec);
}

pub fn alloc(d: *zimt.Device, bytes: usize) !zimt.Buffer {
    const st = state(d);
    const size: u64 = @max(bytes, 4);
    // Host-mapped where that is the device's main memory; device-local when
    // it isn't, or when the mapped heap is full.
    const rec = if (st.mapped_type) |t|
        allocRec(st, size, t, true) catch |e| switch (e) {
            zimt.Error.OutOfMemory => try allocRec(st, size, null, true),
            else => return e,
        }
    else
        try allocRec(st, size, null, true);
    return .{ .handle = @intFromPtr(rec), .size = bytes, .host = rec.map };
}

pub fn free(d: *zimt.Device, buf: zimt.Buffer) void {
    idleIfBusy(d);
    freeRec(state(d), @ptrFromInt(buf.handle));
}

fn bufRec(buf: zimt.Buffer) *BufferRec {
    return @ptrFromInt(buf.handle);
}

/// Includes host reads after the submission completes.
fn barrier(st: *State, cb: c.VkCommandBuffer) void {
    const stages = c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT;
    const mb: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT |
            c.VK_ACCESS_TRANSFER_READ_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT | c.VK_ACCESS_HOST_READ_BIT,
    };
    st.dev.vkCmdPipelineBarrier(cb, stages, stages | c.VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, null, 0, null);
}

fn acquireCb(st: *State) !c.VkCommandBuffer {
    const cb: c.VkCommandBuffer = st.free_cbs.pop() orelse blk: {
        try st.free_cbs.ensureTotalCapacity(st.allocator, st.cb_count + 1);
        const info: c.VkCommandBufferAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = st.pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var new: c.VkCommandBuffer = null;
        try check(st.dev.vkAllocateCommandBuffers(st.device, &info, &new), "vkAllocateCommandBuffers");
        st.cb_count += 1;
        break :blk new;
    };
    errdefer recycle(st, cb);
    const begin: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    try check(st.dev.vkBeginCommandBuffer(cb, &begin), "vkBeginCommandBuffer");
    return cb;
}

fn recycle(st: *State, cb: c.VkCommandBuffer) void {
    st.free_cbs.appendAssumeCapacity(cb);
}

/// Runs `record` in its own command buffer and waits for it. Transfers are
/// synchronous and only run with no submitted work outstanding.
fn oneShot(st: *State, ctx: anytype, comptime record: fn (@TypeOf(ctx), *State, c.VkCommandBuffer) void) !void {
    const cb = try acquireCb(st);
    defer recycle(st, cb);
    barrier(st, cb);
    record(ctx, st, cb);
    barrier(st, cb);
    try check(st.dev.vkEndCommandBuffer(cb), "vkEndCommandBuffer");
    const si: c.VkSubmitInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
    try check(st.dev.vkQueueSubmit(st.queue, 1, &si, null), "vkQueueSubmit");
    try check(st.dev.vkQueueWaitIdle(st.queue), "vkQueueWaitIdle");
    try checkValidation(st);
}

/// Staging memory of at least `min(len, staging_max)` bytes.
fn stagingBuffer(st: *State, len: usize) !*BufferRec {
    const want: u64 = @min(@max(len, 4), staging_max);
    if (st.staging) |s| {
        if (s.size >= want) return s;
        freeRec(st, s);
        st.staging = null;
    }
    // Grow geometrically so repeated sizes settle quickly.
    const size = @min(staging_max, @max(want, 1 << 20));
    st.staging = try allocRec(st, size, st.staging_type, false);
    return st.staging.?;
}

const Copy = struct {
    src: c.VkBuffer,
    dst: c.VkBuffer,
    region: c.VkBufferCopy,

    fn record(self: Copy, st: *State, cb: c.VkCommandBuffer) void {
        st.dev.vkCmdCopyBuffer(cb, self.src, self.dst, 1, &self.region);
    }
};

pub fn upload(d: *zimt.Device, buf: zimt.Buffer, offset: usize, data: []const u8) !void {
    if (buf.host) |h| return @memcpy(h[offset..][0..data.len], data);
    const st = state(d);
    var done: usize = 0;
    while (done < data.len) {
        const s = try stagingBuffer(st, data.len - done);
        const n: usize = @intCast(@min(s.size, data.len - done));
        @memcpy(s.map.?[0..n], data[done..][0..n]);
        try oneShot(st, Copy{ .src = s.buffer, .dst = bufRec(buf).buffer, .region = .{ .srcOffset = 0, .dstOffset = offset + done, .size = n } }, Copy.record);
        done += n;
    }
}

pub fn download(d: *zimt.Device, buf: zimt.Buffer, offset: usize, out: []u8) !void {
    if (buf.host) |h| return @memcpy(out, h[offset..][0..out.len]);
    const st = state(d);
    var done: usize = 0;
    while (done < out.len) {
        const s = try stagingBuffer(st, out.len - done);
        const n: usize = @intCast(@min(s.size, out.len - done));
        try oneShot(st, Copy{ .src = bufRec(buf).buffer, .dst = s.buffer, .region = .{ .srcOffset = offset + done, .dstOffset = 0, .size = n } }, Copy.record);
        @memcpy(out[done..][0..n], s.map.?[0..n]);
        done += n;
    }
}

pub fn zero(d: *zimt.Device, buf: zimt.Buffer, offset: usize, bytes: usize) !void {
    if (buf.host) |h| return @memset(h[offset..][0..bytes], 0);
    // vkCmdFillBuffer needs 4-byte alignment; the ragged ends go through staging.
    const zeros: [8]u8 = @splat(0);
    const start = std.mem.alignForward(usize, offset, 4);
    const end = std.mem.alignBackward(usize, offset + bytes, 4);
    // No aligned word inside, so fewer than 8 bytes.
    if (start >= end) return upload(d, buf, offset, zeros[0..bytes]);
    if (start > offset) try upload(d, buf, offset, zeros[0 .. start - offset]);
    if (offset + bytes > end) try upload(d, buf, end, zeros[0 .. offset + bytes - end]);
    const Fill = struct {
        buffer: c.VkBuffer,
        offset: u64,
        size: u64,
        fn record(self: @This(), st: *State, cb: c.VkCommandBuffer) void {
            st.dev.vkCmdFillBuffer(cb, self.buffer, self.offset, self.size, 0);
        }
    };
    try oneShot(state(d), Fill{ .buffer = bufRec(buf).buffer, .offset = start, .size = end - start }, Fill.record);
}

pub fn dispatch(d: *zimt.Device, comptime K: type, handle: usize, groups: [3]u32, args: K.Args) !void {
    const st = state(d);
    const kr: *KernelRec = @ptrFromInt(handle);
    // dispatch1d keeps within the guaranteed 65535.
    for (groups, st.limits.maxComputeWorkGroupCount) |g, max| if (g > max) {
        log.err("kernel '{s}': {any} groups exceed maxComputeWorkGroupCount {any}", .{ K.name, groups, st.limits.maxComputeWorkGroupCount });
        return zimt.Error.DeviceError;
    };
    if (st.recording == null) st.recording = try acquireCb(st);
    const cb = st.recording;
    barrier(st, cb);
    st.dev.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_COMPUTE, kr.pipeline);

    const n_buf = comptime zimt.bufferCount(K);
    if (n_buf > 0) {
        var infos: [n_buf]c.VkDescriptorBufferInfo = undefined;
        var writes: [n_buf]c.VkWriteDescriptorSet = undefined;
        comptime var i: usize = 0;
        inline for (K.params) |p| switch (p.binding) {
            .buffer => |b| {
                infos[i] = .{ .buffer = bufRec(@field(args, p.name)).buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
                writes[i] = .{
                    .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstBinding = b.vk_binding,
                    .descriptorCount = 1,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    .pBufferInfo = &infos[i],
                };
                i += 1;
            },
            .uniform => {},
        };
        st.dev.vkCmdPushDescriptorSetKHR(cb, c.VK_PIPELINE_BIND_POINT_COMPUTE, kr.layout, 0, n_buf, &writes);
    }
    if (K.uniform_size > 0) {
        const words = zimt.packUniforms(K, args);
        st.dev.vkCmdPushConstants(cb, kr.layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, K.uniform_size, &words);
    }
    st.dev.vkCmdDispatch(cb, groups[0], groups[1], groups[2]);
}

pub fn submit(d: *zimt.Device) !usize {
    const st = state(d);
    // Before taking the command buffer, so a later submit still has it.
    try checkValidation(st);
    // A failed submit consumed it; root still expects a fence.
    const cb = st.recording orelse try acquireCb(st);
    st.recording = null;
    errdefer recycle(st, cb);
    const sub = try st.allocator.create(Submission);
    errdefer st.allocator.destroy(sub);
    sub.* = .{ .cb = cb, .value = d.submitted + 1 };
    barrier(st, cb);
    try check(st.dev.vkEndCommandBuffer(cb), "vkEndCommandBuffer");
    const ts: c.VkTimelineSemaphoreSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
        .signalSemaphoreValueCount = 1,
        .pSignalSemaphoreValues = &sub.value,
    };
    const si: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = &ts,
        .commandBufferCount = 1,
        .pCommandBuffers = &sub.cb,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &st.timeline,
    };
    try check(st.dev.vkQueueSubmit(st.queue, 1, &si, null), "vkQueueSubmit");
    return @intFromPtr(sub);
}

pub fn finish(d: *zimt.Device, handle: usize, block: bool) !bool {
    const st = state(d);
    const sub: *Submission = @ptrFromInt(handle);
    const result: anyerror!void = if (block) blk: {
        const wi: c.VkSemaphoreWaitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
            .semaphoreCount = 1,
            .pSemaphores = &st.timeline,
            .pValues = &sub.value,
        };
        break :blk check(st.dev.vkWaitSemaphores(st.device, &wi, std.math.maxInt(u64)), "vkWaitSemaphores");
    } else blk: {
        var value: u64 = 0;
        check(st.dev.vkGetSemaphoreCounterValue(st.device, st.timeline, &value), "vkGetSemaphoreCounterValue") catch |e| break :blk e;
        if (value < sub.value) return false;
        break :blk {};
    };
    recycle(st, sub.cb);
    st.allocator.destroy(sub);
    try result;
    try checkValidation(st);
    return true;
}
