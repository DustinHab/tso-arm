// Vulkan as vulkaninfo starts it: an instance with a debug messenger chained into vkCreateInstance (VK_EXT_debug_utils,
// every severity, so that the loader has messages for it), a messenger of its own made with the function
// vkGetInstanceProcAddr gives, and the instance's functions taken through vkGetInstanceProcAddr. With FEX's Vulkan thunk those are the host's own functions, linked to guest-callable thunks;
// the messenger's function is the program's x86 code, which the host's loader called as its own (SIGILL) before the
// thunk took such structures out of the chain. Without a Vulkan library or instance it says so and ends with 0.
//   vkproc     prints "vkproc: N devices through vkGetInstanceProcAddr: ..." or what went wrong (exit status 1)
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef int32_t VkResult;
typedef void *VkInstance;
typedef void *VkPhysicalDevice;
typedef void (*PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(VkInstance, const char *);

typedef struct {
    int32_t sType;
    const void *pNext;
    const char *pApplicationName;
    uint32_t applicationVersion;
    const char *pEngineName;
    uint32_t engineVersion;
    uint32_t apiVersion;
} VkApplicationInfo;

typedef struct {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    const VkApplicationInfo *pApplicationInfo;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
} VkInstanceCreateInfo;

typedef uint32_t (*PFN_vkDebugUtilsMessengerCallbackEXT)(int32_t, uint32_t, const void *, void *);
typedef struct {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    uint32_t messageSeverity;
    uint32_t messageType;
    PFN_vkDebugUtilsMessengerCallbackEXT pfnUserCallback;
    void *pUserData;
} VkDebugUtilsMessengerCreateInfoEXT;

typedef VkResult (*PFN_vkCreateInstance)(const VkInstanceCreateInfo *, const void *, VkInstance *);
typedef VkResult (*PFN_vkCreateDebugUtilsMessengerEXT)(VkInstance, const VkDebugUtilsMessengerCreateInfoEXT *, const void *, uint64_t *);
typedef void (*PFN_vkDestroyDebugUtilsMessengerEXT)(VkInstance, uint64_t, const void *);
typedef void (*PFN_vkDestroyInstance)(VkInstance, const void *);
typedef VkResult (*PFN_vkEnumeratePhysicalDevices)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef void (*PFN_vkGetPhysicalDeviceProperties)(VkPhysicalDevice, void *);

static unsigned messages;

static uint32_t message(int32_t severity, uint32_t types, const void *data, void *user) {
    (void)severity, (void)types, (void)data, (void)user;
    messages++;
    return 0;
}

int main(void) {
    void *lib = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!lib) {
        printf("vkproc: no libvulkan.so.1: nothing to try\n");
        return 0;
    }
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    PFN_vkCreateInstance create = gipa ? (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance") : NULL;
    // VERBOSE, INFO, WARNING, ERROR; GENERAL, VALIDATION, PERFORMANCE
    VkDebugUtilsMessengerCreateInfoEXT dbg = {1000128004, NULL, 0, 0x1111, 0x7, message, NULL};
    const char *ext[] = {"VK_EXT_debug_utils"};
    VkApplicationInfo app = {0, NULL, "vkproc", 1, "vkproc", 1, (1u << 22) | (1u << 12)};
    VkInstanceCreateInfo ci = {1, &dbg, 0, &app, 0, NULL, 1, ext};
    VkInstance inst = NULL;
    int with_messenger = 1;
    if (create && create(&ci, NULL, &inst) != 0) {
        // without VK_EXT_debug_utils, plain
        ci.pNext = NULL, ci.enabledExtensionCount = 0, inst = NULL, with_messenger = 0;
        if (create(&ci, NULL, &inst) != 0) inst = NULL;
    }
    if (!inst) {
        printf("vkproc: no Vulkan instance: nothing to try\n");
        return 0;
    }
    if (ci.pNext != (with_messenger ? (const void *)&dbg : NULL) || dbg.pNext || dbg.pfnUserCallback != message) {
        printf("vkproc: vkCreateInstance changed the application's structures\n");
        return 1;
    }
    PFN_vkEnumeratePhysicalDevices enumerate = (PFN_vkEnumeratePhysicalDevices)gipa(inst, "vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceProperties props = (PFN_vkGetPhysicalDeviceProperties)gipa(inst, "vkGetPhysicalDeviceProperties");
    PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)gipa(inst, "vkDestroyInstance");
    // and a messenger of its own, made with the function vkGetInstanceProcAddr gives (vulkaninfo does): the loader
    // passes it what it reports while the devices are enumerated
    PFN_vkCreateDebugUtilsMessengerEXT create_msgr = with_messenger ? (PFN_vkCreateDebugUtilsMessengerEXT)gipa(inst, "vkCreateDebugUtilsMessengerEXT") : NULL;
    PFN_vkDestroyDebugUtilsMessengerEXT destroy_msgr = with_messenger ? (PFN_vkDestroyDebugUtilsMessengerEXT)gipa(inst, "vkDestroyDebugUtilsMessengerEXT") : NULL;
    uint64_t msgr = 0;
    if (create_msgr && create_msgr(inst, &dbg, NULL, &msgr) != 0) msgr = 0;
    uint32_t n = 0;
    if (!enumerate || enumerate(inst, &n, NULL) != 0) {
        printf("vkproc: vkEnumeratePhysicalDevices through vkGetInstanceProcAddr failed\n");
        return 1;
    }
    VkPhysicalDevice dev[8];
    if (n > 8) n = 8;
    enumerate(inst, &n, dev);
    printf("vkproc: %u devices through vkGetInstanceProcAddr:", n);
    for (uint32_t i = 0; i < n && props; i++) {
        unsigned char p[1024];  // VkPhysicalDeviceProperties: the name at byte 20
        memset(p, 0, sizeof(p));
        props(dev[i], p);
        printf(" %s;", (const char *)p + 20);
    }
    if (msgr && destroy_msgr) destroy_msgr(inst, msgr, NULL);
    if (destroy) destroy(inst, NULL);
    if (with_messenger) {
        printf(" debug messengers (in vkCreateInstance%s): %u messages\n", msgr ? " and of its own" : "", messages);
    } else {
        printf(" no VK_EXT_debug_utils\n");
    }
    return 0;
}
