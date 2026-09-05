//============================================================================================================================================
// 📦 Frontier/DeviceExchange/OrientationClassifier.h — Geometric Orientation Classification and Vector Mechanics
//============================================================================================================================================

#pragma once

#if defined(_MSC_VER)
    #pragma warning(disable: 4324)                              // Disable structure padding alignment warning under /WX
#endif

#include <cmath>
#include <cstdint>
#include <array>

namespace Frontier {

//------------------------------------------------------------------------------------------------------------------------
//                                                    VECTOR 3
//------------------------------------------------------------------------------------------------------------------------

struct alignas(16) Vector3
{
    float                   x;                                  // [m] spatial component x
    float                   y;                                  // [m] spatial component y
    float                   z;                                  // [m] spatial component z
    float                   w;                                  // [-] homogeneous / padding component

    constexpr Vector3() noexcept : x(0.0f), y(0.0f), z(0.0f), w(0.0f) {}
    constexpr Vector3(float inX, float inY, float inZ, float inW = 0.0f) noexcept : x(inX), y(inY), z(inZ), w(inW) {}

    [[nodiscard]] constexpr Vector3 operator+(const Vector3& rhs) const noexcept { return { x + rhs.x, y + rhs.y, z + rhs.z }; }
    [[nodiscard]] constexpr Vector3 operator-(const Vector3& rhs) const noexcept { return { x - rhs.x, y - rhs.y, z - rhs.z }; }
    [[nodiscard]] constexpr Vector3 operator*(const Vector3& rhs) const noexcept { return { x * rhs.x, y * rhs.y, z * rhs.z }; }
    [[nodiscard]] constexpr Vector3 operator*(float scalar) const noexcept { return { x * scalar, y * scalar, z * scalar }; }
    [[nodiscard]] constexpr Vector3 operator/(float scalar) const noexcept { float inv = 1.0f / scalar; return { x * inv, y * inv, z * inv }; }

    constexpr Vector3& operator+=(const Vector3& rhs) noexcept { x += rhs.x; y += rhs.y; z += rhs.z; return *this; }
    constexpr Vector3& operator-=(const Vector3& rhs) noexcept { x -= rhs.x; y -= rhs.y; z -= rhs.z; return *this; }
    constexpr Vector3& operator*=(const Vector3& rhs) noexcept { x *= rhs.x; y *= rhs.y; z *= rhs.z; return *this; }
    constexpr Vector3& operator*=(float scalar) noexcept { x *= scalar; y *= scalar; z *= scalar; return *this; }

    [[nodiscard]] float LengthSquared() const noexcept { return x * x + y * y + z * z; }
    [[nodiscard]] float Length() const noexcept { return std::sqrt(LengthSquared()); }
    [[nodiscard]] Vector3 Normalized() const noexcept
    {
        float len = Length();
        return (len > 1e-7f) ? (*this / len) : Vector3{ 0.0f, 0.0f, 0.0f };
    }

    // Single unified type conversion operator
    template<typename TargetType>
    [[nodiscard]] TargetType Convert() const noexcept;
};

template<>
inline std::array<float, 3> Vector3::Convert<std::array<float, 3>>() const noexcept
{
    return { x, y, z };
}

template<>
inline float Vector3::Convert<float>() const noexcept
{
    return Length();
}

//------------------------------------------------------------------------------------------------------------------------
//                                                    VECTOR 4
//------------------------------------------------------------------------------------------------------------------------

struct alignas(16) Vector4
{
    float                   x;                                  // [-] component x
    float                   y;                                  // [-] component y
    float                   z;                                  // [-] component z
    float                   w;                                  // [-] component w

    constexpr Vector4() noexcept : x(0.0f), y(0.0f), z(0.0f), w(0.0f) {}
    constexpr Vector4(float inX, float inY, float inZ, float inW) noexcept : x(inX), y(inY), z(inZ), w(inW) {}
};

//------------------------------------------------------------------------------------------------------------------------
//                                                   QUATERNION
//------------------------------------------------------------------------------------------------------------------------

struct alignas(16) Quaternion
{
    float                   x;                                  // [rad] imaginary component x
    float                   y;                                  // [rad] imaginary component y
    float                   z;                                  // [rad] imaginary component z
    float                   w;                                  // [rad] real scalar component w

    constexpr Quaternion() noexcept : x(0.0f), y(0.0f), z(0.0f), w(1.0f) {}
    constexpr Quaternion(float inX, float inY, float inZ, float inW) noexcept : x(inX), y(inY), z(inZ), w(inW) {}

    [[nodiscard]] static Quaternion Identity() noexcept { return { 0.0f, 0.0f, 0.0f, 1.0f }; }

    [[nodiscard]] Quaternion operator*(const Quaternion& rhs) const noexcept
    {
        return {
            w * rhs.x + x * rhs.w + y * rhs.z - z * rhs.y,
            w * rhs.y - x * rhs.z + y * rhs.w + z * rhs.x,
            w * rhs.z + x * rhs.y - y * rhs.x + z * rhs.w,
            w * rhs.w - x * rhs.x - y * rhs.y - z * rhs.z
        };
    }
};

//------------------------------------------------------------------------------------------------------------------------
//                                                   MATRIX 4X4
//------------------------------------------------------------------------------------------------------------------------

struct alignas(16) Matrix4x4
{
    float                   Columns[4][4];                      // [-] column-major matrix components

    constexpr Matrix4x4() noexcept : Columns{}
    {
        Columns[0][0] = 1.0f;
        Columns[1][1] = 1.0f;
        Columns[2][2] = 1.0f;
        Columns[3][3] = 1.0f;
    }

    [[nodiscard]] static Matrix4x4 Identity() noexcept { return Matrix4x4(); }
};

//------------------------------------------------------------------------------------------------------------------------
//                                                SPATIAL BOUNDING EXTENT
//------------------------------------------------------------------------------------------------------------------------

struct BoundingExtent
{
    Vector3                 MinBounds;                          // [m] minimum spatial coordinate
    Vector3                 MaxBounds;                          // [m] maximum spatial coordinate

    [[nodiscard]] Vector3 QueryCenter() const noexcept { return (MinBounds + MaxBounds) * 0.5f; }
    [[nodiscard]] Vector3 QueryExtents() const noexcept { return (MaxBounds - MinBounds) * 0.5f; }
};

//------------------------------------------------------------------------------------------------------------------------
//                                              ORIENTATION CLASSIFIER
//------------------------------------------------------------------------------------------------------------------------

class OrientationClassifier
{
public:
    [[nodiscard]] static float    DotProduct(const Vector3& a, const Vector3& b) noexcept;
    [[nodiscard]] static Vector3  CrossProduct(const Vector3& a, const Vector3& b) noexcept;
    [[nodiscard]] static Vector3  RotateVector(const Vector3& v, const Quaternion& q) noexcept;
    [[nodiscard]] static bool     ClassifyFrustumContainment(const BoundingExtent& Box, const Matrix4x4& ViewProjection) noexcept;
};

} // namespace Frontier
