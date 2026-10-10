#import "PTVulkanContext.h"
#import "PTCore.h"
#import <dlfcn.h>
#import <pthread.h>

#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>
#include "libretro_vulkan.h"

/// Tampons de sortie qui tournent (comme PTGLContext) : l'écran affiche l'un pendant que le suivant se remplit.
#define PT_VK_BUFFERS 3

// Fonctions Vulkan utilisées, trouvées par vkGetInstanceProcAddr / vkGetDeviceProcAddr.
#define PT_VK_INSTANCE_FUNCTIONS(X) \
    X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceQueueFamilyProperties) \
    X(vkEnumerateDeviceExtensionProperties) X(vkCreateDevice) X(vkGetDeviceProcAddr) \
    X(vkGetPhysicalDeviceMemoryProperties) X(vkGetPhysicalDeviceProperties)
#define PT_VK_DEVICE_FUNCTIONS(X) \
    X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkDeviceWaitIdle) X(vkQueueSubmit) X(vkCreateCommandPool) \
    X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) X(vkResetCommandBuffer) X(vkBeginCommandBuffer) \
    X(vkEndCommandBuffer) X(vkCmdPipelineBarrier) X(vkCmdBlitImage) X(vkCreateFence) X(vkDestroyFence) \
    X(vkWaitForFences) X(vkResetFences) X(vkCreateImage) X(vkDestroyImage) X(vkGetImageMemoryRequirements) \
    X(vkAllocateMemory) X(vkFreeMemory) X(vkBindImageMemory)

#define PT_VK_DECLARE(name) static PFN_##name name;
PT_VK_INSTANCE_FUNCTIONS(PT_VK_DECLARE)
PT_VK_DEVICE_FUNCTIONS(PT_VK_DECLARE)
#undef PT_VK_DECLARE
static PFN_vkGetInstanceProcAddr gGetInstanceProcAddr;
static PFN_vkCreateInstance vkCreateInstance;

static void PTVKSetImage(void *handle, const struct retro_vulkan_image *image, uint32_t numSemaphores,
                         const VkSemaphore *semaphores, uint32_t srcQueueFamily);
static uint32_t PTVKGetSyncIndex(void *handle) { return 0; }
static uint32_t PTVKGetSyncIndexMask(void *handle) { return 1; }
static void PTVKSetCommandBuffers(void *handle, uint32_t count, const VkCommandBuffer *buffers);
static void PTVKWaitSyncIndex(void *handle) {}
static void PTVKLockQueue(void *handle);
static void PTVKUnlockQueue(void *handle);
static void PTVKSetSignalSemaphore(void *handle, VkSemaphore semaphore);

@implementation PTVulkanContext {
    void *_library;
    VkInstance _instance;
    VkPhysicalDevice _gpu;
    VkDevice _device;
    VkQueue _queue;
    uint32_t _queueFamily;
    const struct retro_hw_render_context_negotiation_interface_vulkan *_negotiation;
    BOOL _deviceFromCore;
    struct retro_hw_render_interface_vulkan _interface;
    pthread_mutex_t _queueLock;

    VkCommandPool _commandPool;
    VkCommandBuffer _commandBuffer;
    VkFence _fence;
    /// La dernière copie n'était pas finie au bout d'1 s : liste de commandes et barrière encore occupées.
    BOOL _copyPending;

    // Dernière image du moteur (set_image) et ce qui va avec, gardés jusqu'à la copie.
    pthread_mutex_t _imageLock;
    struct retro_vulkan_image _image;
    BOOL _hasImage;
    uint32_t _imageQueueFamily;
    VkSemaphore _waitSemaphores[8];
    uint32_t _waitSemaphoreCount;
    VkSemaphore _signalSemaphore;
    VkCommandBuffer _coreCommandBuffers[8];
    uint32_t _coreCommandBufferCount;

    // Sorties : CVPixelBuffer (IOSurface) et image Vulkan posée sur la même IOSurface.
    CVPixelBufferRef _buffers[PT_VK_BUFFERS];
    VkImage _outputImages[PT_VK_BUFFERS];
    VkDeviceMemory _outputMemory[PT_VK_BUFFERS];
    unsigned _outputWidth;
    unsigned _outputHeight;
    int _current;
    BOOL _loggedFirstFrame;
}

- (instancetype)initWithMoltenVKPath:(NSString *)path applicationInfo:(const void *)applicationInfo {
    if (!(self = [super init])) return nil;
    pthread_mutex_init(&_queueLock, NULL);
    pthread_mutex_init(&_imageLock, NULL);

    _library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!_library) {
        PTLogLine([NSString stringWithFormat:@"Vulkan : MoltenVK introuvable (%s)", dlerror()]);
        return nil;
    }
    gGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(_library, "vkGetInstanceProcAddr");
    if (!gGetInstanceProcAddr) {
        PTLogLine(@"Vulkan : vkGetInstanceProcAddr absent de MoltenVK");
        return nil;
    }
    vkCreateInstance = (PFN_vkCreateInstance)gGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance");

    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "PlayTendo",
        .pEngineName = "PlayTendo",
        .apiVersion = VK_API_VERSION_1_1,
    };
    if (applicationInfo) app = *(const VkApplicationInfo *)applicationInfo;
    if (app.apiVersion < VK_API_VERSION_1_1) app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };
    VkResult result = vkCreateInstance ? vkCreateInstance(&info, NULL, &_instance) : VK_ERROR_INITIALIZATION_FAILED;
    if (result != VK_SUCCESS) {
        PTLogLine([NSString stringWithFormat:@"Vulkan : création de l'instance impossible (%d)", result]);
        return nil;
    }
#define PT_VK_LOAD(name) name = (PFN_##name)gGetInstanceProcAddr(_instance, #name);
    PT_VK_INSTANCE_FUNCTIONS(PT_VK_LOAD)
#undef PT_VK_LOAD

    uint32_t count = 0;
    vkEnumeratePhysicalDevices(_instance, &count, NULL);
    if (count == 0) {
        PTLogLine(@"Vulkan : aucun processeur graphique");
        return nil;
    }
    VkPhysicalDevice gpus[4];
    count = MIN(count, 4u);
    vkEnumeratePhysicalDevices(_instance, &count, gpus);
    _gpu = gpus[0];
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(_gpu, &properties);
    PTLogLine([NSString stringWithFormat:@"Vulkan (MoltenVK) : %s, Vulkan %u.%u", properties.deviceName,
               VK_API_VERSION_MAJOR(properties.apiVersion), VK_API_VERSION_MINOR(properties.apiVersion)]);
    return self;
}

- (void)dealloc {
    [self destroy];
    pthread_mutex_destroy(&_queueLock);
    pthread_mutex_destroy(&_imageLock);
}

#pragma mark Périphérique

- (BOOL)createDeviceWithNegotiation:(const void *)negotiation {
    if (_device) return YES;
    _negotiation = negotiation;
    // Extension indispensable à PlayTendo : poser une image Vulkan sur une IOSurface (lue ensuite par Metal).
    const char *required[] = {VK_EXT_METAL_OBJECTS_EXTENSION_NAME};
    if (_negotiation && _negotiation->interface_type == RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN
        && _negotiation->create_device) {
        struct retro_vulkan_context context = {0};
        VkPhysicalDeviceFeatures features = {0};
        if (_negotiation->create_device(&context, _instance, _gpu, VK_NULL_HANDLE, gGetInstanceProcAddr,
                                        required, 1, NULL, 0, &features)) {
            _gpu = context.gpu;
            _device = context.device;
            _queue = context.queue;
            _queueFamily = context.queue_family_index;
            _deviceFromCore = YES;
        } else {
            PTLogLine(@"Vulkan : le moteur n'a pas créé son périphérique, essai par PlayTendo");
        }
    }
    if (!_device && ![self createOwnDevice:required count:1]) return NO;

#define PT_VK_LOAD(name) name = (PFN_##name)vkGetDeviceProcAddr(_device, #name);
    PT_VK_DEVICE_FUNCTIONS(PT_VK_LOAD)
#undef PT_VK_LOAD

    VkCommandPoolCreateInfo poolInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = _queueFamily,
    };
    VkFenceCreateInfo fenceInfo = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    if (vkCreateCommandPool(_device, &poolInfo, NULL, &_commandPool) != VK_SUCCESS
        || vkCreateFence(_device, &fenceInfo, NULL, &_fence) != VK_SUCCESS) {
        PTLogLine(@"Vulkan : préparation des commandes impossible");
        return NO;
    }
    VkCommandBufferAllocateInfo allocInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = _commandPool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    vkAllocateCommandBuffers(_device, &allocInfo, &_commandBuffer);

    _interface = (struct retro_hw_render_interface_vulkan){
        .interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN,
        .interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION,
        .handle = (__bridge void *)self,
        .instance = _instance,
        .gpu = _gpu,
        .device = _device,
        .get_device_proc_addr = vkGetDeviceProcAddr,
        .get_instance_proc_addr = gGetInstanceProcAddr,
        .queue = _queue,
        .queue_index = _queueFamily,
        .set_image = PTVKSetImage,
        .get_sync_index = PTVKGetSyncIndex,
        .get_sync_index_mask = PTVKGetSyncIndexMask,
        .set_command_buffers = PTVKSetCommandBuffers,
        .wait_sync_index = PTVKWaitSyncIndex,
        .lock_queue = PTVKLockQueue,
        .unlock_queue = PTVKUnlockQueue,
        .set_signal_semaphore = PTVKSetSignalSemaphore,
    };
    PTLogLine([NSString stringWithFormat:@"Vulkan : périphérique prêt (%@)", _deviceFromCore ? @"créé par le moteur" : @"créé par PlayTendo"]);
    return YES;
}

/// Sans négociation : une file graphique, et les extensions demandées (+ portability_subset, exigée par MoltenVK).
- (BOOL)createOwnDevice:(const char **)required count:(uint32_t)requiredCount {
    uint32_t familyCount = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(_gpu, &familyCount, NULL);
    VkQueueFamilyProperties families[8];
    familyCount = MIN(familyCount, 8u);
    vkGetPhysicalDeviceQueueFamilyProperties(_gpu, &familyCount, families);
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < familyCount; i++) {
        if (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { family = i; break; }
    }
    if (family == UINT32_MAX) return NO;
    const char *extensions[4];
    uint32_t extensionCount = 0;
    for (uint32_t i = 0; i < requiredCount; i++) extensions[extensionCount++] = required[i];
    extensions[extensionCount++] = "VK_KHR_portability_subset";
    float priority = 1;
    VkDeviceQueueCreateInfo queueInfo = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    VkDeviceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queueInfo,
        .enabledExtensionCount = extensionCount,
        .ppEnabledExtensionNames = extensions,
    };
    VkResult result = vkCreateDevice(_gpu, &info, NULL, &_device);
    if (result != VK_SUCCESS) {
        PTLogLine([NSString stringWithFormat:@"Vulkan : création du périphérique impossible (%d)", result]);
        return NO;
    }
    PFN_vkGetDeviceQueue getQueue = (PFN_vkGetDeviceQueue)vkGetDeviceProcAddr(_device, "vkGetDeviceQueue");
    getQueue(_device, family, 0, &_queue);
    _queueFamily = family;
    return YES;
}

- (const void *)renderInterface {
    return _device ? &_interface : NULL;
}

#pragma mark Interface du moteur

static void PTVKSetImage(void *handle, const struct retro_vulkan_image *image, uint32_t numSemaphores,
                         const VkSemaphore *semaphores, uint32_t srcQueueFamily) {
    PTVulkanContext *context = (__bridge PTVulkanContext *)handle;
    pthread_mutex_lock(&context->_imageLock);
    context->_hasImage = image != NULL;
    if (image) context->_image = *image;
    context->_imageQueueFamily = srcQueueFamily;
    context->_waitSemaphoreCount = MIN(numSemaphores, 8u);
    for (uint32_t i = 0; i < context->_waitSemaphoreCount; i++) context->_waitSemaphores[i] = semaphores[i];
    pthread_mutex_unlock(&context->_imageLock);
}

static void PTVKSetCommandBuffers(void *handle, uint32_t count, const VkCommandBuffer *buffers) {
    PTVulkanContext *context = (__bridge PTVulkanContext *)handle;
    pthread_mutex_lock(&context->_imageLock);
    context->_coreCommandBufferCount = MIN(count, 8u);
    for (uint32_t i = 0; i < context->_coreCommandBufferCount; i++) context->_coreCommandBuffers[i] = buffers[i];
    pthread_mutex_unlock(&context->_imageLock);
}

static void PTVKLockQueue(void *handle) {
    pthread_mutex_lock(&((__bridge PTVulkanContext *)handle)->_queueLock);
}

static void PTVKUnlockQueue(void *handle) {
    pthread_mutex_unlock(&((__bridge PTVulkanContext *)handle)->_queueLock);
}

static void PTVKSetSignalSemaphore(void *handle, VkSemaphore semaphore) {
    PTVulkanContext *context = (__bridge PTVulkanContext *)handle;
    pthread_mutex_lock(&context->_imageLock);
    context->_signalSemaphore = semaphore;
    pthread_mutex_unlock(&context->_imageLock);
}

#pragma mark Image de sortie

- (void)destroyOutputs {
    for (int i = 0; i < PT_VK_BUFFERS; i++) {
        if (_outputImages[i]) vkDestroyImage(_device, _outputImages[i], NULL);
        if (_outputMemory[i]) vkFreeMemory(_device, _outputMemory[i], NULL);
        if (_buffers[i]) CVPixelBufferRelease(_buffers[i]);
        _outputImages[i] = VK_NULL_HANDLE;
        _outputMemory[i] = VK_NULL_HANDLE;
        _buffers[i] = NULL;
    }
    _outputWidth = 0;
    _outputHeight = 0;
}

/// Trois CVPixelBuffer BGRA sur IOSurface, chacun vu par Vulkan comme une image (VK_EXT_metal_objects).
- (BOOL)ensureOutputWidth:(unsigned)width height:(unsigned)height {
    if (width == _outputWidth && height == _outputHeight && _buffers[0]) return YES;
    if (_outputWidth) vkDeviceWaitIdle(_device);
    [self destroyOutputs];
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    VkPhysicalDeviceMemoryProperties memoryProperties;
    vkGetPhysicalDeviceMemoryProperties(_gpu, &memoryProperties);
    for (int i = 0; i < PT_VK_BUFFERS; i++) {
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attributes, &_buffers[i]) != kCVReturnSuccess) {
            PTLogLine(@"Vulkan : tampon d'image impossible à créer");
            [self destroyOutputs];
            return NO;
        }
        VkImportMetalIOSurfaceInfoEXT surface = {
            .sType = VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT,
            .ioSurface = CVPixelBufferGetIOSurface(_buffers[i]),
        };
        VkImageCreateInfo imageInfo = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &surface,
            .imageType = VK_IMAGE_TYPE_2D,
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .extent = {width, height, 1},
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .tiling = VK_IMAGE_TILING_OPTIMAL,
            .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        };
        VkResult result = vkCreateImage(_device, &imageInfo, NULL, &_outputImages[i]);
        if (result != VK_SUCCESS) {
            PTLogLine([NSString stringWithFormat:@"Vulkan : image de sortie impossible (%d)", result]);
            [self destroyOutputs];
            return NO;
        }
        VkMemoryRequirements requirements;
        vkGetImageMemoryRequirements(_device, _outputImages[i], &requirements);
        uint32_t type = 0;
        for (uint32_t t = 0; t < memoryProperties.memoryTypeCount; t++) {
            if ((requirements.memoryTypeBits & (1u << t))
                && (memoryProperties.memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
                type = t;
                break;
            }
        }
        VkMemoryAllocateInfo allocInfo = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size,
            .memoryTypeIndex = type,
        };
        if (vkAllocateMemory(_device, &allocInfo, NULL, &_outputMemory[i]) != VK_SUCCESS
            || vkBindImageMemory(_device, _outputImages[i], _outputMemory[i], 0) != VK_SUCCESS) {
            PTLogLine(@"Vulkan : mémoire de l'image de sortie impossible");
            [self destroyOutputs];
            return NO;
        }
    }
    _outputWidth = width;
    _outputHeight = height;
    PTLogLine([NSString stringWithFormat:@"Vulkan : image de sortie %u×%u", width, height]);
    return YES;
}

static VkImageMemoryBarrier PTVKBarrier(VkImage image, VkImageLayout from, VkImageLayout to, VkAccessFlags srcAccess,
                                        VkAccessFlags dstAccess, VkImageSubresourceRange range) {
    return (VkImageMemoryBarrier){
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = srcAccess,
        .dstAccessMask = dstAccess,
        .oldLayout = from,
        .newLayout = to,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = range,
    };
}

- (CVPixelBufferRef)finishFrameWithWidth:(unsigned)width height:(unsigned)height {
    if (!_device || width == 0 || height == 0) return NULL;
    // Copie précédente pas encore finie (puce graphique très en retard) : elle est attendue avant de reprendre sa liste
    // de commandes et sa barrière ; toujours pas finie, cette image est sautée (l'image du moteur reste en attente).
    if (_copyPending) {
        if (vkWaitForFences(_device, 1, &_fence, VK_TRUE, 1000000000ull) != VK_SUCCESS) return NULL;
        vkResetFences(_device, 1, &_fence);
        _copyPending = NO;
    }
    pthread_mutex_lock(&_imageLock);
    BOOL hasImage = _hasImage;
    struct retro_vulkan_image image = _image;
    uint32_t waitCount = _waitSemaphoreCount;
    VkSemaphore waits[8];
    memcpy(waits, _waitSemaphores, sizeof waits);
    _waitSemaphoreCount = 0;
    VkSemaphore signal = _signalSemaphore;
    _signalSemaphore = VK_NULL_HANDLE;
    uint32_t coreCount = _coreCommandBufferCount;
    VkCommandBuffer coreBuffers[8];
    memcpy(coreBuffers, _coreCommandBuffers, sizeof coreBuffers);
    _coreCommandBufferCount = 0;
    pthread_mutex_unlock(&_imageLock);
    if (!hasImage || !image.create_info.image) return NULL;
    if (![self ensureOutputWidth:width height:height]) return NULL;

    _current = (_current + 1) % PT_VK_BUFFERS;
    VkImage source = image.create_info.image;
    VkImage target = _outputImages[_current];
    VkImageSubresourceRange sourceRange = image.create_info.subresourceRange;
    sourceRange.levelCount = 1;
    sourceRange.layerCount = 1;
    VkImageSubresourceRange targetRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};

    vkResetCommandBuffer(_commandBuffer, 0);
    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    vkBeginCommandBuffer(_commandBuffer, &begin);
    // L'image du moteur est prête à être lue par un shader : on la passe en source de copie, puis on la lui rend telle
    // qu'il l'a donnée. Les commandes précédentes de la même file sont terminées avant (ALL_COMMANDS).
    VkImageMemoryBarrier before[2] = {
        PTVKBarrier(source, image.image_layout, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_ACCESS_MEMORY_WRITE_BIT,
                    VK_ACCESS_TRANSFER_READ_BIT, sourceRange),
        PTVKBarrier(target, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0,
                    VK_ACCESS_TRANSFER_WRITE_BIT, targetRange),
    };
    vkCmdPipelineBarrier(_commandBuffer, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                         0, NULL, 0, NULL, 2, before);
    VkImageBlit region = {
        .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, sourceRange.baseMipLevel, sourceRange.baseArrayLayer, 1},
        .srcOffsets = {{0, 0, 0}, {(int32_t)width, (int32_t)height, 1}},
        .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .dstOffsets = {{0, 0, 0}, {(int32_t)width, (int32_t)height, 1}},
    };
    vkCmdBlitImage(_commandBuffer, source, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, target,
                   VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region, VK_FILTER_NEAREST);
    VkImageMemoryBarrier after[2] = {
        PTVKBarrier(source, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, image.image_layout, VK_ACCESS_TRANSFER_READ_BIT,
                    VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, sourceRange),
        PTVKBarrier(target, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL, VK_ACCESS_TRANSFER_WRITE_BIT,
                    VK_ACCESS_MEMORY_READ_BIT, targetRange),
    };
    vkCmdPipelineBarrier(_commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0,
                         0, NULL, 0, NULL, 2, after);
    vkEndCommandBuffer(_commandBuffer);

    // Commandes que le moteur a confiées à PlayTendo (set_command_buffers), puis la copie.
    VkCommandBuffer submitted[9];
    uint32_t submittedCount = 0;
    for (uint32_t i = 0; i < coreCount; i++) submitted[submittedCount++] = coreBuffers[i];
    submitted[submittedCount++] = _commandBuffer;
    VkPipelineStageFlags stages[8];
    for (uint32_t i = 0; i < 8; i++) stages[i] = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = waitCount,
        .pWaitSemaphores = waits,
        .pWaitDstStageMask = stages,
        .commandBufferCount = submittedCount,
        .pCommandBuffers = submitted,
        .signalSemaphoreCount = signal ? 1 : 0,
        .pSignalSemaphores = &signal,
    };
    pthread_mutex_lock(&_queueLock);
    VkResult result = vkQueueSubmit(_queue, 1, &submit, _fence);
    pthread_mutex_unlock(&_queueLock);
    if (result != VK_SUCCESS) {
        PTLogLine([NSString stringWithFormat:@"Vulkan : envoi de la copie impossible (%d)", result]);
        return NULL;
    }
    // Attendue ici : l'image est complète quand l'écran la lit (une copie, très courte). Pas finie au bout d'1 s :
    // l'image n'est pas montrée, et la barrière n'est remise à zéro qu'une fois la copie finie (image suivante).
    if (vkWaitForFences(_device, 1, &_fence, VK_TRUE, 1000000000ull) != VK_SUCCESS) {
        _copyPending = YES;
        PTLogLine(@"Vulkan : copie de l'image pas finie au bout d'1 s (puce graphique en retard), image sautée");
        return NULL;
    }
    vkResetFences(_device, 1, &_fence);
    if (!_loggedFirstFrame) {
        _loggedFirstFrame = YES;
        PTLogLine([NSString stringWithFormat:@"Vulkan : première image %u×%u (format %d)", width, height,
                   image.create_info.format]);
    }
    return _buffers[_current];
}

#pragma mark Fin

- (void)destroy {
    if (_device) {
        vkDeviceWaitIdle(_device);
        [self destroyOutputs];
        if (_fence) vkDestroyFence(_device, _fence, NULL);
        if (_commandPool) vkDestroyCommandPool(_device, _commandPool, NULL);
        _fence = VK_NULL_HANDLE;
        _copyPending = NO;
        _commandPool = VK_NULL_HANDLE;
        if (_negotiation && _negotiation->destroy_device) _negotiation->destroy_device();
        vkDestroyDevice(_device, NULL);
        _device = VK_NULL_HANDLE;
    }
    if (_instance) {
        vkDestroyInstance(_instance, NULL);
        _instance = VK_NULL_HANDLE;
    }
    // MoltenVK reste chargé (le décharger pendant que Metal le référence n'apporte rien).
}

@end
