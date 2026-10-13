// rotate.h — screen orientation for rmweb (pure logic, no Qt; tests/rotate_test.cpp).
//
// The browser lays out and paints in a LOGICAL frame (kPanelW x kPanelH). In landscape the logical
// frame is the physical panel turned on its side (2160x1620 on the Paper Pro); only the two
// hardware boundaries rotate: the painted image -> panel, and the digitizer -> logical taps.
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
#include <string>

namespace rmweb {

inline int normalizeRotation(int deg) { return (deg == 90 || deg == 270) ? deg : 0; }

// Settings-page cycle: portrait -> landscape -> landscape (flipped) -> portrait.
inline int nextRotation(int deg) {
    deg = normalizeRotation(deg);
    return deg == 0 ? 90 : deg == 90 ? 270 : 0;
}

inline const char* rotationLabel(int deg) {
    deg = normalizeRotation(deg);
    return deg == 90 ? "landscape" : deg == 270 ? "landscape (flipped)" : "portrait";
}

// "0" / "90" / "270" (also "portrait" / "landscape" / "landscape-flipped"); anything else -> -1.
inline int parseRotation(const std::string& s) {
    if (s == "0" || s == "portrait") return 0;
    if (s == "90" || s == "landscape") return 90;
    if (s == "270" || s == "landscape-flipped") return 270;
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
