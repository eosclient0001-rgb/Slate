//============================================================================================================================================
//                                                      GAMEEXECUTION.CPP
//============================================================================================================================================
// 🧩 Project-Zero entry point — opens the Vulkan window, uploads Cornell Box geometry, runs the ReSTIR render loop.

#include "../../../Engine/DeviceExchange/SwapchainExchange.h"
#include "../../../Engine/DisplayPresentation/ReSTIRIntegrator.h"
#include "../../../Engine/DisplayPresentation/RenderScheduler.h"
#include "../../../Engine/DeviceExchange/DiagnosticMetrics.h"
#include "FlyThroughSolver.h"
#include "RayTracingSolver.h"

#include <array>
#include <chrono>
#include <filesystem>
#include <iostream>

#if defined(_WIN32)
    #include <windows.h>
#endif

namespace {

std::filesystem::path ResolveBinaryDirectory(int ArgumentCount, char** ArgumentValues)
{
    try
    {
#if defined(_WIN32)
        // argv[0] may be only a command name when launched through PATH. Ask the
        // Windows loader for the actual module so packaged assets always resolve.
        std::array<wchar_t, 32768u> ModulePath{};
        const DWORD ModulePathLength = GetModuleFileNameW(
            nullptr, ModulePath.data(), static_cast<DWORD>(ModulePath.size()));
        if (ModulePathLength > 0u && ModulePathLength < ModulePath.size())
        {
            return std::filesystem::path(
                ModulePath.data(), ModulePath.data() + ModulePathLength).parent_path();
        }
#endif
        if (ArgumentCount > 0 && ArgumentValues && ArgumentValues[0] && ArgumentValues[0][0] != '\0')
        {
            std::filesystem::path ExecutablePath = std::filesystem::absolute(ArgumentValues[0]);
            if (std::filesystem::exists(ExecutablePath))
                ExecutablePath = std::filesystem::weakly_canonical(ExecutablePath);
            if (ExecutablePath.has_parent_path())
                return ExecutablePath.parent_path();
        }
        return std::filesystem::current_path();
    }
    catch (...)
    {
        return ".";
    }
}

std::filesystem::path ResolveShaderPath(const std::filesystem::path& BinaryDirectory)
{
    const std::filesystem::path PackagedShader = BinaryDirectory / "ReSTIRViewport.spv";
    if (std::filesystem::exists(PackagedShader)) return PackagedShader;

    const std::filesystem::path DevelopmentShader =
        std::filesystem::current_path() / "Engine" / "Shaders" / "ReSTIRViewport.spv";
    if (std::filesystem::exists(DevelopmentShader)) return DevelopmentShader;

    // Preserve the packaged location in the error message when neither candidate exists.
    return PackagedShader;
}

} // namespace

int main(int ArgumentCount, char** ArgumentValues)
{
    const std::filesystem::path BinaryDirectory =
        ResolveBinaryDirectory(ArgumentCount, ArgumentValues);
    const std::filesystem::path ShaderPath = ResolveShaderPath(BinaryDirectory);
    const std::filesystem::path DiagnosticDirectory = BinaryDirectory / "Diagnostics";
    const std::filesystem::path DiagnosticPath =
        DiagnosticDirectory / "ProjectZero_TelemetryReport.md";

    std::cout << "Project-Zero | Frontier Engine\n"
              << "  Binary directory : " << BinaryDirectory.string() << "\n"
              << "  Shader binary    : " << ShaderPath.string() << "\n"
              << "  Diagnostic log   : " << DiagnosticPath.string() << "\n"
              << std::flush;

    //──────────────────────────────────────────────────────────────────────────
    // Telemetry sink — file output and console echo stay active together.
    //──────────────────────────────────────────────────────────────────────────
    Frontier::DiagnosticConfiguration DiagnosticConfig{};
    DiagnosticConfig.DestinationFolder          = DiagnosticDirectory.string();
    DiagnosticConfig.OutputFileStem             = "ProjectZero_TelemetryReport";
    DiagnosticConfig.FileExtension              = ".md";
    DiagnosticConfig.TimestampPrefixEnabled     = true;
    DiagnosticConfig.ConsoleEchoEnabled         = true;
    DiagnosticConfig.MarkdownTableFormatEnabled = true;

    Frontier::DiagnosticMetrics Logger(DiagnosticConfig);
    if (!Logger.InitializeSink())
    {
        std::cerr << "[FATAL] [Bootstrap] Could not create the diagnostic log at "
                  << DiagnosticDirectory.string() << "\n";
        return 1;
    }
    Logger.RecordMessage(Frontier::DiagnosticSeverity::Information,
                         "Bootstrap", "Project-Zero windowed ReSTIR renderer starting.");
    Logger.RecordMessage(Frontier::DiagnosticSeverity::Information,
                         "Bootstrap", "Shader: " + ShaderPath.string());

    //──────────────────────────────────────────────────────────────────────────
    // Scene — Cornell Box (CPU analytical geometry, uploaded once to GPU SSBOs)
    //──────────────────────────────────────────────────────────────────────────
    Frontier::ProjectZero::RayTracingSolver Scene;

    const std::vector<Frontier::TriangleIndex> GpuTriangles =
        Frontier::ReSTIRIntegrator::BuildTriangleIndex(Scene);

    const std::vector<Frontier::RadianceStructure> GpuMaterials =
        Frontier::ReSTIRIntegrator::BuildRadianceStructures(Scene);

    const uint32_t LuminaireCount =
        Frontier::ReSTIRIntegrator::CountLuminaireTriangles(Scene);

    //──────────────────────────────────────────────────────────────────────────
    // Camera — Cornell-box fly-through, +Y up and +Z forward
    //──────────────────────────────────────────────────────────────────────────
    Frontier::ProjectZero::FlyThroughConfiguration CameraConfig
    {
        2.5f,       // [m/s]    base flight speed
        3.0f,       // [-]      Shift boost multiplier
        0.0025f,    // [rad/px] mouse sensitivity
        0.5f,       // [m/s]    scroll speed increment
        12.0f       // [-]      acceleration damping
    };

    Frontier::ProjectZero::FlyThroughSolver Camera(CameraConfig);
    Camera.AssignSpatialLocation(Frontier::Vector3{ 0.0f, 1.0f, -1.95f });
    Camera.AssignOrientationEuler(0.0f, 0.0f, 0.0f);
    Camera.AssignFieldOfView(55.0f);
    Camera.AssignAspectRatio(1280.0f / 720.0f);

    //──────────────────────────────────────────────────────────────────────────
    // ReSTIR integrator — owns dispatch parameters, accumulation index
    //──────────────────────────────────────────────────────────────────────────
    Frontier::ReSTIRIntegratorConfiguration IntegratorConfig
    {
        8u,         // [-]  candidates per pixel
        2u,         // [-]  spatial resampling passes
        1.05f,      // [-]  ACES exposure
        0.015f      // [-]  ambient strength
    };

    Frontier::ReSTIRIntegrator Integrator(IntegratorConfig);

    //──────────────────────────────────────────────────────────────────────────
    // Swapchain exchange — GLFW window + Vulkan surface + compute pipeline
    //──────────────────────────────────────────────────────────────────────────
    Frontier::SwapchainConfiguration SurfaceConfig
    {
        1280u,
        720u,
        "Project-Zero  |  ReSTIR GI  |  Frontier Engine",
        false,      // validation layers — set true for debugging
        ShaderPath.string()
    };

    Frontier::SwapchainExchange Surface(SurfaceConfig);

    if (!Surface.Bring())
    {
        Logger.RecordMessage(Frontier::DiagnosticSeverity::Fatal,
                             "Bootstrap", "Renderer bring-up failed: " + Surface.QueryLastError());
        Logger.TerminateSink();
        return 1;
    }

    Logger.RecordMessage(Frontier::DiagnosticSeverity::Information,
                         "Bootstrap", "Native GLFW window and Vulkan renderer initialized.");

    if (!Surface.UploadTriangles(GpuTriangles) || !Surface.UploadRadiance(GpuMaterials))
    {
        Logger.RecordMessage(Frontier::DiagnosticSeverity::Fatal,
                             "Bootstrap", "Scene upload failed: " + Surface.QueryLastError());
        Logger.TerminateSink();
        return 1;
    }

    //──────────────────────────────────────────────────────────────────────────
    // ImGui panel — apply theme once after context exists
    //──────────────────────────────────────────────────────────────────────────
    Frontier::RenderScheduler Panel;
    Panel.ApplyTheme();

    Camera.AssignAspectRatio(
        static_cast<float>(Surface.QueryWidth()) /
        static_cast<float>(Surface.QueryHeight()));

    Logger.RecordMessage(Frontier::DiagnosticSeverity::Information,
                         "Bootstrap", "Entering render loop.");

    //──────────────────────────────────────────────────────────────────────────
    // Input exchange — filled each frame by GLFW callbacks
    //──────────────────────────────────────────────────────────────────────────
    Frontier::InputExchange Input;

    //──────────────────────────────────────────────────────────────────────────
    // Render loop
    //──────────────────────────────────────────────────────────────────────────
    using Clock    = std::chrono::high_resolution_clock;
    using Duration = std::chrono::duration<float>;

    auto PreviousTime = Clock::now();
    bool RenderSucceeded = true;

    while (!Surface.CloseRequested() && !Panel.Convert<bool>())
    {
        const auto  NowTime = Clock::now();
        float       Δτ      = std::chrono::duration_cast<Duration>(NowTime - PreviousTime).count();
        PreviousTime        = NowTime;

        // 📝 Clamp Δτ to prevent spiral-of-death on window drag or breakpoints
        if (Δτ > 0.1f) Δτ = 0.1f;

        // ① Poll input — GLFW callbacks forward into Input
        Surface.PollInput(Input);

        // ② Advance camera kinematics
        Camera.AdvanceLocomotion(Input, Δτ);
        Camera.AssignAspectRatio(
            static_cast<float>(Surface.QueryWidth()) /
            static_cast<float>(Surface.QueryHeight()));

        // ③ Build ImGui draw data (calls ImGui::NewFrame → ImGui::Render internally)
        Panel.Present(Integrator, Camera, Scene,
                      Surface.QueryWidth(), Surface.QueryHeight());

        // ④ Build dispatch configuration from live camera + integrator state
        const Frontier::DispatchConfiguration Dispatch = Integrator.BuildDispatch(
            Camera,
            Surface.QueryWidth(),
            Surface.QueryHeight(),
            static_cast<uint32_t>(Scene.QueryTriangles().size()),
            LuminaireCount);

        // ⑤ Dispatch compute, blit to swapchain, submit ImGui, present
        if (!Surface.RecordAndPresent(Dispatch))
        {
            Logger.RecordMessage(Frontier::DiagnosticSeverity::Fatal,
                                 "Renderer", "Frame presentation failed: " + Surface.QueryLastError());
            RenderSucceeded = false;
            break;
        }

        Integrator.IncrementAccumulationIndex();
    }

    //──────────────────────────────────────────────────────────────────────────
    // Shutdown
    //──────────────────────────────────────────────────────────────────────────
    Surface.Retire();

    Logger.RecordMessage(
        RenderSucceeded ? Frontier::DiagnosticSeverity::Information : Frontier::DiagnosticSeverity::Fatal,
        "Shutdown",
        RenderSucceeded ? "Render loop exited cleanly." : "Render loop stopped after a renderer failure.");
    Logger.TerminateSink();

    return RenderSucceeded ? 0 : 1;
}
