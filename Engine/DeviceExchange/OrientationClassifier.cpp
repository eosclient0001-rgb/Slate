//============================================================================================================================================
// 📦 Frontier/DeviceExchange/OrientationClassifier.cpp — Geometric Orientation Classification Implementation
//============================================================================================================================================

#include "OrientationClassifier.h"

namespace Frontier {

//------------------------------------------------------------------------------------------------------------------------
//                                                GEOMETRIC OPERATIONS
//------------------------------------------------------------------------------------------------------------------------

float OrientationClassifier::DotProduct(const Vector3& a, const Vector3& b) noexcept
{
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vector3 OrientationClassifier::CrossProduct(const Vector3& a, const Vector3& b) noexcept
{
    return Vector3{
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    };
}

Vector3 OrientationClassifier::RotateVector(const Vector3& v, const Quaternion& q) noexcept
{
    Vector3 u{ q.x, q.y, q.z };
    float s = q.w;
    return u * (2.0f * DotProduct(u, v))
         + v * (s * s - DotProduct(u, u))
         + CrossProduct(u, v) * (2.0f * s);
}

bool OrientationClassifier::ClassifyFrustumContainment(const BoundingExtent& Box, const Matrix4x4& ViewProjection) noexcept
{
    (void)Box;
    (void)ViewProjection;
    return true;
}

} // namespace Frontier
