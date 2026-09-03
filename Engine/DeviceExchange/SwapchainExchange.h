//============================================================================================================================================
//                                                      SWAPCHAINEXCHANGE.H
//============================================================================================================================================
// 🧩 Vulkan instance, surface, device, swapchain and recording-slot transport across the hardware vendor edge.

#pragma once

#if defined(_MSC_VER)
    #pragma warning(disable: 4324)
#endif

#include "InputExchange.h"
#include "OrientationClassifier.h"
#include <cstdint>
#include <vector>
#include <array>
#include <string>

struct GLFWwindow;

namespace Frontier {

//------------------------------------------------------------------------------------------------------------------------
//                                              SWAPCHAIN CONFIGURATION
//------------------------------------------------------------------------------------------------------------------------

struct SwapchainConfiguration
{
    uint32_t    Width;                          // [px]   surface horizontal resolution
    uint32_t    Height;                         // [px]   surface vertical resolution
    const char* Title;                          // [-]    window title string
    bool        ValidationEnabled;              // [-]    Vulkan validation layer activation
    std::string ShaderBinaryPath;               // [path] ReSTIR compute SPIR-V binary
};

//------------------------------------------------------------------------------------------------------------------------
//                             FACET STRUCTURE  (GPU SSBO — triangle geometry topology)
//
// 📐 Mechanism: three vertex positions + geometric normal + material slot index,
//    the minimal geometric facet of the Cornell Box mesh, packed as a contiguous
//    64-byte SSBO slot for GPU ray traversal.
//------------------------------------------------------------------------------------------------------------------------

struct TriangleIndex
{
    float    VertexAlphaX,  VertexAlphaY,  VertexAlphaZ;   // [m]   vertex α world position
    float    MaterialSlot;                                   // [-]   material index (uint reinterpreted)
    float    VertexBetaX,   VertexBetaY,   VertexBetaZ;    // [m]   vertex β world position
    float    TriangleSlot;                                   // [-]   triangle index (uint reinterpreted)
    float    VertexGammaX,  VertexGammaY,  VertexGammaZ;   // [m]   vertex γ world position
    float    _PadGamma;                                      // [-]   alignment
    float    NormalX,       NormalY,        NormalZ;         // [-]   geometric surface normal
    float    _PadNormal;                                     // [-]   alignment to 64 bytes
};

//------------------------------------------------------------------------------------------------------------------------
//                           RADIANCE STRUCTURE  (GPU SSBO — photometric surface topology)
//
// 📐 Mechanism: albedo reflectance, emissive radiance, roughness and metallic values
//    that define the surface's photometric behaviour, packed as a contiguous
//    48-byte SSBO slot for GPU shading.
//------------------------------------------------------------------------------------------------------------------------

struct RadianceStructure
{
    float    AlbedoR,    AlbedoG,    AlbedoB;               // [0..1]  diffuse surface reflectance
    float    Roughness;                                       // [0..1]  microfacet roughness
    float    EmissiveR,  EmissiveG,  EmissiveB;              // [lux]   self-emitted radiance
    float    Metallic;                                        // [0..1]  conductor parameter
    uint32_t Identifier;                                      // [-]     unique material slot index
    float    _Pad0, _Pad1, _Pad2;                            // [-]     alignment to 48 bytes
};

static_assert(sizeof(TriangleIndex) == 64u, "TriangleIndex must match the shader's std430 stride");
static_assert(sizeof(RadianceStructure) == 48u, "RadianceStructure must match the shader's std430 stride");

//------------------------------------------------------------------------------------------------------------------------
//                                    DISPATCH CONFIGURATION  (compute push constants)
//
// 📐 Mechanism: per-frame camera orientation and ReSTIR tuning scalars pushed
//    directly to the compute shader via vkCmdPushConstants — 96 bytes total.
//------------------------------------------------------------------------------------------------------------------------

struct DispatchConfiguration
{
    float    CameraOriginX,    CameraOriginY,    CameraOriginZ;  // [m]   camera world position
    float    FieldOfViewTanHalf;                                  // [-]   tan(α_FoV / 2)
    float    CameraForwardX,   CameraForwardY,   CameraForwardZ; // [-]   forward unit vector
    float    AspectRatio;                                          // [-]   width / height
    float    CameraRightX,     CameraRightY,     CameraRightZ;   // [-]   right unit vector
    float    Exposure;                                             // [-]   ACES tone-map exposure scalar
    float    CameraUpX,        CameraUpY,         CameraUpZ;     // [-]   up unit vector
    float    AmbientStrength;                                      // [-]   ambient fallback contribution
    uint32_t ViewportWidth;                                        // [px]  render width
    uint32_t ViewportHeight;                                       // [px]  render height
    uint32_t AccumulationIndex;                                    // [-]   temporal frame counter
    uint32_t SpatialPassCount;                                     // [-]   ReSTIR spatial resampling passes
    uint32_t CandidatesPerPixel;                                   // [-]   primary DI candidates per pixel
    uint32_t TriangleCount;                                        // [-]   total triangles in scene
    uint32_t LuminaireTriangleCount;                               // [-]   emissive triangles for DI sampling
    float    _Pad;                                                 // [-]   alignment to 96 bytes
};

static_assert(sizeof(DispatchConfiguration) == 96u, "DispatchConfiguration must match the shader push-constant block");

//------------------------------------------------------------------------------------------------------------------------
//                                                  SWAPCHAIN EXCHANGE
//------------------------------------------------------------------------------------------------------------------------

class SwapchainExchange
{
public:
    explicit SwapchainExchange(const SwapchainConfiguration& InitialConfiguration) noexcept;
    ~SwapchainExchange() noexcept;

    SwapchainExchange(const SwapchainExchange&)            = delete;
    SwapchainExchange& operator=(const SwapchainExchange&) = delete;

    [[nodiscard]] bool  Bring()  noexcept;
    void                Retire() noexcept;

    void                        PollInput(InputExchange& TargetInput) noexcept;
    [[nodiscard]] bool          CloseRequested() const noexcept;

    [[nodiscard]] bool          UploadTriangles(const std::vector<TriangleIndex>& Facets) noexcept;
    [[nodiscard]] bool          UploadRadiance(const std::vector<RadianceStructure>& Radiances) noexcept;

    [[nodiscard]] bool          RecordAndPresent(const DispatchConfiguration& Dispatch) noexcept;

    void                        SignalResize() noexcept { ResizePending = true; }

    [[nodiscard]] uint32_t      QueryWidth()  const noexcept { return Configuration.Width;  }
    [[nodiscard]] uint32_t      QueryHeight() const noexcept { return Configuration.Height; }
    [[nodiscard]] const std::string& QueryLastError() const noexcept { return LastError; }

    template<typename TargetType>
    [[nodiscard]] TargetType    Convert() const noexcept;

private:
    [[nodiscard]] bool  BringInstance()         noexcept;
    [[nodiscard]] bool  BringSurface()          noexcept;
    [[nodiscard]] bool  BringPhysicalDevice()   noexcept;
    [[nodiscard]] bool  BringLogicalDevice()    noexcept;
    [[nodiscard]] bool  BringSwapchain()        noexcept;
    [[nodiscard]] bool  BringStorageImage()     noexcept;
    [[nodiscard]] bool  BringComputePipeline()  noexcept;
    [[nodiscard]] bool  BringDescriptorSet()    noexcept;
    [[nodiscard]] bool  BringCommandRecording() noexcept;
    [[nodiscard]] bool  BringCycleSlots()       noexcept;
    [[nodiscard]] bool  BringImGui()            noexcept;

    void                RetireSwapchain()       noexcept;
    [[nodiscard]] bool  RebuildSwapchain()      noexcept;

    [[nodiscard]] bool  RecordComputeCommands(uint32_t ImageOrdinal,
                                              const DispatchConfiguration& Dispatch) noexcept;
    [[nodiscard]] bool  WriteDescriptorSet() noexcept;
    [[nodiscard]] bool  ReportFailure(std::string Message) noexcept;

    [[nodiscard]] uint32_t ResolveMemoryType(uint32_t TypeMask, uint32_t PropertyMask) const noexcept;

    static void OnKey         (GLFWwindow*, int Key, int Scancode, int Action, int Mods) noexcept;
    static void OnMouseButton (GLFWwindow*, int Button, int Action, int Mods) noexcept;
    static void OnCursorMove  (GLFWwindow*, double X, double Y) noexcept;
    static void OnScroll      (GLFWwindow*, double OffsetX, double OffsetY) noexcept;
    static void OnFramebuffer (GLFWwindow*, int W, int H) noexcept;

    // 📝 Full Vulkan object lifetimes are owned by VulkanRecord, defined only in .cpp
    struct VulkanRecord;
    VulkanRecord*           Vulkan;             // [-]   heap-allocated Vulkan object lifetimes

    GLFWwindow*             GlfwWindow;             // [-]   GLFW window pointer
    SwapchainConfiguration  Configuration;          // [-]   runtime-tunable surface parameters
    std::string             LastError;               // [-]   most recent actionable startup/runtime failure
    bool                    ResizePending;           // [-]   framebuffer resize signal
    bool                    GlfwInitialised;          // [-]   glfwInit completed
    bool                    ImGuiContextInitialised;  // [-]   ImGui context exists
    bool                    ImGuiGlfwInitialised;     // [-]   ImGui GLFW backend initialized
    bool                    ImGuiVulkanInitialised;   // [-]   ImGui Vulkan backend initialized
    bool                    SceneDescriptorsReady;   // [-]   descriptor set references both uploaded scene buffers

    InputExchange*          ForwardInput;            // [-]   target for GLFW callback forwarding (valid during PollInput)
    double                  PreviousCursorX;         // [px]  last known cursor horizontal position
    double                  PreviousCursorY;         // [px]  last known cursor vertical position
    bool                    CursorInitialised;       // [-]   first-movement delta suppression
};

template<>
inline bool SwapchainExchange::Convert<bool>() const noexcept
{
    return !CloseRequested();
}

template<>
inline uint32_t SwapchainExchange::Convert<uint32_t>() const noexcept
{
    return Configuration.Width;
}

} // namespace Frontier
