//============================================================================================================================================
// 📦 Frontier/PhysicalDynamics/RigidBodySolver.cpp — Jolt Rigid-Body World Implementation (the only translation unit that sees JPH::)
//============================================================================================================================================

#include "RigidBodySolver.h"

// Jolt.h must precede every other Jolt header; the library derives its feature/ISA defines from the compiler flags, so this
//    translation unit has to be compiled with the same -m<isa> / NDEBUG set as libJolt (see Scripts/BuildJolt.*).
#include <Jolt/Jolt.h>
#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyInterface.h>
#include <Jolt/Physics/Collision/BroadPhase/BroadPhaseLayerInterfaceTable.h>
#include <Jolt/Physics/Collision/BroadPhase/ObjectVsBroadPhaseLayerFilterTable.h>
#include <Jolt/Physics/Collision/ObjectLayerPairFilterTable.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/CylinderShape.h>
#include <Jolt/Physics/Collision/Shape/PlaneShape.h>
#include <Jolt/Physics/Collision/Shape/RotatedTranslatedShape.h>

#include <algorithm>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <mutex>
#include <thread>

JPH_SUPPRESS_WARNINGS

namespace Frontier {

//------------------------------------------------------------------------------------------------------------------------
//                                          PROCESS-WIDE JOLT REGISTRATION
//------------------------------------------------------------------------------------------------------------------------
// Jolt's factory and type registry are global; several solvers may coexist (editor preview + game world), so the first
//    Bring() registers and the last Retire() unregisters.

namespace {

std::mutex   RegistrationMutex;
uint32_t     RegistrationCount = 0u;

void JoltTrace(const char* Format, ...)
{
    va_list Arguments;
    va_start(Arguments, Format);
    char Line[1024];
    std::vsnprintf(Line, sizeof(Line), Format, Arguments);
    va_end(Arguments);
    std::fprintf(stderr, "[Jolt] %s\n", Line);
}

#ifdef JPH_ENABLE_ASSERTS
bool JoltAssertFailed(const char* Expression, const char* Message, const char* File, JPH::uint Line)
{
    std::fprintf(stderr, "[Jolt] %s:%u: (%s) %s\n", File, Line, Expression, Message != nullptr ? Message : "");
    return true;   // break into the debugger
}
#endif

bool RegisterJolt() noexcept
{
    std::lock_guard<std::mutex> Guard(RegistrationMutex);
    if (RegistrationCount++ > 0u) return true;

    JPH::RegisterDefaultAllocator();
    JPH::Trace = JoltTrace;
    JPH_IF_ENABLE_ASSERTS(JPH::AssertFailed = JoltAssertFailed;)
    JPH::Factory::sInstance = new JPH::Factory();
    JPH::RegisterTypes();   // aborts with a trace when libJolt and this TU were compiled with different defines
    return JPH::Factory::sInstance != nullptr;
}

void UnregisterJolt() noexcept
{
    std::lock_guard<std::mutex> Guard(RegistrationMutex);
    if (RegistrationCount == 0u || --RegistrationCount > 0u) return;

    JPH::UnregisterTypes();
    delete JPH::Factory::sInstance;
    JPH::Factory::sInstance = nullptr;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                  LAYER SCHEME
//------------------------------------------------------------------------------------------------------------------------
// Two object layers, two broad-phase trees: static geometry never has to be re-inserted when dynamic bodies move.

namespace ObjectLayers
{
    constexpr JPH::ObjectLayer NonMoving = 0;
    constexpr JPH::ObjectLayer Moving    = 1;
    constexpr JPH::uint        Count     = 2;
}

namespace BroadPhaseLayers
{
    constexpr JPH::BroadPhaseLayer NonMoving(0);
    constexpr JPH::BroadPhaseLayer Moving(1);
    constexpr JPH::uint            Count = 2;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                 TYPE CONVERSION
//------------------------------------------------------------------------------------------------------------------------

inline JPH::Vec3    ToJolt(const Vector3& V) noexcept        { return JPH::Vec3(V.x, V.y, V.z); }
inline JPH::RVec3   ToJoltReal(const Vector3& V) noexcept    { return JPH::RVec3(JPH::Real(V.x), JPH::Real(V.y), JPH::Real(V.z)); }
inline JPH::Quat    ToJolt(const Quaternion& Q) noexcept     { const JPH::Quat J(Q.x, Q.y, Q.z, Q.w); return J.IsNormalized() ? J : J.Normalized(); }
inline Vector3      FromJolt(JPH::Vec3Arg V) noexcept        { return Vector3{ V.GetX(), V.GetY(), V.GetZ() }; }
#ifdef JPH_DOUBLE_PRECISION
inline Vector3      FromJolt(JPH::RVec3Arg V) noexcept       { return Vector3{ float(V.GetX()), float(V.GetY()), float(V.GetZ()) }; }
#endif
inline Quaternion   FromJolt(JPH::QuatArg Q) noexcept        { return Quaternion{ Q.GetX(), Q.GetY(), Q.GetZ(), Q.GetW() }; }

inline JPH::EMotionType ToJolt(RigidBodyMotionCategory M) noexcept
{
    switch (M)
    {
        case RigidBodyMotionCategory::Static:    return JPH::EMotionType::Static;
        case RigidBodyMotionCategory::Kinematic: return JPH::EMotionType::Kinematic;
        default:                                 return JPH::EMotionType::Dynamic;
    }
}

// Frontier is +Z up; Jolt's capsule and cylinder run along their local +Y, so those two are wrapped in a +90° rotation about X
//    (local Y → local Z). Returns a null ref with an explanation when the description is unusable.
JPH::ShapeRefC BuildShape(const CollisionShapeDescription& D, std::string& Refusal) noexcept
{
    constexpr float MinimumSize = 1.0e-4f;   // [m] below this Jolt's convex radius logic degenerates
    JPH::ShapeSettings::ShapeResult Result;
    switch (D.Category)
    {
        case CollisionShapeCategory::Plane:
        {
            const Vector3 N = D.PlaneNormal.Normalized();
            if (N.LengthSquared() < 0.5f) { Refusal = "plane normal is zero"; return nullptr; }
            JPH::PlaneShapeSettings S(JPH::Plane(ToJolt(N), -D.PlaneOffset), nullptr, std::max(1.0f, D.PlaneHalfExtent));
            S.SetEmbedded();
            Result = S.Create();
            break;
        }
        case CollisionShapeCategory::Box:
        {
            if (std::min({ D.HalfExtents.x, D.HalfExtents.y, D.HalfExtents.z }) < MinimumSize) { Refusal = "box half extents must be positive"; return nullptr; }
            const float ConvexRadius = std::min(JPH::cDefaultConvexRadius, 0.5f * std::min({ D.HalfExtents.x, D.HalfExtents.y, D.HalfExtents.z }));
            JPH::BoxShapeSettings S(ToJolt(D.HalfExtents), ConvexRadius);
            S.SetEmbedded();
            Result = S.Create();
            break;
        }
        case CollisionShapeCategory::Sphere:
        {
            if (D.Radius < MinimumSize) { Refusal = "sphere radius must be positive"; return nullptr; }
            JPH::SphereShapeSettings S(D.Radius);
            S.SetEmbedded();
            Result = S.Create();
            break;
        }
        case CollisionShapeCategory::Capsule:
        case CollisionShapeCategory::Cylinder:
        {
            if (D.Radius < MinimumSize || D.HalfHeight < MinimumSize) { Refusal = "capsule/cylinder radius and half height must be positive"; return nullptr; }
            JPH::Ref<JPH::ShapeSettings> Axial;
            if (D.Category == CollisionShapeCategory::Capsule)
                Axial = new JPH::CapsuleShapeSettings(D.HalfHeight, D.Radius);
            else
                Axial = new JPH::CylinderShapeSettings(D.HalfHeight, D.Radius, std::min(JPH::cDefaultConvexRadius, 0.5f * std::min(D.Radius, D.HalfHeight)));
            JPH::RotatedTranslatedShapeSettings S(JPH::Vec3::sZero(), JPH::Quat::sRotation(JPH::Vec3::sAxisX(), 0.5f * JPH::JPH_PI), Axial);
            S.SetEmbedded();
            Result = S.Create();
            break;
        }
        default:
            Refusal = "unknown collision shape category";
            return nullptr;
    }
    if (Result.HasError()) { Refusal = Result.GetError().c_str(); return nullptr; }
    return Result.Get();
}

} // namespace

//------------------------------------------------------------------------------------------------------------------------
//                                                    JOLT WORLD
//------------------------------------------------------------------------------------------------------------------------

struct RigidBodySolver::JoltWorld
{
    struct BodyRecord
    {
        JPH::BodyID             Body;                               // [-] Jolt identity (index + sequence number)
        std::string             Name;                               // [-] diagnostic label
        RigidBodyMotionCategory Motion = RigidBodyMotionCategory::Dynamic;
        CollisionShapeCategory  Shape  = CollisionShapeCategory::Box;
        bool                    Alive  = false;
    };

    // The object-vs-broad-phase table SNAPSHOTS the two tables below in its constructor, so they must be fully populated
    //    before it is built — hence a nested aggregate that is a member declared ahead of it (members initialise in order).
    struct LayerScheme
    {
        JPH::BroadPhaseLayerInterfaceTable      BroadPhaseTable;
        JPH::ObjectLayerPairFilterTable         PairTable;

        LayerScheme()
            : BroadPhaseTable(ObjectLayers::Count, BroadPhaseLayers::Count)
            , PairTable(ObjectLayers::Count)
        {
            BroadPhaseTable.MapObjectToBroadPhaseLayer(ObjectLayers::NonMoving, BroadPhaseLayers::NonMoving);
            BroadPhaseTable.MapObjectToBroadPhaseLayer(ObjectLayers::Moving,    BroadPhaseLayers::Moving);
            PairTable.EnableCollision(ObjectLayers::Moving, ObjectLayers::Moving);
            PairTable.EnableCollision(ObjectLayers::Moving, ObjectLayers::NonMoving);   // static ↔ static never collides
        }
    };

    JPH::TempAllocatorImpl                      TemporaryAllocator;
    JPH::JobSystemThreadPool                    Jobs;
    LayerScheme                                 Layers;
    JPH::ObjectVsBroadPhaseLayerFilterTable     ObjectVsBroadPhaseTable;
    JPH::PhysicsSystem                          Physics;
    std::vector<BodyRecord>                     Records;            // [-] indexed by RigidBodyIdentity; creation order
    std::vector<uint32_t>                       FreeSlots;          // [-] recycled record indices

    explicit JoltWorld(const RigidBodyConfiguration& C)
        : TemporaryAllocator(static_cast<JPH::uint>(std::max<uint32_t>(C.TemporaryAllocationBytes, 1u * 1024u * 1024u)))
        , Jobs(JPH::cMaxPhysicsJobs, JPH::cMaxPhysicsBarriers,
               C.WorkerThreads > 0u ? static_cast<int>(C.WorkerThreads)
                                    : std::max(1, static_cast<int>(std::thread::hardware_concurrency()) - 1))
        , Layers()
        , ObjectVsBroadPhaseTable(Layers.BroadPhaseTable, BroadPhaseLayers::Count, Layers.PairTable, ObjectLayers::Count)
    {
        Physics.Init(C.MaxBodies, 0u, C.MaxBodyPairs, C.MaxContactConstraints, Layers.BroadPhaseTable, ObjectVsBroadPhaseTable, Layers.PairTable);
        Physics.SetGravity(ToJolt(C.Gravity));

        JPH::PhysicsSettings Settings = Physics.GetPhysicsSettings();
        Settings.mSpeculativeContactDistance = std::max(0.0f, C.SpeculativeContactDistance);
        Settings.mPenetrationSlop            = std::max(0.0f, C.PenetrationSlop);
        Settings.mTimeBeforeSleep            = std::max(0.0f, C.TimeBeforeSleepSeconds);
        Physics.SetPhysicsSettings(Settings);
    }

    [[nodiscard]] const BodyRecord* Find(RigidBodyIdentity Identity) const noexcept
    {
        if (Identity >= Records.size() || !Records[Identity].Alive) return nullptr;
        return &Records[Identity];
    }
};

//------------------------------------------------------------------------------------------------------------------------
//                                                    LIFECYCLE
//------------------------------------------------------------------------------------------------------------------------

RigidBodySolver::RigidBodySolver() noexcept = default;

RigidBodySolver::~RigidBodySolver() noexcept
{
    Retire();
}

bool RigidBodySolver::Bring(const RigidBodyConfiguration& Configuration) noexcept
{
    if (Ready) { LastRefusal = "Bring() called twice without Retire()"; return false; }
    if (!(Configuration.FixedStepSeconds > 0.0f) || Configuration.MaxBodies == 0u)
    {
        LastRefusal = "FixedStepSeconds must be positive and MaxBodies non-zero";
        return false;
    }
    if (!RegisterJolt()) { LastRefusal = "Jolt type registration failed"; return false; }

    Config      = Configuration;
    Accumulator = 0.0f;
    Metrics     = RigidBodyMetrics{};
    World       = std::make_unique<JoltWorld>(Config);
    Ready       = true;
    LastRefusal.clear();
    return true;
}

void RigidBodySolver::Retire() noexcept
{
    if (!World) return;
    DestroyAllBodies();
    World.reset();          // PhysicsSystem, job threads and scratch go down before the global registry
    Ready = false;
    UnregisterJolt();
}

const char* RigidBodySolver::QueryBackendVersion() noexcept
{
    static char Version[32] = {};
    if (Version[0] == '\0') std::snprintf(Version, sizeof(Version), "Jolt %d.%d.%d", JPH_VERSION_MAJOR, JPH_VERSION_MINOR, JPH_VERSION_PATCH);
    return Version;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                      BODIES
//------------------------------------------------------------------------------------------------------------------------

RigidBodyIdentity RigidBodySolver::CreateBody(const RigidBodyDescription& D) noexcept
{
    if (!Ready) { LastRefusal = "solver not ready"; return InvalidRigidBody; }
    if (D.Shape.Category == CollisionShapeCategory::Plane && D.Motion != RigidBodyMotionCategory::Static)
    {
        LastRefusal = "a plane can only be a static body";
        return InvalidRigidBody;
    }

    const JPH::ShapeRefC Shape = BuildShape(D.Shape, LastRefusal);
    if (Shape == nullptr) return InvalidRigidBody;

    const bool Moving = D.Motion != RigidBodyMotionCategory::Static;
    JPH::BodyCreationSettings Settings(Shape, ToJoltReal(D.Position), ToJolt(D.Orientation), ToJolt(D.Motion),
                                       Moving ? ObjectLayers::Moving : ObjectLayers::NonMoving);
    Settings.mLinearVelocity  = ToJolt(D.LinearVelocity);
    Settings.mAngularVelocity = ToJolt(D.AngularVelocity);
    Settings.mFriction        = std::max(0.0f, D.Friction);
    Settings.mRestitution     = std::clamp(D.Restitution, 0.0f, 1.0f);
    Settings.mLinearDamping   = std::max(0.0f, D.LinearDamping);
    Settings.mAngularDamping  = std::max(0.0f, D.AngularDamping);
    Settings.mGravityFactor   = D.GravityFactor;
    Settings.mAllowSleeping   = D.AllowSleeping;
    Settings.mMotionQuality   = D.ContinuousCollision ? JPH::EMotionQuality::LinearCast : JPH::EMotionQuality::Discrete;
    if (D.Motion == RigidBodyMotionCategory::Dynamic && D.MassKilograms > 0.0f)
    {
        Settings.mOverrideMassProperties       = JPH::EOverrideMassProperties::CalculateInertia;   // inertia from the shape, scaled to the given mass
        Settings.mMassPropertiesOverride.mMass = D.MassKilograms;
    }

    JPH::BodyInterface& Bodies = World->Physics.GetBodyInterface();
    const JPH::BodyID Body = Bodies.CreateAndAddBody(Settings, Moving ? JPH::EActivation::Activate : JPH::EActivation::DontActivate);
    if (Body.IsInvalid())
    {
        LastRefusal = "Jolt refused the body (MaxBodies reached?)";
        return InvalidRigidBody;
    }

    uint32_t Slot;
    if (!World->FreeSlots.empty()) { Slot = World->FreeSlots.back(); World->FreeSlots.pop_back(); }
    else                           { Slot = static_cast<uint32_t>(World->Records.size()); World->Records.emplace_back(); }

    JoltWorld::BodyRecord& R = World->Records[Slot];
    R.Body   = Body;
    R.Name   = D.Name;
    R.Motion = D.Motion;
    R.Shape  = D.Shape.Category;
    R.Alive  = true;
    Bodies.SetUserData(Body, Slot);

    Metrics.BodyCount = World->Physics.GetNumBodies();
    return Slot;
}

void RigidBodySolver::DestroyBody(RigidBodyIdentity Identity) noexcept
{
    if (!Ready) return;
    const JoltWorld::BodyRecord* R = World->Find(Identity);
    if (R == nullptr) return;

    JPH::BodyInterface& Bodies = World->Physics.GetBodyInterface();
    if (Bodies.IsAdded(R->Body)) Bodies.RemoveBody(R->Body);
    Bodies.DestroyBody(R->Body);

    World->Records[Identity] = JoltWorld::BodyRecord{};
    World->FreeSlots.push_back(Identity);
    Metrics.BodyCount = World->Physics.GetNumBodies();
}

void RigidBodySolver::DestroyAllBodies() noexcept
{
    if (!World) return;
    JPH::BodyInterface& Bodies = World->Physics.GetBodyInterface();
    for (const JoltWorld::BodyRecord& R : World->Records)
    {
        if (!R.Alive) continue;
        if (Bodies.IsAdded(R.Body)) Bodies.RemoveBody(R.Body);
        Bodies.DestroyBody(R.Body);
    }
    World->Records.clear();
    World->FreeSlots.clear();
    Metrics.BodyCount = World->Physics.GetNumBodies();
}

void RigidBodySolver::OptimizeBroadPhase() noexcept
{
    if (Ready) World->Physics.OptimizeBroadPhase();
}

//------------------------------------------------------------------------------------------------------------------------
//                                                       TICK
//------------------------------------------------------------------------------------------------------------------------

void RigidBodySolver::Advance(float Δτ) noexcept
{
    Metrics.StepsLastAdvance = 0u;
    if (!Ready || !(Δτ > 0.0f)) return;

    Accumulator += Δτ;

    // Spiral-of-death guard: a hitch longer than MaxStepsPerAdvance steps is dropped rather than replayed.
    const float BacklogLimit = Config.FixedStepSeconds * static_cast<float>(std::max(1u, Config.MaxStepsPerAdvance));
    if (Accumulator > BacklogLimit)
    {
        Metrics.DroppedSeconds += Accumulator - BacklogLimit;
        Accumulator = BacklogLimit;
    }

    using Clock = std::chrono::steady_clock;
    while (Accumulator >= Config.FixedStepSeconds)
    {
        const auto Start = Clock::now();
        const JPH::EPhysicsUpdateError Error = World->Physics.Update(Config.FixedStepSeconds,
                                                                     static_cast<int>(std::max(1u, Config.CollisionStepsPerUpdate)),
                                                                     &World->TemporaryAllocator, &World->Jobs);
        Metrics.LastStepMilliseconds = std::chrono::duration<float, std::milli>(Clock::now() - Start).count();
        if (Error != JPH::EPhysicsUpdateError::None)
        {
            char Line[128];
            std::snprintf(Line, sizeof(Line), "physics update error 0x%X (raise MaxBodyPairs / MaxContactConstraints / TemporaryAllocationBytes)",
                          static_cast<unsigned>(Error));
            LastRefusal = Line;
        }
        Accumulator -= Config.FixedStepSeconds;
        ++Metrics.StepCount;
        ++Metrics.StepsLastAdvance;
    }

    Metrics.AccumulatorSeconds = Accumulator;
    Metrics.BodyCount          = World->Physics.GetNumBodies();
    Metrics.ActiveBodyCount    = World->Physics.GetNumActiveBodies(JPH::EBodyType::RigidBody);
}

float RigidBodySolver::QueryInterpolationAlpha() const noexcept
{
    return Config.FixedStepSeconds > 0.0f ? std::clamp(Accumulator / Config.FixedStepSeconds, 0.0f, 1.0f) : 0.0f;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                    INTERACTION
//------------------------------------------------------------------------------------------------------------------------

void RigidBodySolver::ApplyImpulse(RigidBodyIdentity Identity, const Vector3& Impulse) noexcept
{
    if (!Ready) return;
    if (const JoltWorld::BodyRecord* R = World->Find(Identity); R != nullptr && R->Motion == RigidBodyMotionCategory::Dynamic)
        World->Physics.GetBodyInterface().AddImpulse(R->Body, ToJolt(Impulse));
}

void RigidBodySolver::AssignLinearVelocity(RigidBodyIdentity Identity, const Vector3& Velocity) noexcept
{
    if (!Ready) return;
    if (const JoltWorld::BodyRecord* R = World->Find(Identity); R != nullptr && R->Motion != RigidBodyMotionCategory::Static)
        World->Physics.GetBodyInterface().SetLinearVelocity(R->Body, ToJolt(Velocity));
}

void RigidBodySolver::Teleport(RigidBodyIdentity Identity, const Vector3& Position, const Quaternion& Orientation) noexcept
{
    if (!Ready) return;
    if (const JoltWorld::BodyRecord* R = World->Find(Identity); R != nullptr)
    {
        JPH::BodyInterface& Bodies = World->Physics.GetBodyInterface();
        Bodies.SetPositionAndRotation(R->Body, ToJoltReal(Position), ToJolt(Orientation),
                                      R->Motion == RigidBodyMotionCategory::Static ? JPH::EActivation::DontActivate : JPH::EActivation::Activate);
        if (R->Motion == RigidBodyMotionCategory::Dynamic)
        {
            Bodies.SetLinearAndAngularVelocity(R->Body, JPH::Vec3::sZero(), JPH::Vec3::sZero());
        }
    }
}

void RigidBodySolver::MoveKinematic(RigidBodyIdentity Identity, const Vector3& Position, const Quaternion& Orientation, float Δτ) noexcept
{
    if (!Ready || !(Δτ > 0.0f)) return;
    if (const JoltWorld::BodyRecord* R = World->Find(Identity); R != nullptr && R->Motion == RigidBodyMotionCategory::Kinematic)
        World->Physics.GetBodyInterface().MoveKinematic(R->Body, ToJoltReal(Position), ToJolt(Orientation), Δτ);
}

void RigidBodySolver::Activate(RigidBodyIdentity Identity) noexcept
{
    if (!Ready) return;
    if (const JoltWorld::BodyRecord* R = World->Find(Identity); R != nullptr && R->Motion != RigidBodyMotionCategory::Static)
        World->Physics.GetBodyInterface().ActivateBody(R->Body);
}

//------------------------------------------------------------------------------------------------------------------------
//                                                      READBACK
//------------------------------------------------------------------------------------------------------------------------

bool RigidBodySolver::QueryPose(RigidBodyIdentity Identity, RigidBodyPose& Pose) const noexcept
{
    if (!Ready) return false;
    const JoltWorld::BodyRecord* R = World->Find(Identity);
    if (R == nullptr) return false;

    const JPH::BodyInterface& Bodies = World->Physics.GetBodyInterface();
    JPH::RVec3 Position; JPH::Quat Orientation;
    Bodies.GetPositionAndRotation(R->Body, Position, Orientation);

    Pose.Identity        = Identity;
    Pose.Position        = FromJolt(Position);
    Pose.Orientation     = FromJolt(Orientation);
    Pose.LinearVelocity  = R->Motion == RigidBodyMotionCategory::Static ? Vector3{} : FromJolt(Bodies.GetLinearVelocity(R->Body));
    Pose.AngularVelocity = R->Motion == RigidBodyMotionCategory::Static ? Vector3{} : FromJolt(Bodies.GetAngularVelocity(R->Body));
    Pose.Motion          = R->Motion;
    Pose.Shape           = R->Shape;
    Pose.Active          = Bodies.IsActive(R->Body);
    return true;
}

void RigidBodySolver::QueryPoses(std::vector<RigidBodyPose>& Poses) const noexcept
{
    Poses.clear();
    if (!Ready) return;
    Poses.reserve(World->Records.size());
    for (uint32_t Index = 0; Index < World->Records.size(); ++Index)
    {
        if (!World->Records[Index].Alive) continue;
        RigidBodyPose Pose;
        if (QueryPose(Index, Pose)) Poses.push_back(Pose);
    }
}

const std::string& RigidBodySolver::QueryName(RigidBodyIdentity Identity) const noexcept
{
    static const std::string Empty;
    if (!Ready) return Empty;
    const JoltWorld::BodyRecord* R = World->Find(Identity);
    return R != nullptr ? R->Name : Empty;
}

} // namespace Frontier
