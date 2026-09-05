//============================================================================================================================================
//                                                      GAMEEXECUTION.CPP
//============================================================================================================================================
// 🧩 Project-Physics entry point — brings up the Jolt rigid-body solver, drops boxes / spheres / capsules on a plane and ticks the
//    world from the main loop exactly the way Project-Zero ticks its camera and overlay.
//
//    Usage: Project-Physics [--seconds <float>] [--fixed] [--boxes N] [--spheres N] [--capsules N] [--quiet] [--trace <file.csv>]
//        --seconds   wall / simulated time budget (default 12 s); the loop also ends early once every body is asleep
//        --fixed     feed the tick a constant Δτ = 1/60 s instead of the wall clock (deterministic proof runs, no pacing)
//        --quiet     suppress the per-half-second pose table (summary only)
//        --trace     write every tick's poses as CSV (tick, t, body, shape, x, y, z, vx, vy, vz, active) for offline proofs
//
//    Merge note: the three lines marked ⟨TICK⟩ are the only thing Project-Zero needs inside its render loop — after
//    `Camera.AdvanceLocomotion` and before the ImGui build — plus the Bring()/Construct() block before the loop.

#include "../../../Engine/PhysicalDynamics/RigidBodySolver.h"
#include "../../../Engine/DeviceExchange/DiagnosticMetrics.h"
#include "DropSceneStructure.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

const char* ShapeLabel(Frontier::CollisionShapeCategory Shape) noexcept
{
    switch (Shape)
    {
        case Frontier::CollisionShapeCategory::Plane:    return "plane";
        case Frontier::CollisionShapeCategory::Box:      return "box";
        case Frontier::CollisionShapeCategory::Sphere:   return "sphere";
        case Frontier::CollisionShapeCategory::Capsule:  return "capsule";
        case Frontier::CollisionShapeCategory::Cylinder: return "cylinder";
    }
    return "?";
}

// Inscribed radius of a body's shape: whatever its orientation, the centre of a body resting on the plane can never be
//    closer to it than this without penetrating — the conservative bound the tunnelling proof checks against.
float InscribedRadius(const Frontier::RigidBodyDescription& D) noexcept
{
    switch (D.Shape.Category)
    {
        case Frontier::CollisionShapeCategory::Box:      return std::min({ D.Shape.HalfExtents.x, D.Shape.HalfExtents.y, D.Shape.HalfExtents.z });
        case Frontier::CollisionShapeCategory::Sphere:   return D.Shape.Radius;
        case Frontier::CollisionShapeCategory::Capsule:  return D.Shape.Radius;
        case Frontier::CollisionShapeCategory::Cylinder: return std::min(D.Shape.Radius, D.Shape.HalfHeight);
        default:                                         return 0.0f;
    }
}

} // namespace

int main(int argc, char** argv)
{
    //──────────────────────────────────────────────────────────────────────────
    // Arguments
    //──────────────────────────────────────────────────────────────────────────
    float    SecondsBudget = 12.0f;   // [s]
    bool     FixedStepTick = false;
    bool     Quiet         = false;
    std::string TracePath;
    Frontier::ProjectPhysics::DropSceneConfiguration SceneConfig;
    for (int I = 1; I < argc; ++I)
    {
        const bool HasValue = I + 1 < argc;
        if      (std::strcmp(argv[I], "--fixed") == 0)              FixedStepTick = true;
        else if (std::strcmp(argv[I], "--quiet") == 0)              Quiet = true;
        else if (std::strcmp(argv[I], "--seconds") == 0 && HasValue)  SecondsBudget = static_cast<float>(std::atof(argv[++I]));
        else if (std::strcmp(argv[I], "--trace") == 0 && HasValue)    TracePath = argv[++I];
        else if (std::strcmp(argv[I], "--boxes") == 0 && HasValue)    SceneConfig.BoxCount     = static_cast<uint32_t>(std::atoi(argv[++I]));
        else if (std::strcmp(argv[I], "--spheres") == 0 && HasValue)  SceneConfig.SphereCount  = static_cast<uint32_t>(std::atoi(argv[++I]));
        else if (std::strcmp(argv[I], "--capsules") == 0 && HasValue) SceneConfig.CapsuleCount = static_cast<uint32_t>(std::atoi(argv[++I]));
        else { std::fprintf(stderr, "[Project-Physics] unknown argument '%s'\n", argv[I]); return 1; }
    }
    SecondsBudget = std::clamp(SecondsBudget, 0.5f, 600.0f);
    // The plane is finite in the broad phase (PlaneHalfExtent); a stress pile flings bodies tens of metres sideways, so the
    //    ground grows with the body count — a body rolling off the edge would otherwise look exactly like tunnelling.
    SceneConfig.PlaneHalfExtent = std::max(SceneConfig.PlaneHalfExtent, 4.0f * static_cast<float>(SceneConfig.BoxCount + SceneConfig.SphereCount + SceneConfig.CapsuleCount));

    //──────────────────────────────────────────────────────────────────────────
    // Telemetry sink
    //──────────────────────────────────────────────────────────────────────────
    Frontier::DiagnosticConfiguration DiagnosticConfig{};
    DiagnosticConfig.DestinationFolder          = "Diagnostics";
    DiagnosticConfig.OutputFileStem             = "ProjectPhysics_TelemetryReport";
    DiagnosticConfig.FileExtension              = ".md";
    DiagnosticConfig.TimestampPrefixEnabled     = true;
    DiagnosticConfig.ConsoleEchoEnabled         = true;
    DiagnosticConfig.MarkdownTableFormatEnabled = true;

    Frontier::DiagnosticMetrics Logger(DiagnosticConfig);
    if (!Logger.InitializeSink())
        std::cerr << "[Project-Physics] Telemetry sink could not be opened; continuing with console output only.\n";
    Logger.RecordMessage(Frontier::DiagnosticSeverity::Information, "Bootstrap", "Project-Physics rigid-body testbed starting.");

    //──────────────────────────────────────────────────────────────────────────
    // Rigid-body solver — one Jolt world, fixed 60 Hz step, +Z-up gravity
    //──────────────────────────────────────────────────────────────────────────
    Frontier::RigidBodyConfiguration SolverConfig;
    SolverConfig.Gravity            = Frontier::Vector3{ 0.0f, 0.0f, -9.81f };   // [m/s²]
    SolverConfig.FixedStepSeconds   = 1.0f / 60.0f;                             // [s]
    SolverConfig.MaxStepsPerAdvance = 4u;
    SolverConfig.MaxBodies          = 1024u;

    Frontier::RigidBodySolver Solver;
    if (!Solver.Bring(SolverConfig))
    {
        Logger.RecordMessage(Frontier::DiagnosticSeverity::Fatal, "Bootstrap", ("RigidBodySolver bring-up refused: " + Solver.QueryLastRefusal()).c_str());
        Logger.TerminateSink();
        return 1;
    }
    {
        char Line[160];
        std::snprintf(Line, sizeof(Line), "%s ready - fixed step %.4f s, gravity (%.2f %.2f %.2f) m/s^2, %u worker threads",
                      Frontier::RigidBodySolver::QueryBackendVersion(), SolverConfig.FixedStepSeconds,
                      SolverConfig.Gravity.x, SolverConfig.Gravity.y, SolverConfig.Gravity.z,
                      SolverConfig.WorkerThreads > 0u ? SolverConfig.WorkerThreads : std::max(1u, std::thread::hardware_concurrency() - 1u));
        Logger.RecordMessage(Frontier::DiagnosticSeverity::Information, "Bootstrap", Line);
    }

    //──────────────────────────────────────────────────────────────────────────
    // Level — a plane and a column of falling bodies
    //──────────────────────────────────────────────────────────────────────────
    Frontier::ProjectPhysics::DropSceneStructure Scene;
    if (!Scene.Construct(Solver, SceneConfig))
    {
        Logger.RecordMessage(Frontier::DiagnosticSeverity::Fatal, "Scene", ("Body creation refused: " + Solver.QueryLastRefusal()).c_str());
        Logger.TerminateSink();
        return 1;
    }
    {
        char Line[160];
        std::snprintf(Line, sizeof(Line), "Drop scene: ground plane (z = 0, half extent %.0f m) + %zu dynamic bodies (%u boxes, %u spheres, %u capsules) from z = %.1f m",
                      SceneConfig.PlaneHalfExtent, Scene.QueryBodies().size(), SceneConfig.BoxCount, SceneConfig.SphereCount, SceneConfig.CapsuleCount, SceneConfig.DropHeight);
        Logger.RecordMessage(Frontier::DiagnosticSeverity::Information, "Scene", Line);
    }

    std::ofstream Trace;
    if (!TracePath.empty())
    {
        Trace.open(TracePath, std::ios::out | std::ios::trunc);
        if (Trace.is_open()) Trace << "tick,t,body,shape,x,y,z,vx,vy,vz,active\n";
        else                 std::cerr << "[Project-Physics] cannot open trace file " << TracePath << "\n";
    }

    std::vector<Frontier::RigidBodyPose> Poses;
    const std::vector<Frontier::RigidBodyIdentity>&    Bodies       = Scene.QueryBodies();
    const std::vector<Frontier::RigidBodyDescription>& Descriptions = Scene.QueryDescriptions();

    // Free-fall witness: the topmost box cannot touch anything during its first half second, so its drop must match ½·g·t².
    const Frontier::RigidBodyIdentity Witness   = SceneConfig.BoxCount > 0u ? Bodies[SceneConfig.BoxCount - 1u] : Bodies.front();
    Frontier::RigidBodyPose           WitnessStart;
    (void)Solver.QueryPose(Witness, WitnessStart);
    bool  WitnessSampled = false;
    float WitnessDrop    = 0.0f;   // [m] measured at the first tick past 0.5 s

    auto PrintPoseTable = [&](float Elapsed)
    {
        Solver.QueryPoses(Poses);
        std::printf("\n  t = %6.2f s   step %llu   active %u / %u   last step %.3f ms\n",
                    Elapsed, static_cast<unsigned long long>(Solver.QueryMetrics().StepCount),
                    Solver.QueryMetrics().ActiveBodyCount, Solver.QueryMetrics().BodyCount, Solver.QueryMetrics().LastStepMilliseconds);
        std::printf("  %-10s %-8s %9s %9s %9s   %8s %8s %8s   %s\n", "body", "shape", "x [m]", "y [m]", "z [m]", "vx", "vy", "vz [m/s]", "");
        for (const Frontier::RigidBodyPose& P : Poses)
        {
            if (P.Motion == Frontier::RigidBodyMotionCategory::Static) continue;
            std::printf("  %-10s %-8s %9.3f %9.3f %9.3f   %8.3f %8.3f %8.3f   %s\n",
                        Solver.QueryName(P.Identity).c_str(), ShapeLabel(P.Shape),
                        P.Position.x, P.Position.y, P.Position.z, P.LinearVelocity.x, P.LinearVelocity.y, P.LinearVelocity.z,
                        P.Active ? "" : "asleep");
        }
    };

    //──────────────────────────────────────────────────────────────────────────
    // Main loop — Δτ from the wall clock (or fixed), clamped, then one Tick
    //──────────────────────────────────────────────────────────────────────────
    using Clock    = std::chrono::steady_clock;
    using Duration = std::chrono::duration<float>;

    Logger.RecordMessage(Frontier::DiagnosticSeverity::Information, "Bootstrap", FixedStepTick ? "Entering main loop (fixed Δτ = 1/60 s)." : "Entering main loop (wall-clock Δτ).");

    auto  PreviousTime  = Clock::now();
    float Elapsed       = 0.0f;   // [s] simulated time handed to the tick
    float NextPrintTime = 0.0f;   // [s]
    // Tunnelling proof. Clearance = centre z − inscribed radius: ≥ 0 when the body is above the plane whatever its orientation.
    //    Transient: the deepest sample ever seen. A body arriving at 10 m/s covers 0.17 m per 60 Hz step and the solver only
    //    looks 2 cm ahead (SpeculativeContactDistance), so it lands up to ~0.15 m deep for ONE step and is pushed back out —
    //    that is contact resolution, not tunnelling, and it is reported but not judged.
    //    Settled: the clearance at the end of the run. A body that actually fell through the plane is metres below it.
    float       MinimumFloorClearance = 1.0e9f;   // [m] transient
    std::string WorstClearanceBody;               // [-] body and time that produced MinimumFloorClearance
    float       WorstClearanceTime = 0.0f;        // [s]
    float       SettledFloorClearance = 1.0e9f;   // [m] min over bodies at the end of the run
    float AllAsleepSince = -1.0f; // [s]
    uint32_t TickCount   = 0u;

    while (Elapsed < SecondsBudget)
    {
        const auto NowTime = Clock::now();
        float      Δτ      = FixedStepTick ? SolverConfig.FixedStepSeconds : std::chrono::duration_cast<Duration>(NowTime - PreviousTime).count();
        PreviousTime       = NowTime;
        if (Δτ > 0.1f) Δτ = 0.1f;   // clamp — window drag / breakpoint / hitch must not spiral

        // ⟨TICK⟩ ① advance the physics world (zero or more fixed 60 Hz steps, remainder carried to the next tick)
        Solver.Advance(Δτ);
        // ⟨TICK⟩ ② read every pose back for presentation (a renderer would copy these into its instance transforms)
        Solver.QueryPoses(Poses);
        // ⟨TICK⟩ ③ the interpolation α (accumulator ÷ step) is available for smooth presentation between steps
        (void)Solver.QueryInterpolationAlpha();

        Elapsed += Δτ;
        ++TickCount;

        if (Trace.is_open())
        {
            for (const Frontier::RigidBodyPose& P : Poses)
            {
                if (P.Motion == Frontier::RigidBodyMotionCategory::Static) continue;
                char Row[256];
                std::snprintf(Row, sizeof(Row), "%u,%.5f,%s,%s,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%d\n", TickCount, Elapsed,
                              Solver.QueryName(P.Identity).c_str(), ShapeLabel(P.Shape), P.Position.x, P.Position.y, P.Position.z,
                              P.LinearVelocity.x, P.LinearVelocity.y, P.LinearVelocity.z, P.Active ? 1 : 0);
                Trace << Row;
            }
        }

        // Proof bookkeeping
        bool AllAsleep = true;
        for (size_t Index = 0; Index < Poses.size(); ++Index)
        {
            const Frontier::RigidBodyPose& P = Poses[Index];
            if (P.Motion == Frontier::RigidBodyMotionCategory::Static) continue;
            if (P.Active) AllAsleep = false;
            // Poses are in creation order; the ground is first, so Descriptions[Identity − 1] is this body's description.
            if (P.Identity >= 1u && P.Identity - 1u < Descriptions.size())
            {
                const float Clearance = P.Position.z - InscribedRadius(Descriptions[P.Identity - 1u]);
                if (Clearance < MinimumFloorClearance)
                {
                    MinimumFloorClearance = Clearance;
                    WorstClearanceBody    = Solver.QueryName(P.Identity);
                    WorstClearanceTime    = Elapsed;
                }
            }
        }
        if (!WitnessSampled && Elapsed >= 0.5f)
        {
            Frontier::RigidBodyPose W;
            if (Solver.QueryPose(Witness, W)) WitnessDrop = WitnessStart.Position.z - W.Position.z;
            WitnessSampled = true;
            char Line[160];
            std::snprintf(Line, sizeof(Line), "Free-fall witness %s after %.3f s: dropped %.3f m (analytic ½gt² = %.3f m)",
                          Solver.QueryName(Witness).c_str(), Elapsed, WitnessDrop, 0.5f * 9.81f * Elapsed * Elapsed);
            Logger.RecordMessage(Frontier::DiagnosticSeverity::Information, "Proof", Line);
        }
        if (AllAsleep && Elapsed > 1.0f)
        {
            if (AllAsleepSince < 0.0f) AllAsleepSince = Elapsed;
        }
        else AllAsleepSince = -1.0f;

        if (!Quiet && Elapsed >= NextPrintTime)
        {
            PrintPoseTable(Elapsed);
            NextPrintTime += 0.5f;
        }

        // Every body has been asleep for half a second: the drop has settled, nothing left to simulate.
        if (AllAsleepSince >= 0.0f && Elapsed - AllAsleepSince >= 0.5f) break;

        // Pacing: poll at ~120 Hz so the 60 Hz accumulator sees a steady stream of small Δτ (no pacing in fixed mode).
        if (!FixedStepTick) std::this_thread::sleep_until(NowTime + std::chrono::microseconds(8333));
    }

    //──────────────────────────────────────────────────────────────────────────
    // Summary + proof verdict
    //──────────────────────────────────────────────────────────────────────────
    if (!Quiet) PrintPoseTable(Elapsed);

    const Frontier::RigidBodyMetrics& M = Solver.QueryMetrics();
    Solver.QueryPoses(Poses);
    for (const Frontier::RigidBodyPose& P : Poses)
        if (P.Motion != Frontier::RigidBodyMotionCategory::Static && P.Identity >= 1u && P.Identity - 1u < Descriptions.size())
            SettledFloorClearance = std::min(SettledFloorClearance, P.Position.z - InscribedRadius(Descriptions[P.Identity - 1u]));

    const float ExpectedDrop   = 0.5f * 9.81f * 0.5f * 0.5f;   // [m] the witness sample is taken at the first tick past 0.5 s
    const bool  FreeFallOk     = WitnessSampled && std::fabs(WitnessDrop - ExpectedDrop) <= 0.15f * ExpectedDrop + 0.05f;   // 60 Hz symplectic Euler + damping ≈ +3 %
    const bool  NoTunnelling   = SettledFloorClearance > -(SolverConfig.PenetrationSlop + 0.01f);   // [m] resting bodies sink by at most the slop
    const bool  Settled        = AllAsleepSince >= 0.0f;

    char Line[256];
    std::snprintf(Line, sizeof(Line), "%u ticks, %llu fixed steps in %.2f s simulated, %.3f s dropped by the hitch guard, last step %.3f ms, %u bodies resident",
                  TickCount, static_cast<unsigned long long>(M.StepCount), Elapsed, M.DroppedSeconds, M.LastStepMilliseconds, M.BodyCount);
    Logger.RecordMessage(Frontier::DiagnosticSeverity::Information, "Summary", Line);
    std::snprintf(Line, sizeof(Line), "free fall %s (%.3f m vs %.3f m)  |  settled floor clearance %.4f m %s (transient dip %.3f m, %s at %.2f s)  |  %s",
                  FreeFallOk ? "OK" : "FAILED", WitnessDrop, ExpectedDrop, SettledFloorClearance, NoTunnelling ? "OK" : "TUNNELLED",
                  MinimumFloorClearance, WorstClearanceBody.c_str(), WorstClearanceTime,
                  Settled ? "all bodies asleep - settled" : "still moving at the time budget");
    Logger.RecordMessage(FreeFallOk && NoTunnelling ? Frontier::DiagnosticSeverity::Information : Frontier::DiagnosticSeverity::Refusal, "Proof", Line);

    //──────────────────────────────────────────────────────────────────────────
    // Shutdown
    //──────────────────────────────────────────────────────────────────────────
    Solver.Retire();
    Logger.RecordMessage(Frontier::DiagnosticSeverity::Information, "Shutdown", "Main loop exited cleanly.");
    Logger.TerminateSink();

    return (FreeFallOk && NoTunnelling) ? 0 : 2;
}
