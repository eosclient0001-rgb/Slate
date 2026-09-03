//============================================================================================================================================
//                                                     SWAPCHAINEXCHANGE.CPP
//============================================================================================================================================
// 🧩 Vulkan instance, surface, device, swapchain and recording-slot transport across the hardware vendor edge.

#include <vulkan/vulkan.h>

#ifndef GLFW_INCLUDE_NONE
    #define GLFW_INCLUDE_NONE
#endif
#include <GLFW/glfw3.h>

#include <imgui.h>
#include <imgui_impl_glfw.h>
#include <imgui_impl_vulkan.h>

#include "SwapchainExchange.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace Frontier {

//------------------------------------------------------------------------------------------------------------------------
//                                           CONSTANTS AND INTERNAL LIMITS
//------------------------------------------------------------------------------------------------------------------------

static constexpr uint32_t kCycleSlotCount  = 2u;
static constexpr uint32_t kLocalGroupSizeX = 16u;
static constexpr uint32_t kLocalGroupSizeY = 16u;

static const char* VulkanResultName(VkResult Result) noexcept
{
    switch (Result)
    {
        case VK_SUCCESS:                       return "VK_SUCCESS";
        case VK_NOT_READY:                     return "VK_NOT_READY";
        case VK_TIMEOUT:                       return "VK_TIMEOUT";
        case VK_EVENT_SET:                     return "VK_EVENT_SET";
        case VK_EVENT_RESET:                   return "VK_EVENT_RESET";
        case VK_INCOMPLETE:                    return "VK_INCOMPLETE";
        case VK_ERROR_OUT_OF_HOST_MEMORY:      return "VK_ERROR_OUT_OF_HOST_MEMORY";
        case VK_ERROR_OUT_OF_DEVICE_MEMORY:    return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
        case VK_ERROR_INITIALIZATION_FAILED:   return "VK_ERROR_INITIALIZATION_FAILED";
        case VK_ERROR_DEVICE_LOST:             return "VK_ERROR_DEVICE_LOST";
        case VK_ERROR_MEMORY_MAP_FAILED:       return "VK_ERROR_MEMORY_MAP_FAILED";
        case VK_ERROR_LAYER_NOT_PRESENT:       return "VK_ERROR_LAYER_NOT_PRESENT";
        case VK_ERROR_EXTENSION_NOT_PRESENT:   return "VK_ERROR_EXTENSION_NOT_PRESENT";
        case VK_ERROR_FEATURE_NOT_PRESENT:     return "VK_ERROR_FEATURE_NOT_PRESENT";
        case VK_ERROR_INCOMPATIBLE_DRIVER:     return "VK_ERROR_INCOMPATIBLE_DRIVER";
        case VK_ERROR_TOO_MANY_OBJECTS:        return "VK_ERROR_TOO_MANY_OBJECTS";
        case VK_ERROR_FORMAT_NOT_SUPPORTED:    return "VK_ERROR_FORMAT_NOT_SUPPORTED";
        case VK_ERROR_FRAGMENTED_POOL:         return "VK_ERROR_FRAGMENTED_POOL";
        case VK_ERROR_SURFACE_LOST_KHR:         return "VK_ERROR_SURFACE_LOST_KHR";
        case VK_ERROR_NATIVE_WINDOW_IN_USE_KHR:return "VK_ERROR_NATIVE_WINDOW_IN_USE_KHR";
        case VK_SUBOPTIMAL_KHR:                 return "VK_SUBOPTIMAL_KHR";
        case VK_ERROR_OUT_OF_DATE_KHR:          return "VK_ERROR_OUT_OF_DATE_KHR";
        default:                                return "VK_ERROR_UNKNOWN";
    }
}

static std::string VulkanFailure(const char* Operation, VkResult Result)
{
    std::ostringstream Stream;
    Stream << Operation << " failed with " << VulkanResultName(Result)
           << " (" << static_cast<int32_t>(Result) << ").";
    return Stream.str();
}

static void GlfwErrorCallback(int ErrorCode, const char* Description) noexcept
{
    std::cerr << "[SwapchainExchange] GLFW error " << ErrorCode << ": "
              << (Description ? Description : "no description") << "\n";
}

static void ImGuiVulkanResultCallback(VkResult Result) noexcept
{
    if (Result != VK_SUCCESS)
        std::cerr << "[SwapchainExchange] ImGui Vulkan backend: "
                  << VulkanResultName(Result) << " (" << static_cast<int32_t>(Result) << ").\n";
}

//------------------------------------------------------------------------------------------------------------------------
//                                              VULKAN RECORD DEFINITION
//------------------------------------------------------------------------------------------------------------------------

struct SwapchainExchange::VulkanRecord
{
    // ── Instance and surface ──────────────────────────────────────────────────────────────────────────────────────────
    VkInstance               Instance              = VK_NULL_HANDLE;
    VkDebugUtilsMessengerEXT DebugMessenger        = VK_NULL_HANDLE;
    VkSurfaceKHR             Surface               = VK_NULL_HANDLE;

    // ── Physical and logical device ───────────────────────────────────────────────────────────────────────────────────
    VkPhysicalDevice                  PhysicalDevice  = VK_NULL_HANDLE;
    VkDevice                          Device          = VK_NULL_HANDLE;
    VkPhysicalDeviceMemoryProperties  MemoryProperties{};
    uint32_t                          GraphicsFamily  = 0u;
    uint32_t                          ComputeFamily   = 0u;
    VkQueue                           GraphicsQueue   = VK_NULL_HANDLE;
    VkQueue                           ComputeQueue    = VK_NULL_HANDLE;

    // ── Swapchain ─────────────────────────────────────────────────────────────────────────────────────────────────────
    VkSwapchainKHR           Swapchain             = VK_NULL_HANDLE;
    VkFormat                 SwapchainFormat       = VK_FORMAT_UNDEFINED;
    VkExtent2D               SwapchainExtent       = {};
    std::vector<VkImage>     SwapchainImages;
    std::vector<VkImageView> SwapchainImageViews;

    // ── Storage image (compute writes; blit to swapchain) ────────────────────────────────────────────────────────────
    VkImage                  StorageImage          = VK_NULL_HANDLE;
    VkDeviceMemory           StorageMemory         = VK_NULL_HANDLE;
    VkImageView              StorageImageView      = VK_NULL_HANDLE;
    bool                     StorageImageSubmitted  = false;

    // ── Scene SSBO geometry and materials ────────────────────────────────────────────────────────────────────────────
    VkBuffer                 TriangleBuffer        = VK_NULL_HANDLE;
    VkDeviceMemory           TriangleMemory        = VK_NULL_HANDLE;
    VkBuffer                 MaterialBuffer        = VK_NULL_HANDLE;
    VkDeviceMemory           MaterialMemory        = VK_NULL_HANDLE;
    uint32_t                 TriangleCount         = 0u;
    uint32_t                 MaterialCount         = 0u;

    // ── Compute pipeline ──────────────────────────────────────────────────────────────────────────────────────────────
    VkDescriptorSetLayout    ComputeDescriptorLayout = VK_NULL_HANDLE;
    VkDescriptorPool         ComputeDescriptorPool   = VK_NULL_HANDLE;
    VkDescriptorSet          ComputeDescriptorSet    = VK_NULL_HANDLE;
    VkPipelineLayout         ComputePipelineLayout   = VK_NULL_HANDLE;
    VkPipeline               ComputePipeline         = VK_NULL_HANDLE;

    // ── Command recording ─────────────────────────────────────────────────────────────────────────────────────────────
    VkCommandPool                ComputeCommandPool = VK_NULL_HANDLE;
    std::vector<VkCommandBuffer> ComputeCommands;

    // ── ImGui render pass and framebuffers ───────────────────────────────────────────────────────────────────────────
    VkDescriptorPool         ImGuiDescriptorPool   = VK_NULL_HANDLE;
    VkRenderPass             ImGuiRenderPass       = VK_NULL_HANDLE;
    std::vector<VkFramebuffer> ImGuiFramebuffers;

    // ── Cycle slots (one fence + two semaphores per slot) ────────────────────────────────────────────────────────────
    std::array<VkSemaphore, kCycleSlotCount> AcquireSemaphores = {};
    std::array<VkSemaphore, kCycleSlotCount> ReleaseSemaphores = {};
    std::array<VkFence,     kCycleSlotCount> CycleFences       = {};
    std::vector<VkFence>                     ImageOrdinalFences;  // [-]  per-image in-flight fence pointer
    uint32_t                                 ActiveSlot         = 0u;
};

//------------------------------------------------------------------------------------------------------------------------
//                                                  VALIDATION CALLBACK
//------------------------------------------------------------------------------------------------------------------------

static VKAPI_ATTR VkBool32 VKAPI_CALL ValidationCallback(
    VkDebugUtilsMessageSeverityFlagBitsEXT,
    VkDebugUtilsMessageTypeFlagsEXT,
    const VkDebugUtilsMessengerCallbackDataEXT* CallbackData,
    void*) noexcept
{
    std::cerr << "[SwapchainExchange] Validation: " << CallbackData->pMessage << "\n";
    return VK_FALSE;
}

//------------------------------------------------------------------------------------------------------------------------
//                                               SPIRV LOADER
//------------------------------------------------------------------------------------------------------------------------

static std::vector<uint32_t> LoadSpirv(const std::string& Path, std::string& Error)
{
    std::ifstream File(Path, std::ios::binary | std::ios::ate);
    if (!File.is_open())
    {
        Error = "Cannot open the SPIR-V shader at '" + Path +
                "'. Rebuild Project-Zero so ReSTIRViewport.spv is copied beside the executable.";
        return {};
    }

    const std::streamsize ByteCount = File.tellg();
    if (ByteCount <= 0 || (ByteCount % static_cast<std::streamsize>(sizeof(uint32_t))) != 0)
    {
        Error = "The SPIR-V shader at '" + Path + "' is empty or has an invalid byte length.";
        return {};
    }

    std::vector<uint32_t> Spirv(static_cast<size_t>(ByteCount) / sizeof(uint32_t));
    File.seekg(0, std::ios::beg);
    if (!File.read(reinterpret_cast<char*>(Spirv.data()), ByteCount))
    {
        Error = "The SPIR-V shader at '" + Path + "' could not be read completely.";
        return {};
    }

    return Spirv;
}

//------------------------------------------------------------------------------------------------------------------------
//                                         BUFFER ALLOCATION HELPER
//------------------------------------------------------------------------------------------------------------------------

static VkResult AllocateBuffer(
    VkDevice                                  Device,
    const VkPhysicalDeviceMemoryProperties&   MemoryProperties,
    VkDeviceSize                              ByteCount,
    VkBufferUsageFlags                        UsageFlags,
    VkMemoryPropertyFlags                     MemoryFlags,
    VkBuffer&                                 OutBuffer,
    VkDeviceMemory&                           OutMemory) noexcept
{
    OutBuffer = VK_NULL_HANDLE;
    OutMemory = VK_NULL_HANDLE;

    VkBufferCreateInfo BufferInfo{};
    BufferInfo.sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    BufferInfo.size        = ByteCount;
    BufferInfo.usage       = UsageFlags;
    BufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    VkResult Result = vkCreateBuffer(Device, &BufferInfo, nullptr, &OutBuffer);
    if (Result != VK_SUCCESS) return Result;

    VkMemoryRequirements Requirements{};
    vkGetBufferMemoryRequirements(Device, OutBuffer, &Requirements);

    uint32_t MemoryTypeIndex = std::numeric_limits<uint32_t>::max();
    for (uint32_t Index = 0u; Index < MemoryProperties.memoryTypeCount; ++Index)
    {
        if ((Requirements.memoryTypeBits & (1u << Index)) != 0u &&
            (MemoryProperties.memoryTypes[Index].propertyFlags & MemoryFlags) == MemoryFlags)
        {
            MemoryTypeIndex = Index;
            break;
        }
    }

    if (MemoryTypeIndex == std::numeric_limits<uint32_t>::max())
    {
        vkDestroyBuffer(Device, OutBuffer, nullptr);
        OutBuffer = VK_NULL_HANDLE;
        return VK_ERROR_FEATURE_NOT_PRESENT;
    }

    VkMemoryAllocateInfo AllocateInfo{};
    AllocateInfo.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    AllocateInfo.allocationSize  = Requirements.size;
    AllocateInfo.memoryTypeIndex = MemoryTypeIndex;

    Result = vkAllocateMemory(Device, &AllocateInfo, nullptr, &OutMemory);
    if (Result != VK_SUCCESS)
    {
        vkDestroyBuffer(Device, OutBuffer, nullptr);
        OutBuffer = VK_NULL_HANDLE;
        return Result;
    }

    Result = vkBindBufferMemory(Device, OutBuffer, OutMemory, 0u);
    if (Result != VK_SUCCESS)
    {
        vkFreeMemory(Device, OutMemory, nullptr);
        vkDestroyBuffer(Device, OutBuffer, nullptr);
        OutMemory = VK_NULL_HANDLE;
        OutBuffer = VK_NULL_HANDLE;
    }
    return Result;
}

//============================================================================================================================================
//                                                     LIFECYCLE
//============================================================================================================================================

SwapchainExchange::SwapchainExchange(const SwapchainConfiguration& InitialConfiguration) noexcept
    : Vulkan(new VulkanRecord{})
    , GlfwWindow(nullptr)
    , Configuration(InitialConfiguration)
    , LastError()
    , ResizePending(false)
    , GlfwInitialised(false)
    , ImGuiContextInitialised(false)
    , ImGuiGlfwInitialised(false)
    , ImGuiVulkanInitialised(false)
    , SceneDescriptorsReady(false)
    , ForwardInput(nullptr)
    , PreviousCursorX(0.0)
    , PreviousCursorY(0.0)
    , CursorInitialised(false)
{
}

SwapchainExchange::~SwapchainExchange() noexcept
{
    Retire();
    delete Vulkan;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                       BRING
//------------------------------------------------------------------------------------------------------------------------

bool SwapchainExchange::Bring() noexcept
{
    LastError.clear();
    glfwSetErrorCallback(GlfwErrorCallback);

    if (!glfwInit())
    {
        const char* Description = nullptr;
        const int ErrorCode = glfwGetError(&Description);
        std::ostringstream Message;
        Message << "glfwInit failed (" << ErrorCode << "): "
                << (Description ? Description : "no GLFW error description") << '.';
        return ReportFailure(Message.str());
    }
    GlfwInitialised = true;
    std::cout << "[SwapchainExchange] GLFW runtime: " << glfwGetVersionString() << "\n" << std::flush;

    if (!glfwVulkanSupported())
    {
        (void)ReportFailure("GLFW cannot find a Vulkan loader/driver. Install a current GPU driver and the Vulkan runtime.");
        Retire();
        return false;
    }

    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindowHint(GLFW_RESIZABLE,  GLFW_TRUE);
    glfwWindowHint(GLFW_VISIBLE,    GLFW_TRUE);
    glfwWindowHint(GLFW_FOCUSED,    GLFW_TRUE);

    GlfwWindow = glfwCreateWindow(
        static_cast<int>(Configuration.Width),
        static_cast<int>(Configuration.Height),
        Configuration.Title ? Configuration.Title : "Frontier",
        nullptr, nullptr);

    if (!GlfwWindow)
    {
        const char* Description = nullptr;
        const int ErrorCode = glfwGetError(&Description);
        std::ostringstream Message;
        Message << "glfwCreateWindow failed (" << ErrorCode << "): "
                << (Description ? Description : "no GLFW error description") << '.';
        (void)ReportFailure(Message.str());
        Retire();
        return false;
    }

    glfwSetWindowUserPointer      (GlfwWindow, this);
    glfwSetKeyCallback            (GlfwWindow, OnKey);
    glfwSetMouseButtonCallback    (GlfwWindow, OnMouseButton);
    glfwSetCursorPosCallback      (GlfwWindow, OnCursorMove);
    glfwSetScrollCallback         (GlfwWindow, OnScroll);
    glfwSetFramebufferSizeCallback(GlfwWindow, OnFramebuffer);

    // Make the native window observable while Vulkan resources are prepared.
    glfwShowWindow(GlfwWindow);
    glfwPollEvents();

    struct BringStage
    {
        const char* Name;
        bool (SwapchainExchange::*Operation)() noexcept;
    };

    constexpr std::array<BringStage, 11u> Stages = {{
        { "Vulkan instance",          &SwapchainExchange::BringInstance },
        { "window surface",           &SwapchainExchange::BringSurface },
        { "physical device",          &SwapchainExchange::BringPhysicalDevice },
        { "logical device",           &SwapchainExchange::BringLogicalDevice },
        { "swapchain",                &SwapchainExchange::BringSwapchain },
        { "storage image",            &SwapchainExchange::BringStorageImage },
        { "command recording",        &SwapchainExchange::BringCommandRecording },
        { "compute pipeline",         &SwapchainExchange::BringComputePipeline },
        { "descriptor set",           &SwapchainExchange::BringDescriptorSet },
        { "frame synchronization",    &SwapchainExchange::BringCycleSlots },
        { "ImGui",                    &SwapchainExchange::BringImGui }
    }};

    for (const BringStage& Stage : Stages)
    {
        std::cout << "[SwapchainExchange] Initializing " << Stage.Name << "...\n" << std::flush;
        if (!(this->*Stage.Operation)())
        {
            if (LastError.empty())
                (void)ReportFailure(std::string("Failed while initializing ") + Stage.Name + '.');
            Retire();
            return false;
        }
    }

    glfwShowWindow(GlfwWindow);
    glfwFocusWindow(GlfwWindow);
    glfwPollEvents();
    std::cout << "[SwapchainExchange] Native window and Vulkan renderer are ready.\n" << std::flush;
    return true;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                       RETIRE
//------------------------------------------------------------------------------------------------------------------------

void SwapchainExchange::Retire() noexcept
{
    if (!Vulkan) return;

    if (Vulkan->Device)
    {
        (void)vkDeviceWaitIdle(Vulkan->Device);

        if (ImGuiVulkanInitialised)
        {
            ImGui_ImplVulkan_Shutdown();
            ImGuiVulkanInitialised = false;
        }
        if (ImGuiGlfwInitialised)
        {
            ImGui_ImplGlfw_Shutdown();
            ImGuiGlfwInitialised = false;
        }
        if (ImGuiContextInitialised)
        {
            ImGui::DestroyContext();
            ImGuiContextInitialised = false;
        }

        for (VkFramebuffer& Framebuffer : Vulkan->ImGuiFramebuffers)
            if (Framebuffer) vkDestroyFramebuffer(Vulkan->Device, Framebuffer, nullptr);
        Vulkan->ImGuiFramebuffers.clear();

        if (Vulkan->ImGuiRenderPass)
            vkDestroyRenderPass(Vulkan->Device, Vulkan->ImGuiRenderPass, nullptr);
        if (Vulkan->ImGuiDescriptorPool)
            vkDestroyDescriptorPool(Vulkan->Device, Vulkan->ImGuiDescriptorPool, nullptr);

        RetireSwapchain();

        if (Vulkan->TriangleBuffer) vkDestroyBuffer(Vulkan->Device, Vulkan->TriangleBuffer, nullptr);
        if (Vulkan->TriangleMemory) vkFreeMemory(Vulkan->Device, Vulkan->TriangleMemory, nullptr);
        if (Vulkan->MaterialBuffer) vkDestroyBuffer(Vulkan->Device, Vulkan->MaterialBuffer, nullptr);
        if (Vulkan->MaterialMemory) vkFreeMemory(Vulkan->Device, Vulkan->MaterialMemory, nullptr);

        for (uint32_t Slot = 0u; Slot < kCycleSlotCount; ++Slot)
        {
            if (Vulkan->AcquireSemaphores[Slot])
                vkDestroySemaphore(Vulkan->Device, Vulkan->AcquireSemaphores[Slot], nullptr);
            if (Vulkan->ReleaseSemaphores[Slot])
                vkDestroySemaphore(Vulkan->Device, Vulkan->ReleaseSemaphores[Slot], nullptr);
            if (Vulkan->CycleFences[Slot])
                vkDestroyFence(Vulkan->Device, Vulkan->CycleFences[Slot], nullptr);
        }

        if (Vulkan->ComputeCommandPool)
            vkDestroyCommandPool(Vulkan->Device, Vulkan->ComputeCommandPool, nullptr);
        if (Vulkan->ComputePipeline)
            vkDestroyPipeline(Vulkan->Device, Vulkan->ComputePipeline, nullptr);
        if (Vulkan->ComputePipelineLayout)
            vkDestroyPipelineLayout(Vulkan->Device, Vulkan->ComputePipelineLayout, nullptr);
        if (Vulkan->ComputeDescriptorPool)
            vkDestroyDescriptorPool(Vulkan->Device, Vulkan->ComputeDescriptorPool, nullptr);
        if (Vulkan->ComputeDescriptorLayout)
            vkDestroyDescriptorSetLayout(Vulkan->Device, Vulkan->ComputeDescriptorLayout, nullptr);

        vkDestroyDevice(Vulkan->Device, nullptr);
    }
    else if (ImGuiContextInitialised)
    {
        // A context can only survive without a device when initialization stopped midway.
        ImGui::DestroyContext();
        ImGuiContextInitialised = false;
        ImGuiGlfwInitialised = false;
        ImGuiVulkanInitialised = false;
    }

    if (Vulkan->DebugMessenger && Vulkan->Instance)
    {
        const auto DestroyMessenger = reinterpret_cast<PFN_vkDestroyDebugUtilsMessengerEXT>(
            vkGetInstanceProcAddr(Vulkan->Instance, "vkDestroyDebugUtilsMessengerEXT"));
        if (DestroyMessenger)
            DestroyMessenger(Vulkan->Instance, Vulkan->DebugMessenger, nullptr);
    }
    if (Vulkan->Surface && Vulkan->Instance)
        vkDestroySurfaceKHR(Vulkan->Instance, Vulkan->Surface, nullptr);
    if (Vulkan->Instance)
        vkDestroyInstance(Vulkan->Instance, nullptr);

    *Vulkan = VulkanRecord{};
    SceneDescriptorsReady = false;
    ResizePending = false;
    ForwardInput = nullptr;

    if (GlfwWindow)
    {
        glfwDestroyWindow(GlfwWindow);
        GlfwWindow = nullptr;
    }
    if (GlfwInitialised)
    {
        glfwTerminate();
        GlfwInitialised = false;
    }
}

bool SwapchainExchange::ReportFailure(std::string Message) noexcept
{
    LastError = std::move(Message);
    std::cerr << "[SwapchainExchange] " << LastError << "\n" << std::flush;
    return false;
}

//------------------------------------------------------------------------------------------------------------------------
//                                               RETIRE SWAPCHAIN  (inner)
//------------------------------------------------------------------------------------------------------------------------

void SwapchainExchange::RetireSwapchain() noexcept
{
    if (Vulkan->StorageImageView)  vkDestroyImageView(Vulkan->Device, Vulkan->StorageImageView,  nullptr);
    if (Vulkan->StorageImage)      vkDestroyImage    (Vulkan->Device, Vulkan->StorageImage,      nullptr);
    if (Vulkan->StorageMemory)     vkFreeMemory      (Vulkan->Device, Vulkan->StorageMemory,     nullptr);
    Vulkan->StorageImageView     = VK_NULL_HANDLE;
    Vulkan->StorageImage         = VK_NULL_HANDLE;
    Vulkan->StorageMemory        = VK_NULL_HANDLE;
    Vulkan->StorageImageSubmitted = false;

    for (VkImageView& ImageView : Vulkan->SwapchainImageViews)
        if (ImageView) vkDestroyImageView(Vulkan->Device, ImageView, nullptr);
    Vulkan->SwapchainImageViews.clear();
    Vulkan->SwapchainImages.clear();
    Vulkan->ImageOrdinalFences.clear();

    if (Vulkan->Swapchain) vkDestroySwapchainKHR(Vulkan->Device, Vulkan->Swapchain, nullptr);
    Vulkan->Swapchain = VK_NULL_HANDLE;
    SceneDescriptorsReady = false;
}

//============================================================================================================================================
//                                                   BRING-UP STAGES
//============================================================================================================================================

bool SwapchainExchange::BringInstance() noexcept
{
    VkApplicationInfo ApplicationInfo{};
    ApplicationInfo.sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    ApplicationInfo.pApplicationName   = Configuration.Title ? Configuration.Title : "Project-Zero";
    ApplicationInfo.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
    ApplicationInfo.pEngineName        = "Frontier";
    ApplicationInfo.engineVersion      = VK_MAKE_VERSION(1, 0, 0);
    ApplicationInfo.apiVersion         = VK_API_VERSION_1_2;

    uint32_t GlfwExtensionCount = 0u;
    const char** GlfwExtensions = glfwGetRequiredInstanceExtensions(&GlfwExtensionCount);
    if (!GlfwExtensions || GlfwExtensionCount == 0u)
        return ReportFailure("GLFW did not provide the Vulkan instance extensions required by this window system.");

    std::vector<const char*> Extensions(GlfwExtensions, GlfwExtensions + GlfwExtensionCount);
    std::vector<const char*> Layers;

    if (Configuration.ValidationEnabled)
    {
        uint32_t LayerCount = 0u;
        VkResult Result = vkEnumerateInstanceLayerProperties(&LayerCount, nullptr);
        if (Result != VK_SUCCESS)
            return ReportFailure(VulkanFailure("vkEnumerateInstanceLayerProperties", Result));

        std::vector<VkLayerProperties> AvailableLayers(LayerCount);
        Result = vkEnumerateInstanceLayerProperties(&LayerCount, AvailableLayers.data());
        if (Result != VK_SUCCESS)
            return ReportFailure(VulkanFailure("vkEnumerateInstanceLayerProperties", Result));

        const bool ValidationAvailable = std::any_of(
            AvailableLayers.begin(), AvailableLayers.end(), [](const VkLayerProperties& Layer)
            {
                return std::strcmp(Layer.layerName, "VK_LAYER_KHRONOS_validation") == 0;
            });
        if (!ValidationAvailable)
            return ReportFailure("Vulkan validation was requested, but VK_LAYER_KHRONOS_validation is not installed.");

        Extensions.push_back(VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
        Layers.push_back("VK_LAYER_KHRONOS_validation");
    }

    VkInstanceCreateInfo InstanceInfo{};
    InstanceInfo.sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    InstanceInfo.pApplicationInfo        = &ApplicationInfo;
    InstanceInfo.enabledExtensionCount   = static_cast<uint32_t>(Extensions.size());
    InstanceInfo.ppEnabledExtensionNames = Extensions.data();
    InstanceInfo.enabledLayerCount       = static_cast<uint32_t>(Layers.size());
    InstanceInfo.ppEnabledLayerNames     = Layers.data();

    VkResult Result = vkCreateInstance(&InstanceInfo, nullptr, &Vulkan->Instance);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateInstance", Result));

    if (Configuration.ValidationEnabled)
    {
        const auto CreateMessenger = reinterpret_cast<PFN_vkCreateDebugUtilsMessengerEXT>(
            vkGetInstanceProcAddr(Vulkan->Instance, "vkCreateDebugUtilsMessengerEXT"));
        if (!CreateMessenger)
            return ReportFailure("vkCreateDebugUtilsMessengerEXT is unavailable although validation was enabled.");

        VkDebugUtilsMessengerCreateInfoEXT MessengerInfo{};
        MessengerInfo.sType           = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
        MessengerInfo.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
                                      | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
        MessengerInfo.messageType     = VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
                                      | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        MessengerInfo.pfnUserCallback = ValidationCallback;

        Result = CreateMessenger(Vulkan->Instance, &MessengerInfo, nullptr, &Vulkan->DebugMessenger);
        if (Result != VK_SUCCESS)
            return ReportFailure(VulkanFailure("vkCreateDebugUtilsMessengerEXT", Result));
    }

    return true;
}

bool SwapchainExchange::BringSurface() noexcept
{
    const VkResult Result = glfwCreateWindowSurface(
        Vulkan->Instance, GlfwWindow, nullptr, &Vulkan->Surface);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("glfwCreateWindowSurface", Result));
    return true;
}

bool SwapchainExchange::BringPhysicalDevice() noexcept
{
    uint32_t DeviceCount = 0u;
    VkResult Result = vkEnumeratePhysicalDevices(Vulkan->Instance, &DeviceCount, nullptr);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkEnumeratePhysicalDevices", Result));
    if (DeviceCount == 0u)
        return ReportFailure("No Vulkan physical device was found. Install the Vulkan-capable driver from your GPU vendor.");

    std::vector<VkPhysicalDevice> Devices(DeviceCount);
    Result = vkEnumeratePhysicalDevices(Vulkan->Instance, &DeviceCount, Devices.data());
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkEnumeratePhysicalDevices", Result));

    VkPhysicalDevice SelectedDevice = VK_NULL_HANDLE;
    uint32_t SelectedFamily = std::numeric_limits<uint32_t>::max();
    uint32_t SelectedScore = 0u;
    VkPhysicalDeviceProperties SelectedProperties{};

    for (VkPhysicalDevice Candidate : Devices)
    {
        VkPhysicalDeviceProperties Properties{};
        vkGetPhysicalDeviceProperties(Candidate, &Properties);
        if (VK_VERSION_MAJOR(Properties.apiVersion) < 1u ||
            (VK_VERSION_MAJOR(Properties.apiVersion) == 1u && VK_VERSION_MINOR(Properties.apiVersion) < 2u))
        {
            continue;
        }

        uint32_t ExtensionCount = 0u;
        Result = vkEnumerateDeviceExtensionProperties(Candidate, nullptr, &ExtensionCount, nullptr);
        if (Result != VK_SUCCESS) continue;

        std::vector<VkExtensionProperties> Extensions(ExtensionCount);
        Result = vkEnumerateDeviceExtensionProperties(Candidate, nullptr, &ExtensionCount, Extensions.data());
        if (Result != VK_SUCCESS) continue;

        const bool SwapchainExtensionAvailable = std::any_of(
            Extensions.begin(), Extensions.end(), [](const VkExtensionProperties& Extension)
            {
                return std::strcmp(Extension.extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0;
            });
        if (!SwapchainExtensionAvailable) continue;

        uint32_t FormatCount = 0u;
        uint32_t PresentModeCount = 0u;
        if (vkGetPhysicalDeviceSurfaceFormatsKHR(Candidate, Vulkan->Surface, &FormatCount, nullptr) != VK_SUCCESS ||
            vkGetPhysicalDeviceSurfacePresentModesKHR(Candidate, Vulkan->Surface, &PresentModeCount, nullptr) != VK_SUCCESS ||
            FormatCount == 0u || PresentModeCount == 0u)
        {
            continue;
        }

        VkSurfaceCapabilitiesKHR SurfaceCapabilities{};
        if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(Candidate, Vulkan->Surface, &SurfaceCapabilities) != VK_SUCCESS)
            continue;

        constexpr VkImageUsageFlags RequiredSurfaceUsage =
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        if ((SurfaceCapabilities.supportedUsageFlags & RequiredSurfaceUsage) != RequiredSurfaceUsage)
            continue;

        VkFormatProperties StorageFormatProperties{};
        vkGetPhysicalDeviceFormatProperties(Candidate, VK_FORMAT_R8G8B8A8_UNORM, &StorageFormatProperties);
        constexpr VkFormatFeatureFlags RequiredStorageFeatures =
            VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT | VK_FORMAT_FEATURE_BLIT_SRC_BIT;
        if ((StorageFormatProperties.optimalTilingFeatures & RequiredStorageFeatures) != RequiredStorageFeatures)
            continue;

        uint32_t FamilyCount = 0u;
        vkGetPhysicalDeviceQueueFamilyProperties(Candidate, &FamilyCount, nullptr);
        std::vector<VkQueueFamilyProperties> Families(FamilyCount);
        vkGetPhysicalDeviceQueueFamilyProperties(Candidate, &FamilyCount, Families.data());

        uint32_t UnifiedFamily = std::numeric_limits<uint32_t>::max();
        for (uint32_t Index = 0u; Index < FamilyCount; ++Index)
        {
            VkBool32 PresentCapable = VK_FALSE;
            Result = vkGetPhysicalDeviceSurfaceSupportKHR(
                Candidate, Index, Vulkan->Surface, &PresentCapable);
            const VkQueueFlags RequiredQueueFlags = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
            if (Result == VK_SUCCESS && PresentCapable == VK_TRUE &&
                (Families[Index].queueFlags & RequiredQueueFlags) == RequiredQueueFlags)
            {
                UnifiedFamily = Index;
                break;
            }
        }
        if (UnifiedFamily == std::numeric_limits<uint32_t>::max()) continue;

        uint32_t Score = 1u;
        if (Properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU)   Score += 1000u;
        if (Properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) Score += 500u;
        Score += Properties.limits.maxImageDimension2D / 1024u;

        if (!SelectedDevice || Score > SelectedScore)
        {
            SelectedDevice = Candidate;
            SelectedFamily = UnifiedFamily;
            SelectedScore = Score;
            SelectedProperties = Properties;
        }
    }

    if (!SelectedDevice)
    {
        return ReportFailure(
            "No compatible Vulkan 1.2 device supports graphics, compute, presentation, and transfer-to-swapchain on one queue.");
    }

    Vulkan->PhysicalDevice = SelectedDevice;
    Vulkan->GraphicsFamily = SelectedFamily;
    Vulkan->ComputeFamily = SelectedFamily;
    vkGetPhysicalDeviceMemoryProperties(Vulkan->PhysicalDevice, &Vulkan->MemoryProperties);

    std::cout << "[SwapchainExchange] GPU: " << SelectedProperties.deviceName
              << " (Vulkan " << VK_VERSION_MAJOR(SelectedProperties.apiVersion) << '.'
              << VK_VERSION_MINOR(SelectedProperties.apiVersion) << '.'
              << VK_VERSION_PATCH(SelectedProperties.apiVersion) << ")\n" << std::flush;
    return true;
}

bool SwapchainExchange::BringLogicalDevice() noexcept
{
    const float Priority = 1.0f;

    VkDeviceQueueCreateInfo QueueInfo{};
    QueueInfo.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    QueueInfo.queueFamilyIndex = Vulkan->GraphicsFamily;
    QueueInfo.queueCount       = 1u;
    QueueInfo.pQueuePriorities = &Priority;

    const char* DeviceExtensions[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };

    // OutputImage declares rgba8 explicitly, so no optional storage-image feature is required.
    VkPhysicalDeviceFeatures DeviceFeatures{};

    VkDeviceCreateInfo DeviceInfo{};
    DeviceInfo.sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    DeviceInfo.queueCreateInfoCount    = 1u;
    DeviceInfo.pQueueCreateInfos       = &QueueInfo;
    DeviceInfo.enabledExtensionCount   = 1u;
    DeviceInfo.ppEnabledExtensionNames = DeviceExtensions;
    DeviceInfo.pEnabledFeatures        = &DeviceFeatures;

    const VkResult Result = vkCreateDevice(
        Vulkan->PhysicalDevice, &DeviceInfo, nullptr, &Vulkan->Device);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateDevice", Result));

    vkGetDeviceQueue(Vulkan->Device, Vulkan->GraphicsFamily, 0u, &Vulkan->GraphicsQueue);
    Vulkan->ComputeQueue = Vulkan->GraphicsQueue;
    if (!Vulkan->GraphicsQueue)
        return ReportFailure("vkGetDeviceQueue returned a null graphics/compute/presentation queue.");
    return true;
}

bool SwapchainExchange::BringSwapchain() noexcept
{
    VkSurfaceCapabilitiesKHR SurfaceCapabilities{};
    VkResult Result = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
        Vulkan->PhysicalDevice, Vulkan->Surface, &SurfaceCapabilities);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkGetPhysicalDeviceSurfaceCapabilitiesKHR", Result));

    constexpr VkImageUsageFlags RequiredUsage =
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if ((SurfaceCapabilities.supportedUsageFlags & RequiredUsage) != RequiredUsage)
    {
        return ReportFailure(
            "The selected window surface cannot receive the compute result (color-attachment and transfer-destination usage are required).");
    }

    uint32_t FormatCount = 0u;
    Result = vkGetPhysicalDeviceSurfaceFormatsKHR(
        Vulkan->PhysicalDevice, Vulkan->Surface, &FormatCount, nullptr);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkGetPhysicalDeviceSurfaceFormatsKHR", Result));
    if (FormatCount == 0u)
        return ReportFailure("The Vulkan window surface exposes no usable image formats.");

    std::vector<VkSurfaceFormatKHR> SurfaceFormats(FormatCount);
    Result = vkGetPhysicalDeviceSurfaceFormatsKHR(
        Vulkan->PhysicalDevice, Vulkan->Surface, &FormatCount, SurfaceFormats.data());
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkGetPhysicalDeviceSurfaceFormatsKHR", Result));

    VkSurfaceFormatKHR ChosenFormat = SurfaceFormats.front();
    if (SurfaceFormats.size() == 1u && ChosenFormat.format == VK_FORMAT_UNDEFINED)
    {
        ChosenFormat.format = VK_FORMAT_B8G8R8A8_UNORM;
        ChosenFormat.colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    }
    for (const VkSurfaceFormatKHR& Candidate : SurfaceFormats)
    {
        if (Candidate.format == VK_FORMAT_B8G8R8A8_UNORM &&
            Candidate.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            ChosenFormat = Candidate;
            break;
        }
    }

    VkFormatProperties DestinationFormatProperties{};
    vkGetPhysicalDeviceFormatProperties(
        Vulkan->PhysicalDevice, ChosenFormat.format, &DestinationFormatProperties);
    if ((DestinationFormatProperties.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_DST_BIT) == 0u)
        return ReportFailure("The selected swapchain format cannot be used as a Vulkan blit destination.");

    Vulkan->SwapchainFormat = ChosenFormat.format;

    if (SurfaceCapabilities.currentExtent.width != std::numeric_limits<uint32_t>::max())
    {
        Vulkan->SwapchainExtent = SurfaceCapabilities.currentExtent;
    }
    else
    {
        int FramebufferW = 0;
        int FramebufferH = 0;
        glfwGetFramebufferSize(GlfwWindow, &FramebufferW, &FramebufferH);
        if (FramebufferW <= 0 || FramebufferH <= 0)
            return ReportFailure("The GLFW window has a zero-sized framebuffer during swapchain creation.");

        Vulkan->SwapchainExtent.width = std::clamp(
            static_cast<uint32_t>(FramebufferW),
            SurfaceCapabilities.minImageExtent.width,
            SurfaceCapabilities.maxImageExtent.width);
        Vulkan->SwapchainExtent.height = std::clamp(
            static_cast<uint32_t>(FramebufferH),
            SurfaceCapabilities.minImageExtent.height,
            SurfaceCapabilities.maxImageExtent.height);
    }

    if (Vulkan->SwapchainExtent.width == 0u || Vulkan->SwapchainExtent.height == 0u)
        return ReportFailure("The Vulkan surface selected a zero-sized swapchain extent.");

    Configuration.Width  = Vulkan->SwapchainExtent.width;
    Configuration.Height = Vulkan->SwapchainExtent.height;

    uint32_t ImageCount = std::max(2u, SurfaceCapabilities.minImageCount + 1u);
    if (SurfaceCapabilities.maxImageCount > 0u)
        ImageCount = std::min(ImageCount, SurfaceCapabilities.maxImageCount);
    if (ImageCount < 2u)
        return ReportFailure("The Vulkan surface cannot provide the two presentation images required by ImGui.");

    VkCompositeAlphaFlagBitsKHR CompositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    constexpr std::array<VkCompositeAlphaFlagBitsKHR, 4u> CompositeCandidates = {{
        VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR
    }};
    for (VkCompositeAlphaFlagBitsKHR Candidate : CompositeCandidates)
    {
        if ((SurfaceCapabilities.supportedCompositeAlpha & Candidate) != 0u)
        {
            CompositeAlpha = Candidate;
            break;
        }
    }

    VkSwapchainCreateInfoKHR SwapchainInfo{};
    SwapchainInfo.sType            = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    SwapchainInfo.surface          = Vulkan->Surface;
    SwapchainInfo.minImageCount    = ImageCount;
    SwapchainInfo.imageFormat      = ChosenFormat.format;
    SwapchainInfo.imageColorSpace  = ChosenFormat.colorSpace;
    SwapchainInfo.imageExtent      = Vulkan->SwapchainExtent;
    SwapchainInfo.imageArrayLayers = 1u;
    // The compute shader writes to a separate storage image. Swapchain images are only blit destinations and ImGui attachments.
    SwapchainInfo.imageUsage       = RequiredUsage;
    SwapchainInfo.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    SwapchainInfo.preTransform     = SurfaceCapabilities.currentTransform;
    SwapchainInfo.compositeAlpha   = CompositeAlpha;
    SwapchainInfo.presentMode      = VK_PRESENT_MODE_FIFO_KHR;
    SwapchainInfo.clipped          = VK_TRUE;

    Result = vkCreateSwapchainKHR(Vulkan->Device, &SwapchainInfo, nullptr, &Vulkan->Swapchain);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateSwapchainKHR", Result));

    uint32_t ActualImageCount = 0u;
    Result = vkGetSwapchainImagesKHR(
        Vulkan->Device, Vulkan->Swapchain, &ActualImageCount, nullptr);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkGetSwapchainImagesKHR", Result));
    if (ActualImageCount == 0u)
        return ReportFailure("vkGetSwapchainImagesKHR returned no presentation images.");

    Vulkan->SwapchainImages.resize(ActualImageCount);
    Result = vkGetSwapchainImagesKHR(
        Vulkan->Device, Vulkan->Swapchain, &ActualImageCount, Vulkan->SwapchainImages.data());
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkGetSwapchainImagesKHR", Result));

    Vulkan->SwapchainImageViews.assign(ActualImageCount, VK_NULL_HANDLE);
    for (uint32_t Index = 0u; Index < ActualImageCount; ++Index)
    {
        VkImageViewCreateInfo ImageViewInfo{};
        ImageViewInfo.sType                           = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        ImageViewInfo.image                           = Vulkan->SwapchainImages[Index];
        ImageViewInfo.viewType                        = VK_IMAGE_VIEW_TYPE_2D;
        ImageViewInfo.format                          = Vulkan->SwapchainFormat;
        ImageViewInfo.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
        ImageViewInfo.subresourceRange.baseMipLevel   = 0u;
        ImageViewInfo.subresourceRange.levelCount     = 1u;
        ImageViewInfo.subresourceRange.baseArrayLayer = 0u;
        ImageViewInfo.subresourceRange.layerCount     = 1u;

        Result = vkCreateImageView(
            Vulkan->Device, &ImageViewInfo, nullptr, &Vulkan->SwapchainImageViews[Index]);
        if (Result != VK_SUCCESS)
            return ReportFailure(VulkanFailure("vkCreateImageView (swapchain)", Result));
    }

    Vulkan->ImageOrdinalFences.assign(ActualImageCount, VK_NULL_HANDLE);
    return true;
}

bool SwapchainExchange::BringStorageImage() noexcept
{
    VkImageCreateInfo ImageInfo{};
    ImageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    ImageInfo.imageType     = VK_IMAGE_TYPE_2D;
    ImageInfo.format        = VK_FORMAT_R8G8B8A8_UNORM;
    ImageInfo.extent        = { Configuration.Width, Configuration.Height, 1u };
    ImageInfo.mipLevels     = 1u;
    ImageInfo.arrayLayers   = 1u;
    ImageInfo.samples       = VK_SAMPLE_COUNT_1_BIT;
    ImageInfo.tiling        = VK_IMAGE_TILING_OPTIMAL;
    ImageInfo.usage         = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    ImageInfo.sharingMode   = VK_SHARING_MODE_EXCLUSIVE;
    ImageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    VkResult Result = vkCreateImage(
        Vulkan->Device, &ImageInfo, nullptr, &Vulkan->StorageImage);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateImage (compute output)", Result));

    VkMemoryRequirements Requirements{};
    vkGetImageMemoryRequirements(Vulkan->Device, Vulkan->StorageImage, &Requirements);

    const uint32_t MemoryTypeIndex = ResolveMemoryType(
        Requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (MemoryTypeIndex == std::numeric_limits<uint32_t>::max())
        return ReportFailure("No device-local Vulkan memory type can hold the compute output image.");

    VkMemoryAllocateInfo AllocateInfo{};
    AllocateInfo.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    AllocateInfo.allocationSize  = Requirements.size;
    AllocateInfo.memoryTypeIndex = MemoryTypeIndex;
    Result = vkAllocateMemory(
        Vulkan->Device, &AllocateInfo, nullptr, &Vulkan->StorageMemory);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkAllocateMemory (compute output)", Result));

    Result = vkBindImageMemory(
        Vulkan->Device, Vulkan->StorageImage, Vulkan->StorageMemory, 0u);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkBindImageMemory (compute output)", Result));

    VkImageViewCreateInfo ViewInfo{};
    ViewInfo.sType                           = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    ViewInfo.image                           = Vulkan->StorageImage;
    ViewInfo.viewType                        = VK_IMAGE_VIEW_TYPE_2D;
    ViewInfo.format                          = VK_FORMAT_R8G8B8A8_UNORM;
    ViewInfo.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
    ViewInfo.subresourceRange.levelCount     = 1u;
    ViewInfo.subresourceRange.layerCount     = 1u;
    Result = vkCreateImageView(
        Vulkan->Device, &ViewInfo, nullptr, &Vulkan->StorageImageView);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateImageView (compute output)", Result));

    return true;
}

bool SwapchainExchange::BringCommandRecording() noexcept
{
    VkCommandPoolCreateInfo PoolInfo{};
    PoolInfo.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    PoolInfo.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    // These buffers contain compute, transfer, ImGui graphics, and presentation transitions.
    PoolInfo.queueFamilyIndex = Vulkan->GraphicsFamily;

    VkResult Result = vkCreateCommandPool(
        Vulkan->Device, &PoolInfo, nullptr, &Vulkan->ComputeCommandPool);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateCommandPool", Result));

    const uint32_t ImageCount = static_cast<uint32_t>(Vulkan->SwapchainImages.size());
    if (ImageCount == 0u)
        return ReportFailure("Cannot allocate command buffers because the swapchain has no images.");
    Vulkan->ComputeCommands.assign(ImageCount, VK_NULL_HANDLE);

    VkCommandBufferAllocateInfo AllocateInfo{};
    AllocateInfo.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    AllocateInfo.commandPool        = Vulkan->ComputeCommandPool;
    AllocateInfo.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    AllocateInfo.commandBufferCount = ImageCount;
    Result = vkAllocateCommandBuffers(
        Vulkan->Device, &AllocateInfo, Vulkan->ComputeCommands.data());
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkAllocateCommandBuffers", Result));

    return true;
}

bool SwapchainExchange::BringComputePipeline() noexcept
{
    // ① Descriptor set layout — binding 0: storage image, 1: triangle SSBO, 2: material SSBO
    std::array<VkDescriptorSetLayoutBinding, 3u> LayoutBindings{};
    LayoutBindings[0].binding         = 0u;
    LayoutBindings[0].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
    LayoutBindings[0].descriptorCount = 1u;
    LayoutBindings[0].stageFlags      = VK_SHADER_STAGE_COMPUTE_BIT;
    LayoutBindings[1].binding         = 1u;
    LayoutBindings[1].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    LayoutBindings[1].descriptorCount = 1u;
    LayoutBindings[1].stageFlags      = VK_SHADER_STAGE_COMPUTE_BIT;
    LayoutBindings[2].binding         = 2u;
    LayoutBindings[2].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    LayoutBindings[2].descriptorCount = 1u;
    LayoutBindings[2].stageFlags      = VK_SHADER_STAGE_COMPUTE_BIT;

    VkDescriptorSetLayoutCreateInfo LayoutInfo{};
    LayoutInfo.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    LayoutInfo.bindingCount = static_cast<uint32_t>(LayoutBindings.size());
    LayoutInfo.pBindings    = LayoutBindings.data();
    VkResult Result = vkCreateDescriptorSetLayout(
        Vulkan->Device, &LayoutInfo, nullptr, &Vulkan->ComputeDescriptorLayout);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateDescriptorSetLayout", Result));

    // ② Push constant range — matches DispatchConfiguration exactly.
    static_assert(sizeof(DispatchConfiguration) <= 128u,
                  "Project-Zero push constants exceed Vulkan's guaranteed minimum capacity");
    VkPushConstantRange PushRange{};
    PushRange.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    PushRange.offset     = 0u;
    PushRange.size       = static_cast<uint32_t>(sizeof(DispatchConfiguration));

    VkPipelineLayoutCreateInfo PipelineLayoutInfo{};
    PipelineLayoutInfo.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    PipelineLayoutInfo.setLayoutCount         = 1u;
    PipelineLayoutInfo.pSetLayouts            = &Vulkan->ComputeDescriptorLayout;
    PipelineLayoutInfo.pushConstantRangeCount = 1u;
    PipelineLayoutInfo.pPushConstantRanges    = &PushRange;
    Result = vkCreatePipelineLayout(
        Vulkan->Device, &PipelineLayoutInfo, nullptr, &Vulkan->ComputePipelineLayout);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreatePipelineLayout", Result));

    // ③ Load the self-contained shader copied beside Project-Zero.exe by the build.
    const std::string ShaderPath = Configuration.ShaderBinaryPath.empty()
        ? "Engine/Shaders/ReSTIRViewport.spv"
        : Configuration.ShaderBinaryPath;
    std::string ShaderError;
    const std::vector<uint32_t> Spirv = LoadSpirv(ShaderPath, ShaderError);
    if (Spirv.empty())
        return ReportFailure(std::move(ShaderError));

    VkShaderModuleCreateInfo ShaderModuleInfo{};
    ShaderModuleInfo.sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    ShaderModuleInfo.codeSize = Spirv.size() * sizeof(uint32_t);
    ShaderModuleInfo.pCode    = Spirv.data();
    VkShaderModule ShaderModule = VK_NULL_HANDLE;
    Result = vkCreateShaderModule(
        Vulkan->Device, &ShaderModuleInfo, nullptr, &ShaderModule);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateShaderModule", Result));

    VkComputePipelineCreateInfo ComputeInfo{};
    ComputeInfo.sType        = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    ComputeInfo.stage.sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    ComputeInfo.stage.stage  = VK_SHADER_STAGE_COMPUTE_BIT;
    ComputeInfo.stage.module = ShaderModule;
    ComputeInfo.stage.pName  = "main";
    ComputeInfo.layout       = Vulkan->ComputePipelineLayout;

    Result = vkCreateComputePipelines(
        Vulkan->Device, VK_NULL_HANDLE, 1u, &ComputeInfo, nullptr, &Vulkan->ComputePipeline);
    vkDestroyShaderModule(Vulkan->Device, ShaderModule, nullptr);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateComputePipelines", Result));

    return true;
}

bool SwapchainExchange::BringDescriptorSet() noexcept
{
    std::array<VkDescriptorPoolSize, 2u> PoolSizes{};
    PoolSizes[0].type            = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
    PoolSizes[0].descriptorCount = 1u;
    PoolSizes[1].type            = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    PoolSizes[1].descriptorCount = 2u;

    VkDescriptorPoolCreateInfo PoolInfo{};
    PoolInfo.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    PoolInfo.maxSets       = 1u;
    PoolInfo.poolSizeCount = static_cast<uint32_t>(PoolSizes.size());
    PoolInfo.pPoolSizes    = PoolSizes.data();
    VkResult Result = vkCreateDescriptorPool(
        Vulkan->Device, &PoolInfo, nullptr, &Vulkan->ComputeDescriptorPool);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateDescriptorPool (compute)", Result));

    VkDescriptorSetAllocateInfo AllocateInfo{};
    AllocateInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    AllocateInfo.descriptorPool     = Vulkan->ComputeDescriptorPool;
    AllocateInfo.descriptorSetCount = 1u;
    AllocateInfo.pSetLayouts        = &Vulkan->ComputeDescriptorLayout;
    Result = vkAllocateDescriptorSets(
        Vulkan->Device, &AllocateInfo, &Vulkan->ComputeDescriptorSet);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkAllocateDescriptorSets (compute)", Result));

    // Scene buffers are uploaded after Bring(); writing null buffer descriptors here is invalid Vulkan.
    SceneDescriptorsReady = false;
    return true;
}

bool SwapchainExchange::WriteDescriptorSet() noexcept
{
    if (!Vulkan->ComputeDescriptorSet || !Vulkan->StorageImageView ||
        !Vulkan->TriangleBuffer || !Vulkan->MaterialBuffer)
    {
        SceneDescriptorsReady = false;
        return ReportFailure("Cannot write the compute descriptor set before both scene buffers are uploaded.");
    }

    VkDescriptorImageInfo ImageInfo{};
    ImageInfo.imageView   = Vulkan->StorageImageView;
    ImageInfo.imageLayout = VK_IMAGE_LAYOUT_GENERAL;

    VkDescriptorBufferInfo TriangleBufferInfo{};
    TriangleBufferInfo.buffer = Vulkan->TriangleBuffer;
    TriangleBufferInfo.offset = 0u;
    TriangleBufferInfo.range  = VK_WHOLE_SIZE;

    VkDescriptorBufferInfo MaterialBufferInfo{};
    MaterialBufferInfo.buffer = Vulkan->MaterialBuffer;
    MaterialBufferInfo.offset = 0u;
    MaterialBufferInfo.range  = VK_WHOLE_SIZE;

    std::array<VkWriteDescriptorSet, 3u> Writes{};
    Writes[0].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    Writes[0].dstSet          = Vulkan->ComputeDescriptorSet;
    Writes[0].dstBinding      = 0u;
    Writes[0].descriptorCount = 1u;
    Writes[0].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
    Writes[0].pImageInfo      = &ImageInfo;

    Writes[1].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    Writes[1].dstSet          = Vulkan->ComputeDescriptorSet;
    Writes[1].dstBinding      = 1u;
    Writes[1].descriptorCount = 1u;
    Writes[1].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    Writes[1].pBufferInfo     = &TriangleBufferInfo;

    Writes[2].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    Writes[2].dstSet          = Vulkan->ComputeDescriptorSet;
    Writes[2].dstBinding      = 2u;
    Writes[2].descriptorCount = 1u;
    Writes[2].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    Writes[2].pBufferInfo     = &MaterialBufferInfo;

    vkUpdateDescriptorSets(
        Vulkan->Device, static_cast<uint32_t>(Writes.size()), Writes.data(), 0u, nullptr);
    SceneDescriptorsReady = true;
    return true;
}

bool SwapchainExchange::BringCycleSlots() noexcept
{
    VkSemaphoreCreateInfo SemaphoreInfo{};
    SemaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    VkFenceCreateInfo FenceInfo{};
    FenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    FenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT;

    for (uint32_t Slot = 0u; Slot < kCycleSlotCount; ++Slot)
    {
        VkResult Result = vkCreateSemaphore(
            Vulkan->Device, &SemaphoreInfo, nullptr, &Vulkan->AcquireSemaphores[Slot]);
        if (Result != VK_SUCCESS)
            return ReportFailure(VulkanFailure("vkCreateSemaphore (acquire)", Result));

        Result = vkCreateSemaphore(
            Vulkan->Device, &SemaphoreInfo, nullptr, &Vulkan->ReleaseSemaphores[Slot]);
        if (Result != VK_SUCCESS)
            return ReportFailure(VulkanFailure("vkCreateSemaphore (release)", Result));

        Result = vkCreateFence(
            Vulkan->Device, &FenceInfo, nullptr, &Vulkan->CycleFences[Slot]);
        if (Result != VK_SUCCESS)
            return ReportFailure(VulkanFailure("vkCreateFence", Result));
    }
    return true;
}

bool SwapchainExchange::BringImGui() noexcept
{
    // ① ImGui 1.92.9+ uses separate sampled-image and sampler descriptors.
    const std::array<VkDescriptorPoolSize, 2u> ImGuiPoolSizes = {{
        { VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 64u },
        { VK_DESCRIPTOR_TYPE_SAMPLER,        8u }
    }};
    VkDescriptorPoolCreateInfo ImGuiPoolInfo{};
    ImGuiPoolInfo.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    ImGuiPoolInfo.flags         = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    ImGuiPoolInfo.maxSets       = 72u;
    ImGuiPoolInfo.poolSizeCount = static_cast<uint32_t>(ImGuiPoolSizes.size());
    ImGuiPoolInfo.pPoolSizes    = ImGuiPoolSizes.data();
    VkResult Result = vkCreateDescriptorPool(
        Vulkan->Device, &ImGuiPoolInfo, nullptr, &Vulkan->ImGuiDescriptorPool);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateDescriptorPool (ImGui)", Result));

    // ② Render pass — loads compute output, ImGui renders on top, transitions to PRESENT.
    VkAttachmentDescription ColourAttachment{};
    ColourAttachment.format         = Vulkan->SwapchainFormat;
    ColourAttachment.samples        = VK_SAMPLE_COUNT_1_BIT;
    ColourAttachment.loadOp         = VK_ATTACHMENT_LOAD_OP_LOAD;
    ColourAttachment.storeOp        = VK_ATTACHMENT_STORE_OP_STORE;
    ColourAttachment.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    ColourAttachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    ColourAttachment.initialLayout  = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    ColourAttachment.finalLayout    = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentReference ColourReference{ 0u, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription Subpass{};
    Subpass.pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS;
    Subpass.colorAttachmentCount = 1u;
    Subpass.pColorAttachments    = &ColourReference;

    VkSubpassDependency Dependency{};
    Dependency.srcSubpass    = VK_SUBPASS_EXTERNAL;
    Dependency.dstSubpass    = 0u;
    Dependency.srcStageMask  = VK_PIPELINE_STAGE_TRANSFER_BIT;
    Dependency.dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    Dependency.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    Dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
                               VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    VkRenderPassCreateInfo RenderPassInfo{};
    RenderPassInfo.sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    RenderPassInfo.attachmentCount = 1u;
    RenderPassInfo.pAttachments    = &ColourAttachment;
    RenderPassInfo.subpassCount    = 1u;
    RenderPassInfo.pSubpasses      = &Subpass;
    RenderPassInfo.dependencyCount = 1u;
    RenderPassInfo.pDependencies   = &Dependency;
    Result = vkCreateRenderPass(
        Vulkan->Device, &RenderPassInfo, nullptr, &Vulkan->ImGuiRenderPass);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkCreateRenderPass (ImGui)", Result));

    // ③ Framebuffers.
    const uint32_t ImageCount = static_cast<uint32_t>(Vulkan->SwapchainImages.size());
    if (ImageCount < 2u)
        return ReportFailure("ImGui requires at least two swapchain images.");

    Vulkan->ImGuiFramebuffers.assign(ImageCount, VK_NULL_HANDLE);
    for (uint32_t Index = 0u; Index < ImageCount; ++Index)
    {
        VkFramebufferCreateInfo FramebufferInfo{};
        FramebufferInfo.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        FramebufferInfo.renderPass      = Vulkan->ImGuiRenderPass;
        FramebufferInfo.attachmentCount = 1u;
        FramebufferInfo.pAttachments    = &Vulkan->SwapchainImageViews[Index];
        FramebufferInfo.width           = Configuration.Width;
        FramebufferInfo.height          = Configuration.Height;
        FramebufferInfo.layers          = 1u;
        Result = vkCreateFramebuffer(
            Vulkan->Device, &FramebufferInfo, nullptr, &Vulkan->ImGuiFramebuffers[Index]);
        if (Result != VK_SUCCESS)
            return ReportFailure(VulkanFailure("vkCreateFramebuffer (ImGui)", Result));
    }

    // ④ ImGui context and backends.
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiContextInitialised = true;
#ifdef IMGUI_HAS_DOCK
    ImGui::GetIO().ConfigFlags |= ImGuiConfigFlags_DockingEnable;
#endif // IMGUI_HAS_DOCK
    ImGui::StyleColorsDark();

    if (!ImGui_ImplGlfw_InitForVulkan(GlfwWindow, true))
        return ReportFailure("ImGui_ImplGlfw_InitForVulkan failed.");
    ImGuiGlfwInitialised = true;

    ImGui_ImplVulkan_InitInfo ImGuiVulkanInfo{};
    ImGuiVulkanInfo.ApiVersion     = VK_API_VERSION_1_2;
    ImGuiVulkanInfo.Instance       = Vulkan->Instance;
    ImGuiVulkanInfo.PhysicalDevice = Vulkan->PhysicalDevice;
    ImGuiVulkanInfo.Device         = Vulkan->Device;
    ImGuiVulkanInfo.QueueFamily    = Vulkan->GraphicsFamily;
    ImGuiVulkanInfo.Queue          = Vulkan->GraphicsQueue;
    ImGuiVulkanInfo.DescriptorPool = Vulkan->ImGuiDescriptorPool;
    ImGuiVulkanInfo.PipelineInfoMain.RenderPass  = Vulkan->ImGuiRenderPass;
    ImGuiVulkanInfo.PipelineInfoMain.MSAASamples = VK_SAMPLE_COUNT_1_BIT;
    ImGuiVulkanInfo.MinImageCount  = 2u;
    ImGuiVulkanInfo.ImageCount     = ImageCount;
    ImGuiVulkanInfo.CheckVkResultFn = ImGuiVulkanResultCallback;
    if (!ImGui_ImplVulkan_Init(&ImGuiVulkanInfo))
        return ReportFailure("ImGui_ImplVulkan_Init failed.");
    ImGuiVulkanInitialised = true;

    // Font upload is owned by ImGui and occurs during its first NewFrame call.
    return true;
}

//============================================================================================================================================
//                                               SCENE UPLOAD
//============================================================================================================================================

bool SwapchainExchange::UploadTriangles(const std::vector<TriangleIndex>& Triangles) noexcept
{
    if (!Vulkan->Device)
        return ReportFailure("Cannot upload triangles before the Vulkan device is initialized.");
    if (Triangles.empty())
        return ReportFailure("The Project-Zero scene contains no triangles to upload.");

    const VkDeviceSize ByteCount = Triangles.size() * sizeof(TriangleIndex);
    constexpr VkMemoryPropertyFlags HostVisible =
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

    VkBuffer NewBuffer = VK_NULL_HANDLE;
    VkDeviceMemory NewMemory = VK_NULL_HANDLE;
    VkResult Result = AllocateBuffer(
        Vulkan->Device, Vulkan->MemoryProperties, ByteCount,
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, HostVisible, NewBuffer, NewMemory);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("triangle buffer allocation", Result));

    void* Mapped = nullptr;
    Result = vkMapMemory(Vulkan->Device, NewMemory, 0u, ByteCount, 0u, &Mapped);
    if (Result != VK_SUCCESS || !Mapped)
    {
        vkDestroyBuffer(Vulkan->Device, NewBuffer, nullptr);
        vkFreeMemory(Vulkan->Device, NewMemory, nullptr);
        return ReportFailure(VulkanFailure("vkMapMemory (triangles)", Result));
    }

    std::memcpy(Mapped, Triangles.data(), static_cast<size_t>(ByteCount));
    vkUnmapMemory(Vulkan->Device, NewMemory);

    (void)vkDeviceWaitIdle(Vulkan->Device);
    if (Vulkan->TriangleBuffer) vkDestroyBuffer(Vulkan->Device, Vulkan->TriangleBuffer, nullptr);
    if (Vulkan->TriangleMemory) vkFreeMemory(Vulkan->Device, Vulkan->TriangleMemory, nullptr);
    Vulkan->TriangleBuffer = NewBuffer;
    Vulkan->TriangleMemory = NewMemory;
    Vulkan->TriangleCount = static_cast<uint32_t>(Triangles.size());
    SceneDescriptorsReady = false;

    return !Vulkan->MaterialBuffer || WriteDescriptorSet();
}

bool SwapchainExchange::UploadRadiance(const std::vector<RadianceStructure>& Materials) noexcept
{
    if (!Vulkan->Device)
        return ReportFailure("Cannot upload materials before the Vulkan device is initialized.");
    if (Materials.empty())
        return ReportFailure("The Project-Zero scene contains no materials to upload.");

    const VkDeviceSize ByteCount = Materials.size() * sizeof(RadianceStructure);
    constexpr VkMemoryPropertyFlags HostVisible =
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

    VkBuffer NewBuffer = VK_NULL_HANDLE;
    VkDeviceMemory NewMemory = VK_NULL_HANDLE;
    VkResult Result = AllocateBuffer(
        Vulkan->Device, Vulkan->MemoryProperties, ByteCount,
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, HostVisible, NewBuffer, NewMemory);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("material buffer allocation", Result));

    void* Mapped = nullptr;
    Result = vkMapMemory(Vulkan->Device, NewMemory, 0u, ByteCount, 0u, &Mapped);
    if (Result != VK_SUCCESS || !Mapped)
    {
        vkDestroyBuffer(Vulkan->Device, NewBuffer, nullptr);
        vkFreeMemory(Vulkan->Device, NewMemory, nullptr);
        return ReportFailure(VulkanFailure("vkMapMemory (materials)", Result));
    }

    std::memcpy(Mapped, Materials.data(), static_cast<size_t>(ByteCount));
    vkUnmapMemory(Vulkan->Device, NewMemory);

    (void)vkDeviceWaitIdle(Vulkan->Device);
    if (Vulkan->MaterialBuffer) vkDestroyBuffer(Vulkan->Device, Vulkan->MaterialBuffer, nullptr);
    if (Vulkan->MaterialMemory) vkFreeMemory(Vulkan->Device, Vulkan->MaterialMemory, nullptr);
    Vulkan->MaterialBuffer = NewBuffer;
    Vulkan->MaterialMemory = NewMemory;
    Vulkan->MaterialCount = static_cast<uint32_t>(Materials.size());
    SceneDescriptorsReady = false;

    return !Vulkan->TriangleBuffer || WriteDescriptorSet();
}

//============================================================================================================================================
//                                           RECORD AND PRESENT
//============================================================================================================================================

bool SwapchainExchange::RecordAndPresent(const DispatchConfiguration& Dispatch) noexcept
{
    if (!SceneDescriptorsReady)
        return ReportFailure("Cannot render before valid triangle and material descriptors are installed.");

    if (ResizePending)
    {
        ResizePending = false;
        return RebuildSwapchain();
    }

    const uint32_t ActiveSlot = Vulkan->ActiveSlot;
    VkResult Result = vkWaitForFences(
        Vulkan->Device, 1u, &Vulkan->CycleFences[ActiveSlot], VK_TRUE, UINT64_MAX);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkWaitForFences", Result));

    uint32_t ImageOrdinal = 0u;
    Result = vkAcquireNextImageKHR(
        Vulkan->Device, Vulkan->Swapchain, UINT64_MAX,
        Vulkan->AcquireSemaphores[ActiveSlot], VK_NULL_HANDLE, &ImageOrdinal);

    if (Result == VK_ERROR_OUT_OF_DATE_KHR)
        return RebuildSwapchain();
    if (Result != VK_SUCCESS && Result != VK_SUBOPTIMAL_KHR)
        return ReportFailure(VulkanFailure("vkAcquireNextImageKHR", Result));
    const bool AcquireWasSuboptimal = Result == VK_SUBOPTIMAL_KHR;

    if (ImageOrdinal >= Vulkan->ImageOrdinalFences.size() ||
        ImageOrdinal >= Vulkan->ComputeCommands.size() ||
        ImageOrdinal >= Vulkan->ImGuiFramebuffers.size())
    {
        return ReportFailure("The acquired swapchain image index exceeds the allocated per-image resources.");
    }

    if (Vulkan->ImageOrdinalFences[ImageOrdinal] != VK_NULL_HANDLE)
    {
        Result = vkWaitForFences(
            Vulkan->Device, 1u, &Vulkan->ImageOrdinalFences[ImageOrdinal], VK_TRUE, UINT64_MAX);
        if (Result != VK_SUCCESS)
            return ReportFailure(VulkanFailure("vkWaitForFences (swapchain image)", Result));
    }
    Vulkan->ImageOrdinalFences[ImageOrdinal] = Vulkan->CycleFences[ActiveSlot];

    if (!RecordComputeCommands(ImageOrdinal, Dispatch))
        return false;

    Result = vkResetFences(Vulkan->Device, 1u, &Vulkan->CycleFences[ActiveSlot]);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkResetFences", Result));

    // Transfer is the first stage that accesses the acquired presentation image.
    const VkPipelineStageFlags WaitStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo Submit{};
    Submit.sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    Submit.waitSemaphoreCount   = 1u;
    Submit.pWaitSemaphores      = &Vulkan->AcquireSemaphores[ActiveSlot];
    Submit.pWaitDstStageMask    = &WaitStage;
    Submit.commandBufferCount   = 1u;
    Submit.pCommandBuffers      = &Vulkan->ComputeCommands[ImageOrdinal];
    Submit.signalSemaphoreCount = 1u;
    Submit.pSignalSemaphores    = &Vulkan->ReleaseSemaphores[ActiveSlot];
    Result = vkQueueSubmit(
        Vulkan->GraphicsQueue, 1u, &Submit, Vulkan->CycleFences[ActiveSlot]);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkQueueSubmit", Result));
    Vulkan->StorageImageSubmitted = true;

    VkPresentInfoKHR PresentInfo{};
    PresentInfo.sType              = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    PresentInfo.waitSemaphoreCount = 1u;
    PresentInfo.pWaitSemaphores    = &Vulkan->ReleaseSemaphores[ActiveSlot];
    PresentInfo.swapchainCount     = 1u;
    PresentInfo.pSwapchains        = &Vulkan->Swapchain;
    PresentInfo.pImageIndices      = &ImageOrdinal;

    Result = vkQueuePresentKHR(Vulkan->GraphicsQueue, &PresentInfo);
    Vulkan->ActiveSlot = (ActiveSlot + 1u) % kCycleSlotCount;

    if (Result == VK_ERROR_OUT_OF_DATE_KHR || Result == VK_SUBOPTIMAL_KHR ||
        AcquireWasSuboptimal || ResizePending)
    {
        ResizePending = false;
        return RebuildSwapchain();
    }
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkQueuePresentKHR", Result));

    return true;
}

//------------------------------------------------------------------------------------------------------------------------
//                                           RECORD COMPUTE COMMANDS
//------------------------------------------------------------------------------------------------------------------------

bool SwapchainExchange::RecordComputeCommands(uint32_t ImageOrdinal, const DispatchConfiguration& Dispatch) noexcept
{
    VkCommandBuffer Command = Vulkan->ComputeCommands[ImageOrdinal];

    VkResult Result = vkResetCommandBuffer(Command, 0u);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkResetCommandBuffer", Result));

    VkCommandBufferBeginInfo BeginInfo{};
    BeginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    BeginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    Result = vkBeginCommandBuffer(Command, &BeginInfo);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkBeginCommandBuffer", Result));

    // ① Storage image → GENERAL for compute write. After the first submitted
    // frame, wait for the previous frame's blit read before overwriting the one
    // shared compute image (queue submissions may otherwise overlap stages).
    {
        const bool ReusingStorageImage = Vulkan->StorageImageSubmitted;
        VkImageMemoryBarrier Barrier{};
        Barrier.sType                           = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        Barrier.oldLayout                       = ReusingStorageImage
                                                ? VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
                                                : VK_IMAGE_LAYOUT_UNDEFINED;
        Barrier.newLayout                       = VK_IMAGE_LAYOUT_GENERAL;
        Barrier.srcQueueFamilyIndex             = VK_QUEUE_FAMILY_IGNORED;
        Barrier.dstQueueFamilyIndex             = VK_QUEUE_FAMILY_IGNORED;
        Barrier.image                           = Vulkan->StorageImage;
        Barrier.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
        Barrier.subresourceRange.levelCount     = 1u;
        Barrier.subresourceRange.layerCount     = 1u;
        Barrier.srcAccessMask                   = ReusingStorageImage
                                                ? static_cast<VkAccessFlags>(VK_ACCESS_TRANSFER_READ_BIT)
                                                : VkAccessFlags{ 0u };
        Barrier.dstAccessMask                   = VK_ACCESS_SHADER_WRITE_BIT;
        vkCmdPipelineBarrier(Command,
            ReusingStorageImage ? VK_PIPELINE_STAGE_TRANSFER_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0u, 0u, nullptr, 0u, nullptr, 1u, &Barrier);
    }

    // ② Dispatch ReSTIR compute
    vkCmdBindPipeline(Command, VK_PIPELINE_BIND_POINT_COMPUTE, Vulkan->ComputePipeline);
    vkCmdBindDescriptorSets(Command, VK_PIPELINE_BIND_POINT_COMPUTE,
        Vulkan->ComputePipelineLayout, 0u, 1u, &Vulkan->ComputeDescriptorSet, 0u, nullptr);
    vkCmdPushConstants(Command, Vulkan->ComputePipelineLayout,
        VK_SHADER_STAGE_COMPUTE_BIT, 0u, sizeof(DispatchConfiguration), &Dispatch);

    const uint32_t GroupX = (Configuration.Width  + kLocalGroupSizeX - 1u) / kLocalGroupSizeX;
    const uint32_t GroupY = (Configuration.Height + kLocalGroupSizeY - 1u) / kLocalGroupSizeY;
    vkCmdDispatch(Command, GroupX, GroupY, 1u);

    // ③ Storage image → TRANSFER_SRC for blit
    {
        VkImageMemoryBarrier Barrier{};
        Barrier.sType                           = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        Barrier.oldLayout                       = VK_IMAGE_LAYOUT_GENERAL;
        Barrier.newLayout                       = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        Barrier.srcQueueFamilyIndex             = VK_QUEUE_FAMILY_IGNORED;
        Barrier.dstQueueFamilyIndex             = VK_QUEUE_FAMILY_IGNORED;
        Barrier.image                           = Vulkan->StorageImage;
        Barrier.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
        Barrier.subresourceRange.levelCount     = 1u;
        Barrier.subresourceRange.layerCount     = 1u;
        Barrier.srcAccessMask                   = VK_ACCESS_SHADER_WRITE_BIT;
        Barrier.dstAccessMask                   = VK_ACCESS_TRANSFER_READ_BIT;
        vkCmdPipelineBarrier(Command,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0u, 0u, nullptr, 0u, nullptr, 1u, &Barrier);
    }

    // ④ Swapchain image → TRANSFER_DST
    {
        VkImageMemoryBarrier Barrier{};
        Barrier.sType                           = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        Barrier.oldLayout                       = VK_IMAGE_LAYOUT_UNDEFINED;
        Barrier.newLayout                       = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        Barrier.srcQueueFamilyIndex             = VK_QUEUE_FAMILY_IGNORED;
        Barrier.dstQueueFamilyIndex             = VK_QUEUE_FAMILY_IGNORED;
        Barrier.image                           = Vulkan->SwapchainImages[ImageOrdinal];
        Barrier.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
        Barrier.subresourceRange.levelCount     = 1u;
        Barrier.subresourceRange.layerCount     = 1u;
        Barrier.srcAccessMask                   = 0u;
        Barrier.dstAccessMask                   = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(Command,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0u, 0u, nullptr, 0u, nullptr, 1u, &Barrier);
    }

    // ⑤ Blit storage → swapchain
    VkImageBlit BlitRegion{};
    BlitRegion.srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0u, 0u, 1u };
    BlitRegion.srcOffsets[0]  = { 0, 0, 0 };
    BlitRegion.srcOffsets[1]  = { static_cast<int32_t>(Configuration.Width), static_cast<int32_t>(Configuration.Height), 1 };
    BlitRegion.dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0u, 0u, 1u };
    BlitRegion.dstOffsets[0]  = { 0, 0, 0 };
    BlitRegion.dstOffsets[1]  = { static_cast<int32_t>(Configuration.Width), static_cast<int32_t>(Configuration.Height), 1 };
    vkCmdBlitImage(Command,
        Vulkan->StorageImage,                    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        Vulkan->SwapchainImages[ImageOrdinal],   VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1u, &BlitRegion, VK_FILTER_NEAREST);

    // ⑥ Swapchain image → COLOR_ATTACHMENT_OPTIMAL for ImGui
    {
        VkImageMemoryBarrier Barrier{};
        Barrier.sType                           = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        Barrier.oldLayout                       = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        Barrier.newLayout                       = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        Barrier.srcQueueFamilyIndex             = VK_QUEUE_FAMILY_IGNORED;
        Barrier.dstQueueFamilyIndex             = VK_QUEUE_FAMILY_IGNORED;
        Barrier.image                           = Vulkan->SwapchainImages[ImageOrdinal];
        Barrier.subresourceRange.aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT;
        Barrier.subresourceRange.levelCount     = 1u;
        Barrier.subresourceRange.layerCount     = 1u;
        Barrier.srcAccessMask                   = VK_ACCESS_TRANSFER_WRITE_BIT;
        Barrier.dstAccessMask                   = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        vkCmdPipelineBarrier(Command,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0u, 0u, nullptr, 0u, nullptr, 1u, &Barrier);
    }

    // ⑦ ImGui render pass
    VkClearValue ClearValue{};
    ClearValue.color = {{ 0.0f, 0.0f, 0.0f, 0.0f }};

    VkRenderPassBeginInfo RenderPassBegin{};
    RenderPassBegin.sType             = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    RenderPassBegin.renderPass        = Vulkan->ImGuiRenderPass;
    RenderPassBegin.framebuffer       = Vulkan->ImGuiFramebuffers[ImageOrdinal];
    RenderPassBegin.renderArea.extent = Vulkan->SwapchainExtent;
    RenderPassBegin.clearValueCount   = 1u;
    RenderPassBegin.pClearValues      = &ClearValue;
    vkCmdBeginRenderPass(Command, &RenderPassBegin, VK_SUBPASS_CONTENTS_INLINE);
    ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), Command);
    vkCmdEndRenderPass(Command);

    Result = vkEndCommandBuffer(Command);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkEndCommandBuffer", Result));
    return true;
}

//============================================================================================================================================
//                                             SWAPCHAIN REBUILD (on resize)
//============================================================================================================================================

bool SwapchainExchange::RebuildSwapchain() noexcept
{
    int FramebufferW = 0;
    int FramebufferH = 0;
    glfwGetFramebufferSize(GlfwWindow, &FramebufferW, &FramebufferH);
    while (FramebufferW == 0 || FramebufferH == 0)
    {
        if (glfwWindowShouldClose(GlfwWindow)) return true;
        glfwWaitEvents();
        glfwGetFramebufferSize(GlfwWindow, &FramebufferW, &FramebufferH);
    }

    VkResult Result = vkDeviceWaitIdle(Vulkan->Device);
    if (Result != VK_SUCCESS)
        return ReportFailure(VulkanFailure("vkDeviceWaitIdle (swapchain rebuild)", Result));

    for (VkFramebuffer& Framebuffer : Vulkan->ImGuiFramebuffers)
        if (Framebuffer) vkDestroyFramebuffer(Vulkan->Device, Framebuffer, nullptr);
    Vulkan->ImGuiFramebuffers.clear();

    if (Vulkan->ComputeCommandPool)
    {
        vkDestroyCommandPool(Vulkan->Device, Vulkan->ComputeCommandPool, nullptr);
        Vulkan->ComputeCommandPool = VK_NULL_HANDLE;
        Vulkan->ComputeCommands.clear();
    }

    const VkFormat PreviousFormat = Vulkan->SwapchainFormat;
    RetireSwapchain();

    if (!BringSwapchain() || !BringStorageImage() || !BringCommandRecording())
        return false;
    if (Vulkan->SwapchainFormat != PreviousFormat)
        return ReportFailure("The surface format changed during resize; restart Project-Zero to rebuild the ImGui render pass safely.");
    if (!WriteDescriptorSet())
        return false;

    const uint32_t ImageCount = static_cast<uint32_t>(Vulkan->SwapchainImages.size());
    Vulkan->ImGuiFramebuffers.assign(ImageCount, VK_NULL_HANDLE);
    for (uint32_t Index = 0u; Index < ImageCount; ++Index)
    {
        VkFramebufferCreateInfo FramebufferInfo{};
        FramebufferInfo.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        FramebufferInfo.renderPass      = Vulkan->ImGuiRenderPass;
        FramebufferInfo.attachmentCount = 1u;
        FramebufferInfo.pAttachments    = &Vulkan->SwapchainImageViews[Index];
        FramebufferInfo.width           = Configuration.Width;
        FramebufferInfo.height          = Configuration.Height;
        FramebufferInfo.layers          = 1u;
        Result = vkCreateFramebuffer(
            Vulkan->Device, &FramebufferInfo, nullptr, &Vulkan->ImGuiFramebuffers[Index]);
        if (Result != VK_SUCCESS)
            return ReportFailure(VulkanFailure("vkCreateFramebuffer (swapchain rebuild)", Result));
    }

    if (ImGuiVulkanInitialised)
        ImGui_ImplVulkan_SetMinImageCount(2u);
    return true;
}

//============================================================================================================================================
//                                               POLL AND CLOSE
//============================================================================================================================================

bool SwapchainExchange::CloseRequested() const noexcept
{
    return GlfwWindow && glfwWindowShouldClose(GlfwWindow);
}

void SwapchainExchange::PollInput(InputExchange& TargetInput) noexcept
{
    ForwardInput = &TargetInput;
    TargetInput.AssignCursorDelta(0.0f, 0.0f);
    TargetInput.AssignMouseScroll(0.0f);
    glfwPollEvents();
    ForwardInput = nullptr;
}

//============================================================================================================================================
//                                               MEMORY TYPE RESOLUTION
//============================================================================================================================================

uint32_t SwapchainExchange::ResolveMemoryType(uint32_t TypeMask, uint32_t PropertyMask) const noexcept
{
    for (uint32_t Index = 0u; Index < Vulkan->MemoryProperties.memoryTypeCount; ++Index)
    {
        if ((TypeMask & (1u << Index)) &&
            (Vulkan->MemoryProperties.memoryTypes[Index].propertyFlags & PropertyMask) ==
             static_cast<VkMemoryPropertyFlags>(PropertyMask))
        {
            return Index;
        }
    }
    return std::numeric_limits<uint32_t>::max();
}

//============================================================================================================================================
//                                                 GLFW CALLBACKS
//============================================================================================================================================

void SwapchainExchange::OnKey(GLFWwindow* Window, int Key, int, int Action, int) noexcept
{
    auto* Self = static_cast<SwapchainExchange*>(glfwGetWindowUserPointer(Window));
    if (!Self || !Self->ForwardInput) return;

    const bool Pressed = (Action == GLFW_PRESS || Action == GLFW_REPEAT);
    auto MapKey = [&](int GlfwKey, VirtualKeyCategory EngineKey)
    {
        if (Key == GlfwKey) Self->ForwardInput->AssignKeyState(EngineKey, Pressed);
    };

    MapKey(GLFW_KEY_W,           VirtualKeyCategory::KeyW);
    MapKey(GLFW_KEY_A,           VirtualKeyCategory::KeyA);
    MapKey(GLFW_KEY_S,           VirtualKeyCategory::KeyS);
    MapKey(GLFW_KEY_D,           VirtualKeyCategory::KeyD);
    MapKey(GLFW_KEY_Q,           VirtualKeyCategory::KeyQ);
    MapKey(GLFW_KEY_E,           VirtualKeyCategory::KeyE);
    MapKey(GLFW_KEY_LEFT_SHIFT,  VirtualKeyCategory::KeyLeftShift);
    MapKey(GLFW_KEY_RIGHT_SHIFT, VirtualKeyCategory::KeyRightShift);
    MapKey(GLFW_KEY_ESCAPE,      VirtualKeyCategory::KeyEscape);

    if (Key == GLFW_KEY_ESCAPE && Action == GLFW_PRESS)
        glfwSetWindowShouldClose(Window, GLFW_TRUE);
}

void SwapchainExchange::OnMouseButton(GLFWwindow* Window, int Button, int Action, int) noexcept
{
    auto* Self = static_cast<SwapchainExchange*>(glfwGetWindowUserPointer(Window));
    if (!Self || !Self->ForwardInput) return;

    const bool Pressed = (Action == GLFW_PRESS);
    if (Button == GLFW_MOUSE_BUTTON_RIGHT)
    {
        Self->ForwardInput->AssignMouseButton(MouseButtonCategory::ButtonRight, Pressed);
        glfwSetInputMode(Window, GLFW_CURSOR, Pressed ? GLFW_CURSOR_DISABLED : GLFW_CURSOR_NORMAL);
        Self->CursorInitialised = false;
    }
    if (Button == GLFW_MOUSE_BUTTON_LEFT)
        Self->ForwardInput->AssignMouseButton(MouseButtonCategory::ButtonLeft,  Pressed);
    if (Button == GLFW_MOUSE_BUTTON_MIDDLE)
        Self->ForwardInput->AssignMouseButton(MouseButtonCategory::ButtonMiddle, Pressed);
}

void SwapchainExchange::OnCursorMove(GLFWwindow* Window, double X, double Y) noexcept
{
    auto* Self = static_cast<SwapchainExchange*>(glfwGetWindowUserPointer(Window));
    if (!Self || !Self->ForwardInput) return;

    if (!Self->CursorInitialised)
    {
        Self->PreviousCursorX  = X;
        Self->PreviousCursorY  = Y;
        Self->CursorInitialised = true;
    }

    const float Δx = static_cast<float>(X - Self->PreviousCursorX);
    const float Δy = static_cast<float>(Y - Self->PreviousCursorY);
    Self->PreviousCursorX = X;
    Self->PreviousCursorY = Y;

    Self->ForwardInput->AssignCursorDelta(Δx, Δy);
    Self->ForwardInput->AssignCursorPosition(static_cast<float>(X), static_cast<float>(Y));
}

void SwapchainExchange::OnScroll(GLFWwindow* Window, double, double OffsetY) noexcept
{
    auto* Self = static_cast<SwapchainExchange*>(glfwGetWindowUserPointer(Window));
    if (!Self || !Self->ForwardInput) return;
    Self->ForwardInput->AssignMouseScroll(static_cast<float>(OffsetY));
}

void SwapchainExchange::OnFramebuffer(GLFWwindow* Window, int, int) noexcept
{
    auto* Self = static_cast<SwapchainExchange*>(glfwGetWindowUserPointer(Window));
    if (Self) Self->SignalResize();
}

} // namespace Frontier
