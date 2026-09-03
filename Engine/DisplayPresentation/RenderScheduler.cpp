//============================================================================================================================================
//                                                      RENDERERPANEL.CPP
//============================================================================================================================================
// 🧩 Immediate-mode ImGui control centre overlay — presents ReSTIR parameters, camera telemetry and scene diagnostics.

#include "RenderScheduler.h"

#ifndef GLFW_INCLUDE_NONE
    #define GLFW_INCLUDE_NONE
#endif
#include <GLFW/glfw3.h>

#include <imgui.h>
#include <imgui_impl_glfw.h>
#include <imgui_impl_vulkan.h>

#include <algorithm>
#include <cmath>

namespace Frontier {

//============================================================================================================================================
//                                                      APPLY THEME
//============================================================================================================================================

void RenderScheduler::ApplyTheme() noexcept
{
    ImGui::StyleColorsDark();

    ImGuiStyle& Style           = ImGui::GetStyle();
    Style.WindowRounding        = 8.0f;
    Style.FrameRounding         = 5.0f;
    Style.GrabRounding          = 5.0f;
    Style.TabRounding           = 4.0f;
    Style.WindowBorderSize      = 0.0f;
    Style.FrameBorderSize       = 0.0f;
    Style.WindowPadding         = ImVec2(14.0f, 14.0f);
    Style.ItemSpacing           = ImVec2(8.0f, 6.0f);

    ImVec4* Colours = Style.Colors;
    Colours[ImGuiCol_WindowBg]        = ImVec4(0.08f, 0.09f, 0.10f, 0.93f);
    Colours[ImGuiCol_TitleBg]         = ImVec4(0.05f, 0.06f, 0.07f, 1.00f);
    Colours[ImGuiCol_TitleBgActive]   = ImVec4(0.09f, 0.27f, 0.48f, 1.00f);
    Colours[ImGuiCol_Header]          = ImVec4(0.09f, 0.24f, 0.43f, 0.85f);
    Colours[ImGuiCol_HeaderHovered]   = ImVec4(0.13f, 0.33f, 0.55f, 1.00f);
    Colours[ImGuiCol_SliderGrab]      = ImVec4(0.18f, 0.52f, 0.82f, 1.00f);
    Colours[ImGuiCol_SliderGrabActive]= ImVec4(0.24f, 0.62f, 0.95f, 1.00f);
    Colours[ImGuiCol_Button]          = ImVec4(0.09f, 0.27f, 0.48f, 0.80f);
    Colours[ImGuiCol_ButtonHovered]   = ImVec4(0.14f, 0.36f, 0.62f, 1.00f);
    Colours[ImGuiCol_ButtonActive]    = ImVec4(0.20f, 0.46f, 0.78f, 1.00f);
    Colours[ImGuiCol_FrameBg]         = ImVec4(0.13f, 0.14f, 0.16f, 1.00f);
    Colours[ImGuiCol_FrameBgHovered]  = ImVec4(0.18f, 0.19f, 0.22f, 1.00f);
    Colours[ImGuiCol_Separator]       = ImVec4(0.22f, 0.24f, 0.28f, 1.00f);
    Colours[ImGuiCol_Tab]             = ImVec4(0.08f, 0.20f, 0.36f, 0.86f);
    Colours[ImGuiCol_TabHovered]      = ImVec4(0.14f, 0.36f, 0.62f, 1.00f);
    Colours[ImGuiCol_TabActive]       = ImVec4(0.18f, 0.44f, 0.74f, 1.00f);
}

//============================================================================================================================================
//                                                         PRESENT
//============================================================================================================================================

void RenderScheduler::Present(
    ReSTIRIntegrator&                    Integrator,
    const ProjectZero::FlyThroughSolver& Camera,
    const ProjectZero::RayTracingSolver& Scene,
    uint32_t                             ViewportWidth,
    uint32_t                             ViewportHeight) noexcept
{
    ImGui_ImplVulkan_NewFrame();
    ImGui_ImplGlfw_NewFrame();
    ImGui::NewFrame();

    const float PanelWidth  = 320.0f;
    const float PanelHeight = static_cast<float>(ViewportHeight);

    ImGui::SetNextWindowPos (ImVec2(static_cast<float>(ViewportWidth) - PanelWidth, 0.0f), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(PanelWidth, PanelHeight), ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(0.93f);

    constexpr ImGuiWindowFlags PanelFlags =
        ImGuiWindowFlags_NoMove            |
        ImGuiWindowFlags_NoResize          |
        ImGuiWindowFlags_NoCollapse        |
        ImGuiWindowFlags_NoBringToFrontOnFocus;

    ImGui::Begin("Control Centre", nullptr, PanelFlags);

    SectionCamera(Camera);
    ImGui::Spacing();
    SectionReSTIR(Integrator, ViewportWidth, ViewportHeight);
    ImGui::Spacing();
    SectionScene(Scene);

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();

    if (ImGui::Button("Quit", ImVec2(-1.0f, 0.0f)))
        QuitRequested = true;

    ImGui::End();
    ImGui::Render();
}

//============================================================================================================================================
//                                                    SECTION — CAMERA
//============================================================================================================================================

void RenderScheduler::SectionCamera(const ProjectZero::FlyThroughSolver& Camera) noexcept
{
    if (!ImGui::CollapsingHeader("Camera", ImGuiTreeNodeFlags_DefaultOpen)) return;

    const Vector3& Position = Camera.QuerySpatialLocation();
    ImGui::Text("Position");
    ImGui::Text("  X  %+.3f m     Y  %+.3f m     Z  %+.3f m",
                Position.x, Position.y, Position.z);

    ImGui::Spacing();

    const float PitchDeg = Camera.QueryPitchRadians() * 57.295779513f;
    const float YawDeg   = Camera.QueryYawRadians()   * 57.295779513f;
    ImGui::Text("Pitch  %+.1f °     Yaw  %+.1f °", PitchDeg, YawDeg);

    ImGui::Spacing();

    ImGui::Text("Speed  %.2f m/s     FoV  %.1f °",
                Camera.QueryFlightSpeed(),
                Camera.QueryFieldOfViewRadians() * 57.295779513f);

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();

    ImGui::TextDisabled("W / A / S / D          fly  forward / strafe");
    ImGui::TextDisabled("Q / E                  descend / ascend");
    ImGui::TextDisabled("RMB + drag             look around");
    ImGui::TextDisabled("Scroll                 adjust speed");
    ImGui::TextDisabled("Left Shift             3 × speed boost");
    ImGui::TextDisabled("Escape                 quit");
}

//============================================================================================================================================
//                                                  SECTION — RESTIR
//============================================================================================================================================

void RenderScheduler::SectionReSTIR(
    ReSTIRIntegrator& Integrator,
    uint32_t          ViewportWidth,
    uint32_t          ViewportHeight) noexcept
{
    if (!ImGui::CollapsingHeader("ReSTIR DI + GI", ImGuiTreeNodeFlags_DefaultOpen)) return;

    const ReSTIRIntegratorConfiguration& Config = Integrator.QueryConfiguration();

    int Candidates    = static_cast<int>(Config.CandidatesPerPixel);
    int SpatialPasses = static_cast<int>(Config.SpatialPassCount);
    float Exposure    = Config.Exposure;

    if (ImGui::SliderInt("Candidates / px", &Candidates, 1, 32))
        Integrator.AssignCandidatesPerPixel(static_cast<uint32_t>(std::clamp(Candidates, 1, 32)));

    if (ImGui::SliderInt("Spatial passes",  &SpatialPasses, 0, 8))
        Integrator.AssignSpatialPassCount(static_cast<uint32_t>(std::clamp(SpatialPasses, 0, 8)));

    if (ImGui::SliderFloat("Exposure", &Exposure, 0.1f, 4.0f, "%.2f"))
        Integrator.AssignExposure(Exposure);

    ImGui::Spacing();
    ImGui::Text("Frame      %u", Integrator.QueryAccumulationIndex());
    ImGui::Text("Viewport   %u × %u px", ViewportWidth, ViewportHeight);
}

//============================================================================================================================================
//                                                   SECTION — SCENE
//============================================================================================================================================

void RenderScheduler::SectionScene(const ProjectZero::RayTracingSolver& Scene) noexcept
{
    if (!ImGui::CollapsingHeader("Scene", ImGuiTreeNodeFlags_DefaultOpen)) return;

    ImGui::Text("Cornell Box");
    ImGui::Text("Triangles   %zu", Scene.QueryTriangles().size());
    ImGui::Text("Materials   %zu", Scene.QueryMaterials().size());

    ImGui::Spacing();
    ImGui::TextColored(ImVec4(0.85f, 0.12f, 0.12f, 1.0f), "LEFT     Red wall");
    ImGui::TextColored(ImVec4(0.12f, 0.85f, 0.15f, 1.0f), "RIGHT    Green wall");
    ImGui::TextColored(ImVec4(1.00f, 0.95f, 0.80f, 1.0f), "CEILING  Area luminaire  32 lux");
    ImGui::TextColored(ImVec4(0.78f, 0.78f, 0.78f, 1.0f), "BOX A    Tall diffuse box");
    ImGui::TextColored(ImVec4(0.78f, 0.78f, 0.78f, 1.0f), "BOX B    Short diffuse box");
}

} // namespace Frontier
