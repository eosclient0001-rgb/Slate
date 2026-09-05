//============================================================================================================================================
// 📦 Project-Physics/Source/DropSceneStructure.h — Ground Plane plus a Column of Falling Bodies (the project's only level)
//============================================================================================================================================

#pragma once

#include "../../../Engine/PhysicalDynamics/RigidBodySolver.h"

#include <vector>

namespace Frontier::ProjectPhysics {

//------------------------------------------------------------------------------------------------------------------------
//                                                DROP SCENE CONFIGURATION
//------------------------------------------------------------------------------------------------------------------------

struct DropSceneConfiguration
{
    uint32_t                BoxCount        = 6u;                   // [-]   stacked boxes above the origin
    uint32_t                SphereCount     = 4u;                   // [-]   spheres dropped beside the stack
    uint32_t                CapsuleCount    = 2u;                   // [-]   capsules dropped on the other side
    float                   DropHeight      = 6.0f;                 // [m]   height of the lowest body above the plane
    float                   Spacing         = 1.25f;                // [m]   vertical spacing between dropped bodies
    float                   PlaneHalfExtent = 50.0f;                // [m]   broad-phase bounds of the ground plane
    float                   PlaneFriction   = 0.6f;                 // [-]
    float                   BodyRestitution = 0.25f;                // [-]   a little bounce so the drop is visible in the log
};

//------------------------------------------------------------------------------------------------------------------------
//                                                  DROP SCENE STRUCTURE
//------------------------------------------------------------------------------------------------------------------------

class DropSceneStructure
{
public:
    DropSceneStructure() noexcept = default;

    // Creates the plane and every body in the solver; returns false (with the solver's refusal text) if any body was refused.
    [[nodiscard]] bool      Construct(RigidBodySolver& Solver, const DropSceneConfiguration& Configuration) noexcept;
    void                    Reset(RigidBodySolver& Solver) noexcept;    // teleports every body back to its drop pose

    [[nodiscard]] RigidBodyIdentity              QueryGround() const noexcept { return Ground; }
    [[nodiscard]] const std::vector<RigidBodyIdentity>& QueryBodies() const noexcept { return Bodies; }
    [[nodiscard]] const std::vector<RigidBodyDescription>& QueryDescriptions() const noexcept { return Descriptions; }

private:
    RigidBodyIdentity                   Ground = InvalidRigidBody;  // [-] the static plane
    std::vector<RigidBodyIdentity>      Bodies;                     // [-] dynamic bodies, creation order
    std::vector<RigidBodyDescription>   Descriptions;               // [-] their drop poses, for Reset()
};

} // namespace Frontier::ProjectPhysics
