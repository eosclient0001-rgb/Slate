//============================================================================================================================================
// 📦 Project-Physics/Source/DropSceneStructure.cpp — Drop Scene Construction
//============================================================================================================================================

#include "DropSceneStructure.h"

#include <cmath>
#include <cstdio>

namespace Frontier::ProjectPhysics {

//------------------------------------------------------------------------------------------------------------------------
//                                                    CONSTRUCTION
//------------------------------------------------------------------------------------------------------------------------

bool DropSceneStructure::Construct(RigidBodySolver& Solver, const DropSceneConfiguration& C) noexcept
{
    Bodies.clear();
    Descriptions.clear();

    // Ground: an infinite half-space with +Z as its normal through the origin (Frontier is +Z up).
    {
        RigidBodyDescription Plane;
        Plane.Name                  = "Ground";
        Plane.Motion                = RigidBodyMotionCategory::Static;
        Plane.Shape.Category        = CollisionShapeCategory::Plane;
        Plane.Shape.PlaneNormal     = Vector3{ 0.0f, 0.0f, 1.0f };
        Plane.Shape.PlaneOffset     = 0.0f;
        Plane.Shape.PlaneHalfExtent = C.PlaneHalfExtent;
        Plane.Friction              = C.PlaneFriction;
        Plane.Restitution           = 0.0f;
        Ground = Solver.CreateBody(Plane);
        if (Ground == InvalidRigidBody) return false;
    }

    char Name[32];

    // Boxes: a slightly rotated column over the origin so the stack topples rather than balancing perfectly.
    for (uint32_t Index = 0; Index < C.BoxCount; ++Index)
    {
        RigidBodyDescription D;
        std::snprintf(Name, sizeof(Name), "Box%02u", Index);
        D.Name              = Name;
        D.Shape.Category    = CollisionShapeCategory::Box;
        D.Shape.HalfExtents = Vector3{ 0.5f, 0.5f, 0.5f };
        D.Position          = Vector3{ 0.0f, 0.0f, C.DropHeight + static_cast<float>(Index) * C.Spacing };
        const float Yaw     = 0.15f * static_cast<float>(Index);                                    // [rad]
        D.Orientation       = Quaternion{ 0.0f, 0.0f, std::sin(0.5f * Yaw), std::cos(0.5f * Yaw) };
        D.MassKilograms     = 10.0f;
        D.Friction          = 0.5f;
        D.Restitution       = C.BodyRestitution;
        Descriptions.push_back(D);
    }

    // Spheres: to the +X side, staggered in Y so they roll apart. The stagger wraps every 8 bodies so a stress run with
    //    hundreds of spheres still spawns over the plane (the vertical spacing keeps wrapped bodies from overlapping).
    for (uint32_t Index = 0; Index < C.SphereCount; ++Index)
    {
        RigidBodyDescription D;
        std::snprintf(Name, sizeof(Name), "Sphere%02u", Index);
        D.Name              = Name;
        D.Shape.Category    = CollisionShapeCategory::Sphere;
        D.Shape.Radius      = 0.4f;
        D.Position          = Vector3{ 2.5f, 0.3f * static_cast<float>(Index % 8u), C.DropHeight + static_cast<float>(Index) * C.Spacing };
        D.MassKilograms     = 5.0f;
        D.Friction          = 0.4f;
        D.Restitution       = C.BodyRestitution + 0.3f;   // spheres bounce more than boxes
        D.AngularDamping    = 1.0f;                       // rolling resistance stand-in: a sphere on a plane never stops otherwise
        D.ContinuousCollision = true;                     // linear cast — engages once a step would move the sphere > ¾ of its radius
        Descriptions.push_back(D);
    }

    // Capsules: to the −X side, lying along Y (the solver's capsule axis is local Z; tip them over 90° about X).
    for (uint32_t Index = 0; Index < C.CapsuleCount; ++Index)
    {
        RigidBodyDescription D;
        std::snprintf(Name, sizeof(Name), "Capsule%02u", Index);
        D.Name              = Name;
        D.Shape.Category    = CollisionShapeCategory::Capsule;
        D.Shape.Radius      = 0.3f;
        D.Shape.HalfHeight  = 0.6f;
        D.Position          = Vector3{ -2.5f, 0.0f, C.DropHeight + static_cast<float>(Index) * C.Spacing };
        const float Roll    = 1.5707963f + 0.2f * static_cast<float>(Index);                        // [rad]
        D.Orientation       = Quaternion{ std::sin(0.5f * Roll), 0.0f, 0.0f, std::cos(0.5f * Roll) };
        D.MassKilograms     = 4.0f;
        D.Friction          = 0.5f;
        D.Restitution       = C.BodyRestitution;
        Descriptions.push_back(D);
    }

    Bodies.reserve(Descriptions.size());
    for (const RigidBodyDescription& D : Descriptions)
    {
        const RigidBodyIdentity Identity = Solver.CreateBody(D);
        if (Identity == InvalidRigidBody) return false;
        Bodies.push_back(Identity);
    }

    Solver.OptimizeBroadPhase();   // once, after the batch — never per frame
    return true;
}

void DropSceneStructure::Reset(RigidBodySolver& Solver) noexcept
{
    for (size_t Index = 0; Index < Bodies.size() && Index < Descriptions.size(); ++Index)
    {
        Solver.Teleport(Bodies[Index], Descriptions[Index].Position, Descriptions[Index].Orientation);
        Solver.Activate(Bodies[Index]);
    }
}

} // namespace Frontier::ProjectPhysics
