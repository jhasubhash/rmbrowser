// rotate.h — screen orientation for rmweb (pure logic, no Qt; tests/rotate_test.cpp).
//
// The browser lays out and paints in a LOGICAL frame (kPanelW x kPanelH). In landscape the logical
// frame is the physical panel turned on its side (2160x1620 on the Paper Pro); only the two
// hardware boundaries rotate: the painted image -> panel, and the digitizer -> logical taps.
//
// The setting can also be kRotateAuto (-1, the default): follow the accelerometer (see
// classifyOrientation), resolved to one of the effective rotations below.
//
//   deg = 0    portrait (native)
//   deg = 90   landscape: logical top edge = the panel's physical RIGHT edge
//              (turn the tablet 90° counter-clockwise; Type Folio keyboard-at-bottom orientation)
//   deg = 270  landscape, flipped: logical top edge = the panel's physical LEFT edge
//
// Logical pixel (lx, ly) lands on physical pixel:
//   90:  (PW-1-ly, lx)          270: (ly, PH-1-lx)
// which is exactly what QImage::transformed(QTransform().rotate(deg)) does to an image.
#pragma once
#include <cmath>
#include <cstdlib>
#include <string>

namespace rmweb {

// The orientation SETTING is one of kRotateAuto / 0 / 90 / 270; the effective rotation of a running
// process is always 0 / 90 / 270 (auto resolves it from the accelerometer — classifyOrientation).
constexpr int kRotateAuto = -1;

inline int normalizeRotation(int deg) { return (deg == 90 || deg == 270) ? deg : 0; }
inline int normalizeRotationSetting(int s) { return s == kRotateAuto ? kRotateAuto : normalizeRotation(s); }

// Settings-page cycle: auto -> portrait -> landscape -> landscape (flipped) -> auto.
inline int nextRotation(int s) {
    if (s == kRotateAuto) return 0;
    s = normalizeRotation(s);
    return s == 0 ? 90 : s == 90 ? 270 : kRotateAuto;
}

inline const char* rotationLabel(int s) {
    if (s == kRotateAuto) return "auto (follows the tablet)";
    s = normalizeRotation(s);
    return s == 90 ? "landscape" : s == 270 ? "landscape (flipped)" : "portrait";
}

// "0" / "90" / "270" / "auto" (also "portrait" / "landscape" / "landscape-flipped");
// anything else -> -2 (invalid; -1 is kRotateAuto).
inline int parseRotation(const std::string& s) {
    if (s == "auto") return kRotateAuto;
    if (s == "0" || s == "portrait") return 0;
    if (s == "90" || s == "landscape") return 90;
    if (s == "270" || s == "landscape-flipped") return 270;
    return -2;
}

// IIO "in_accel_mount_matrix" ("a, b, c; d, e, f; g, h, i") -> row-major 3x3. Maps the chip's raw
// axes into the device frame (x = right edge, y = top edge, z = out of the screen in portrait; at
// rest the reading points AWAY from gravity, i.e. +y when the tablet stands upright). Malformed ->
// false (callers fall back to identity).
inline bool parseMountMatrix(const std::string& s, double m[9]) {
    const char* p = s.c_str();
    for (int i = 0; i < 9; ++i) {
        while (*p == ' ' || *p == ',' || *p == ';' || *p == '\n' || *p == '\t') ++p;
        char* end = nullptr;
        const double v = std::strtod(p, &end);
        if (end == p) return false;
        m[i] = v; p = end;
    }
    return true;
}

// Device-frame gravity (x right edge, y top edge, z toward the reader) -> rotation to show:
//   tablet upright           (+y up)         -> 0
//   right edge on top        (+x up)         -> 90
//   left edge on top         (-x up)         -> 270
// No decision (-1) when the tablet lies too flat (in-plane gravity < ~30° of tilt), when it is
// upside-down (rmweb has no 180° mode), or inside the ±~34° dead band around the diagonals — the
// dead band is the hysteresis: a held tablet wobbling near 45° never flips back and forth.
inline int classifyOrientation(double x, double y, double z) {
    const double inPlane = std::hypot(x, y), total = std::sqrt(x * x + y * y + z * z);
    if (total <= 0 || inPlane < 0.5 * total) return -1;   // < 30° from flat
    const double ax = std::fabs(x), ay = std::fabs(y);
    if (ay >= 1.5 * ax) return y > 0 ? 0 : -1;            // portrait; upside-down = no decision
    if (ax >= 1.5 * ay) return x > 0 ? 90 : 270;
    return -1;
}

inline bool isLandscape(int deg) { return normalizeRotation(deg) != 0; }

// Logical frame size for a physical panel PWxPH.
inline void logicalSize(int deg, int pw, int ph, int& lw, int& lh) {
    if (isLandscape(deg)) { lw = ph; lh = pw; } else { lw = pw; lh = ph; }
}

// Physical panel pixel -> logical pixel (touch). Inputs are clamped into the panel first.
inline void physToLogical(int deg, int pw, int ph, int px, int py, int& lx, int& ly) {
    px = px < 0 ? 0 : px >= pw ? pw - 1 : px;
    py = py < 0 ? 0 : py >= ph ? ph - 1 : py;
    switch (normalizeRotation(deg)) {
        case 90:  lx = py;          ly = pw - 1 - px; break;
        case 270: lx = ph - 1 - py; ly = px;          break;
        default:  lx = px;          ly = py;          break;
    }
}

// Logical rect -> the physical rect it covers on the panel (damage / update regions).
struct IRect { int x, y, w, h; };
inline IRect logicalRectToPhys(int deg, int pw, int ph, IRect r) {
    switch (normalizeRotation(deg)) {
        case 90:  return { pw - r.y - r.h, r.x, r.h, r.w };
        case 270: return { r.y, ph - r.x - r.w, r.h, r.w };
        default:  return r;
    }
}

} // namespace rmweb
