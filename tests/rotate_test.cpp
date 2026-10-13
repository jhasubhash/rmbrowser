// Host unit test for engine/wpeqt/rotate.h (clang++ -std=c++17; run via scripts/run-tests.sh).
#include "../engine/wpeqt/rotate.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>

static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); ++fails; } } while (0)

using namespace rmweb;
static const int PW = 1620, PH = 2160;   // Paper Pro panel

// Forward map of one logical pixel (the image rotation QImage::transformed applies).
static void logicalToPhys(int deg, int lx, int ly, int& px, int& py) {
    if (deg == 90)       { px = PW - 1 - ly; py = lx; }
    else if (deg == 270) { px = ly;          py = PH - 1 - lx; }
    else                 { px = lx;          py = ly; }
}

int main() {
    // parsing / cycle / labels
    CHECK(parseRotation("0") == 0 && parseRotation("90") == 90 && parseRotation("270") == 270);
    CHECK(parseRotation("landscape") == 90 && parseRotation("landscape-flipped") == 270);
    CHECK(parseRotation("180") == -1 && parseRotation("") == -1 && parseRotation("x") == -1);
    CHECK(nextRotation(0) == 90 && nextRotation(90) == 270 && nextRotation(270) == 0);
    CHECK(nextRotation(45) == 90);                        // garbage normalizes to portrait first
    CHECK(normalizeRotation(180) == 0 && normalizeRotation(-90) == 0);
    CHECK(std::string(rotationLabel(90)) == "landscape");

    // logical size
    int lw, lh;
    logicalSize(0, PW, PH, lw, lh);   CHECK(lw == PW && lh == PH);
    logicalSize(90, PW, PH, lw, lh);  CHECK(lw == PH && lh == PW);
    logicalSize(270, PW, PH, lw, lh); CHECK(lw == PH && lh == PW);

    // touch inverse is exact for every corner + a sample grid, all orientations
    for (int deg : {0, 90, 270}) {
        logicalSize(deg, PW, PH, lw, lh);
        for (int ly = 0; ly < lh; ly += 97) for (int lx = 0; lx < lw; lx += 89) {
            int px, py, bx, by;
            logicalToPhys(deg, lx, ly, px, py);
            CHECK(px >= 0 && px < PW && py >= 0 && py < PH);
            physToLogical(deg, PW, PH, px, py, bx, by);
            if (bx != lx || by != ly) { std::printf("deg=%d (%d,%d)->(%d,%d)->(%d,%d)\n", deg, lx, ly, px, py, bx, by); ++fails; }
        }
        const int cx[4] = {0, lw - 1, 0, lw - 1}, cy[4] = {0, 0, lh - 1, lh - 1};
        for (int i = 0; i < 4; ++i) {
            int px, py, bx, by;
            logicalToPhys(deg, cx[i], cy[i], px, py);
            physToLogical(deg, PW, PH, px, py, bx, by);
            CHECK(bx == cx[i] && by == cy[i]);
        }
    }
    // landscape (90): logical top-left sits at the physical top-RIGHT corner
    { int lx, ly; physToLogical(90, PW, PH, PW - 1, 0, lx, ly); CHECK(lx == 0 && ly == 0); }
    // flipped (270): logical top-left sits at the physical bottom-LEFT corner
    { int lx, ly; physToLogical(270, PW, PH, 0, PH - 1, lx, ly); CHECK(lx == 0 && ly == 0); }
    // out-of-range digitizer values clamp instead of escaping the frame
    { int lx, ly; physToLogical(90, PW, PH, -5, PH + 9, lx, ly); CHECK(lx == PH - 1 && ly == PW - 1); }

    // rect mapping: full frame -> full panel; a rect maps to exactly its pixels' bounding box
    for (int deg : {0, 90, 270}) {
        logicalSize(deg, PW, PH, lw, lh);
        IRect f = logicalRectToPhys(deg, PW, PH, {0, 0, lw, lh});
        CHECK(f.x == 0 && f.y == 0 && f.w == PW && f.h == PH);
        const IRect r{120, 40, 300, 80};
        IRect p = logicalRectToPhys(deg, PW, PH, r);
        int minx = 1 << 30, miny = 1 << 30, maxx = -1, maxy = -1;
        for (int y = r.y; y < r.y + r.h; ++y) for (int x = r.x; x < r.x + r.w; ++x) {
            int px, py; logicalToPhys(deg, x, y, px, py);
            minx = std::min(minx, px); miny = std::min(miny, py);
            maxx = std::max(maxx, px); maxy = std::max(maxy, py);
        }
        CHECK(p.x == minx && p.y == miny && p.w == maxx - minx + 1 && p.h == maxy - miny + 1);
    }

    if (fails) { std::printf("rotate_test: %d FAILED\n", fails); return 1; }
    std::printf("rotate_test: OK\n");
    return 0;
}
