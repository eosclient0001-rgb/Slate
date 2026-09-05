//============================================================================================================================================
// 📦 Frontier/PhysicalDynamics/RigidBodySolver.h — Jolt Rigid-Body World, Fixed-Step Accumulator and Backend-Neutral Body Records
//============================================================================================================================================
//
//    The solver owns one Jolt PhysicsSystem behind an opaque seam: no JPH:: type is visible to a project. A game creates bodies
//    from RigidBodyDescription records, calls Advance(Δτ) once per tick from its main loop, then reads RigidBodyPose records
//    back for rendering. Time is accumulated and the world is stepped at a fixed 60 Hz (configurable) so the simulation is
//    frame-rate independent; the remainder is exposed as an interpolation α for smooth presentation.
//
//    Coordinates: Frontier is right-handed +Z up in metres — Jolt is axis-agnostic, so gravity is simply (0, 0, -9.81) and no
//    basis change is performed anywhere.

#pragma once

#include "../DeviceExchange/OrientationClassifier.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace Frontier {

//------------------------------------------------------------------------------------------------------------------------
//                                                RIGID BODY CATEGORIES
//------------------------------------------------------------------------------------------------------------------------

enum class RigidBodyMotionCategory : uint8_t
{
    Static                              = 0,                    // never moves, collides with dynamic bodies only
    Kinematic                           = 1,                    // moved by the game, pushes dynamic bodies
    Dynamic                             = 2                     // simulated: gravity, contacts, impulses
};

enum class CollisionShapeCategory : uint8_t
{
    Plane                               = 0,                    // half-space, FINITE in the broad phase (PlaneHalfExtent) — the ground
    Box                                 = 1,                    // axis-aligned half extents
    Sphere                              = 2,                    // radius
    Capsule                             = 3,                    // half height + radius along local Z
    Cylinder                            = 4                     // half height + radius along local Z
};

//------------------------------------------------------------------------------------------------------------------------
//                                                RIGID BODY DESCRIPTION
//------------------------------------------------------------------------------------------------------------------------

struct CollisionShapeDescription
{
    CollisionShapeCategory  Category        = CollisionShapeCategory::Box;
    Vector3                 HalfExtents     { 0.5f, 0.5f, 0.5f };   // [m]   Box half sizes
    float                   Radius          = 0.5f;                 // [m]   Sphere / Capsule / Cylinder
    float                   HalfHeight      = 0.5f;                 // [m]   Capsule / Cylinder half length (excluding caps)
    Vector3                 PlaneNormal     { 0.0f, 0.0f, 1.0f };   // [-]   Plane: unit normal
    float                   PlaneOffset     = 0.0f;                 // [m]   Plane: signed distance along the normal
    float                   PlaneHalfExtent = 500.0f;               // [m]   Plane: broad-phase bounds — a body beyond them falls past the plane
};

struct RigidBodyDescription
{
    std::string             Name;                                   // [-]   diagnostic label carried into RigidBodyPose
    CollisionShapeDescription Shape;
    RigidBodyMotionCategory Motion          = RigidBodyMotionCategory::Dynamic;
    Vector3                 Position        { 0.0f, 0.0f, 0.0f };   // [m]
    Quaternion              Orientation     = Quaternion::Identity();
    Vector3                 LinearVelocity  { 0.0f, 0.0f, 0.0f };   // [m/s]
    Vector3                 AngularVelocity { 0.0f, 0.0f, 0.0f };   // [rad/s]
    float                   MassKilograms   = 0.0f;                 // [kg]  0 = derive from shape volume × 1000 kg/m³
    float                   Friction        = 0.5f;                 // [-]
    float                   Restitution     = 0.1f;                 // [-]
    float                   LinearDamping   = 0.05f;                // [1/s]
    float                   AngularDamping  = 0.05f;                // [1/s]
    float                   GravityFactor   = 1.0f;                 // [-]
    bool                    AllowSleeping   = true;                 // [bool]
    bool                    ContinuousCollision = false;            // [bool] linear-cast motion quality for fast small bodies
};

//------------------------------------------------------------------------------------------------------------------------
//                                                  RIGID BODY POSE
//------------------------------------------------------------------------------------------------------------------------

using RigidBodyIdentity = uint32_t;                                 // opaque; 0xFFFFFFFF = invalid
constexpr RigidBodyIdentity InvalidRigidBody = 0xFFFFFFFFu;

struct RigidBodyPose
{
    RigidBodyIdentity       Identity        = InvalidRigidBody;
    Vector3                 Position;                               // [m]   world-space centre of mass
    Quaternion              Orientation;                            // [-]   world-space rotation
    Vector3                 LinearVelocity;                         // [m/s]
    Vector3                 AngularVelocity;                        // [rad/s]
    RigidBodyMotionCategory Motion          = RigidBodyMotionCategory::Dynamic;
    CollisionShapeCategory  Shape           = CollisionShapeCategory::Box;
    bool                    Active          = false;                // [bool] false once Jolt has put the body to sleep
};

//------------------------------------------------------------------------------------------------------------------------
//                                              RIGID BODY CONFIGURATION
//------------------------------------------------------------------------------------------------------------------------

struct RigidBodyConfiguration
{
    Vector3                 Gravity                 { 0.0f, 0.0f, -9.81f }; // [m/s²] +Z up
    float                   FixedStepSeconds        = 1.0f / 60.0f;         // [s]    simulation step; Advance() accumulates towards it
    uint32_t                MaxStepsPerAdvance      = 4u;                   // [-]    spiral-of-death guard: extra time is dropped
    uint32_t                CollisionStepsPerUpdate = 1u;                   // [-]    Jolt sub-steps per fixed step
    uint32_t                MaxBodies               = 4096u;                // [-]
    uint32_t                MaxBodyPairs            = 4096u;                // [-]
    uint32_t                MaxContactConstraints   = 4096u;                // [-]
    uint32_t                WorkerThreads           = 0u;                   // [-]    0 = hardware_concurrency − 1 (min 1)
    uint32_t                TemporaryAllocationBytes= 16u * 1024u * 1024u;  // [B]    Jolt per-update scratch
    float                   SpeculativeContactDistance = 0.02f;             // [m]    contact look-ahead; a body moving faster than
                                                                            //        this per step lands up to (v·Δt − this) deep for
                                                                            //        one step before the solver pushes it out
    float                   PenetrationSlop         = 0.02f;                // [m]    resting interpenetration the solver tolerates
    float                   TimeBeforeSleepSeconds  = 0.5f;                 // [s]    stillness required before a body sleeps
};

//------------------------------------------------------------------------------------------------------------------------
//                                                RIGID BODY METRICS
//------------------------------------------------------------------------------------------------------------------------

struct RigidBodyMetrics
{
    uint32_t                BodyCount               = 0u;           // [-]    bodies currently resident
    uint32_t                ActiveBodyCount         = 0u;           // [-]    awake dynamic / kinematic bodies after the last step
    uint64_t                StepCount               = 0u;           // [-]    fixed steps executed since Bring()
    uint32_t                StepsLastAdvance        = 0u;           // [-]    fixed steps executed by the last Advance()
    float                   LastStepMilliseconds    = 0.0f;         // [ms]   wall time of the last fixed step
    float                   AccumulatorSeconds      = 0.0f;         // [s]    time carried into the next Advance()
    float                   DroppedSeconds          = 0.0f;         // [s]    total time discarded by the spiral-of-death guard
};

//------------------------------------------------------------------------------------------------------------------------
//                                                  RIGID BODY SOLVER
//------------------------------------------------------------------------------------------------------------------------

class RigidBodySolver
{
public:
    RigidBodySolver() noexcept;
    ~RigidBodySolver() noexcept;

    RigidBodySolver(const RigidBodySolver&) = delete;
    RigidBodySolver& operator=(const RigidBodySolver&) = delete;

    // Lifecycle — Bring() registers Jolt's factory/types once per process, allocates the job system and the world.
    //    The refusal text (if any) is available through QueryLastRefusal().
    [[nodiscard]] bool      Bring(const RigidBodyConfiguration& Configuration) noexcept;
    void                    Retire() noexcept;
    [[nodiscard]] bool      IsReady() const noexcept { return Ready; }

    // Bodies — creation returns an identity stable for the body's lifetime; InvalidRigidBody on refusal.
    [[nodiscard]] RigidBodyIdentity CreateBody(const RigidBodyDescription& Description) noexcept;
    void                    DestroyBody(RigidBodyIdentity Identity) noexcept;
    void                    DestroyAllBodies() noexcept;
    void                    OptimizeBroadPhase() noexcept;          // call once after a batch of static bodies, never per frame

    // Tick — call once per main-loop iteration with the frame's Δτ. Steps the world zero or more times at the fixed rate.
    void                    Advance(float Δτ) noexcept;

    // Interaction (dynamic bodies only)
    void                    ApplyImpulse(RigidBodyIdentity Identity, const Vector3& ImpulseNewtonSeconds) noexcept;
    void                    AssignLinearVelocity(RigidBodyIdentity Identity, const Vector3& Velocity) noexcept;
    void                    Teleport(RigidBodyIdentity Identity, const Vector3& Position, const Quaternion& Orientation) noexcept;
    void                    MoveKinematic(RigidBodyIdentity Identity, const Vector3& Position, const Quaternion& Orientation, float Δτ) noexcept;
    void                    Activate(RigidBodyIdentity Identity) noexcept;

    // Readback
    [[nodiscard]] bool      QueryPose(RigidBodyIdentity Identity, RigidBodyPose& Pose) const noexcept;
    void                    QueryPoses(std::vector<RigidBodyPose>& Poses) const noexcept;     // every resident body, creation order
    [[nodiscard]] const std::string& QueryName(RigidBodyIdentity Identity) const noexcept;
    [[nodiscard]] const RigidBodyMetrics& QueryMetrics() const noexcept { return Metrics; }
    [[nodiscard]] const RigidBodyConfiguration& QueryConfiguration() const noexcept { return Config; }
    [[nodiscard]] float     QueryInterpolationAlpha() const noexcept;   // [0..1] accumulator ÷ fixed step, for render interpolation
    [[nodiscard]] const std::string& QueryLastRefusal() const noexcept { return LastRefusal; }
    [[nodiscard]] static const char* QueryBackendVersion() noexcept;    // "Jolt 5.6.1"

    // Single unified conversion accessor: bool → IsReady, uint32_t → BodyCount, uint64_t → StepCount
    template<typename TargetType>
    [[nodiscard]] TargetType Convert() const noexcept;

private:
    struct JoltWorld;                                               // Jolt-owning implementation, defined in the .cpp only
    std::unique_ptr<JoltWorld> World;

    RigidBodyConfiguration  Config;                                 // [config] applied at Bring()
    RigidBodyMetrics        Metrics;                                // [metrics] refreshed by Advance()
    float                   Accumulator = 0.0f;                     // [s] un-simulated time carried between ticks
    bool                    Ready = false;                          // [bool] Bring() succeeded and Retire() not yet called
    std::string             LastRefusal;                            // [-] text of the last refused operation
};

template<>
inline bool RigidBodySolver::Convert<bool>() const noexcept
{
    return Ready;
}

template<>
inline uint32_t RigidBodySolver::Convert<uint32_t>() const noexcept
{
    return Metrics.BodyCount;
}

template<>
inline uint64_t RigidBodySolver::Convert<uint64_t>() const noexcept
{
    return Metrics.StepCount;
}

} // namespace Frontier
