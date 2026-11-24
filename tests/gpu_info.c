// Which GPU an x86 program reaches through Vulkan, and whether through FEX's thunks: creates a Vulkan instance,
// lists the physical devices with their driver, and says whether the thunk library (libvulkan-guest.so) is the one
// mapped. No window and no Vulkan headers needed (the few types are declared here).
//   gpu_info            exit status 0 with at least one device, 1 without Vulkan or devices
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef int32_t VkResult;
typedef struct VkInstance_T *VkInstance;
typedef struct VkPhysicalDevice_T *VkPhysicalDevice;
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
// VkPhysicalDeviceProperties: apiVersion, driverVersion, vendorID, deviceID, deviceType, deviceName[256], then more;
// the rest is read into the padding
typedef struct {
    uint32_t apiVersion, driverVersion, vendorID, deviceID;
    int32_t deviceType;
    char deviceName[256];
    uint8_t rest[2048];
} VkPhysicalDeviceProperties;

typedef void *(*PFN_vkGetInstanceProcAddr)(VkInstance, const char *);
typedef VkResult (*PFN_vkCreateInstance)(const VkInstanceCreateInfo *, const void *, VkInstance *);
typedef VkResult (*PFN_vkEnumeratePhysicalDevices)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef void (*PFN_vkGetPhysicalDeviceProperties)(VkPhysicalDevice, VkPhysicalDeviceProperties *);
typedef void (*PFN_vkDestroyInstance)(VkInstance, const void *);

static int mapped(const char *name) {
    FILE *f = fopen("/proc/self/maps", "r");
    char line[1024];
    int found = 0;
    if (!f) return 0;
    while (fgets(line, sizeof line, f))
        if (strstr(line, name)) found = 1;
    fclose(f);
    return found;
}

int main(void) {
    void *lib = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!lib) {
        printf("gpu_info: no Vulkan loader (%s)\n", dlerror());
        return 1;
    }
    int thunk = mapped("libvulkan-guest.so");
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    VkApplicationInfo app = {0, NULL, "gpu_info", 1, NULL, 0, (1u << 22) | (1u << 12)};  // Vulkan 1.1
    VkInstanceCreateInfo ci = {1, NULL, 0, &app, 0, NULL, 0, NULL};
    VkInstance inst;
    VkResult r = create(&ci, NULL, &inst);
    if (r != 0) {
        printf("gpu_info: vkCreateInstance failed (%d), thunk %s\n", r, thunk ? "yes" : "no");
        return 1;
    }
    PFN_vkEnumeratePhysicalDevices enumerate = (PFN_vkEnumeratePhysicalDevices)gipa(inst, "vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceProperties props = (PFN_vkGetPhysicalDeviceProperties)gipa(inst, "vkGetPhysicalDeviceProperties");
    PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)gipa(inst, "vkDestroyInstance");
    uint32_t n = 0;
    enumerate(inst, &n, NULL);
    VkPhysicalDevice devs[16];
    if (n > 16) n = 16;
    enumerate(inst, &n, devs);
    static const char *const types[] = {"other", "integrated GPU", "discrete GPU", "virtual GPU", "CPU"};
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p;
        memset(&p, 0, sizeof p);
        props(devs[i], &p);
        printf("gpu_info: device %u: %s (%s, Vulkan %u.%u)\n", i, p.deviceName,
               p.deviceType >= 0 && p.deviceType <= 4 ? types[p.deviceType] : "?", p.apiVersion >> 22,
               (p.apiVersion >> 12) & 0x3ff);
    }
    destroy(inst, NULL);
    printf("gpu_info: %u devices, through FEX's thunk: %s\n", n, thunk || mapped("libvulkan-guest.so") ? "yes" : "no");
    return n > 0 ? 0 : 1;
}
