//============================================================================================================================================
// 📦 Project-Zero/Source/FlyThroughSolver.h — Unreal-Style Fly-Through Camera Navigation and Viewport Locomotion
//============================================================================================================================================

#pragma once

#include "../../../Engine/GeometricRaster/CameraProjection.h"
#include "../../../Engine/DeviceExchange/InputExchange.h"

namespace Frontier::ProjectZero {

//------------------------------------------------------------------------------------------------------------------------
//                                              FLY-THROUGH CONFIGURATION
//------------------------------------------------------------------------------------------------------------------------

struct FlyThroughConfiguration
{
    float                   BaseFlightSpeed;                    // [m/s] default translational movement speed
    float                   BoostMultiplier;                    // [-] speed scaling when Left Shift is held
    float                   MouseSensitivity;                   // [rad/px] rotational sensitivity per mouse pixel
    float                   ScrollSpeedIncrement;               // [m/s] speed delta per scroll wheel step
    float                   AccelerationDamping;                // [0..1] momentum smoothing coefficient
};

//------------------------------------------------------------------------------------------------------------------------
//                                                FLY-THROUGH SOLVER
//------------------------------------------------------------------------------------------------------------------------

class FlyThroughSolver : public Frontier::CameraProjection
{
public:
    FlyThroughSolver() noexcept;
    explicit FlyThroughSolver(const FlyThroughConfiguration& InitialConfig) noexcept;
    ~FlyThroughSolver() noexcept override = default;

    void                    AdvanceLocomotion(const InputExchange& Input, float Δτ) noexcept;
    void                    AdvanceProjection(float Δτ) noexcept override;

    // Project-Zero's Cornell box uses +Y up and +Z forward.
    void                    AssignOrientationEuler(float PitchRadians, float YawRadians, float RollRadians) noexcept;
    void                    AssignFlightSpeed(float SpeedMetersPerSec) noexcept;

    [[nodiscard]] float     QueryFlightSpeed() const noexcept { return CurrentFlightSpeed; }
    [[nodiscard]] bool      IsSteeringActive() const noexcept { return SteeringActive; }

    // Single unified conversion operator for current speed
    template<typename TargetType>
    [[nodiscard]] TargetType Convert() const noexcept;

private:
    FlyThroughConfiguration Config;                             // [config] flight tuning constants
    Vector3                 CurrentVelocity;                    // [m/s] smooth translational momentum
    float                   CurrentFlightSpeed;                 // [m/s] active flight speed
    bool                    SteeringActive;                     // [bool] true when RMB is held
};

template<>
inline float FlyThroughSolver::Convert<float>() const noexcept
{
    return CurrentFlightSpeed;
}

template<>
inline Vector3 FlyThroughSolver::Convert<Vector3>() const noexcept
{
    return SpatialLocation;
}

} // namespace Frontier::ProjectZero
