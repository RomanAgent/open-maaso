#include "../../windows/runner/desktop_avatar_alpha_mask.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::cerr << __LINE__ << ": " << #condition << " failed\n";            \
      std::exit(1);                                                        \
    }                                                                      \
  } while (false)

int main() {
  using Mask = DesktopAvatarAlphaMask;
  Mask mask;
  CHECK(mask.Empty());
  CHECK(!mask.Contains(0, 0));

  // A colored transparent pixel is not a target. Alpha 16 is inclusive.
  std::vector<unsigned char> pixels{
      255, 255, 255, 0, 0, 0, 0, 15, 0, 0, 0, 16, 0, 0, 0, 255};
  CHECK(mask.Build(pixels.data(), pixels.size(), 4, 1, 16));
  CHECK(!mask.Contains(0, 0));
  CHECK(!mask.Contains(1, 0));
  CHECK(mask.Contains(2, 0));
  CHECK(mask.Contains(3, 0));
  CHECK(!mask.Contains(-1, 0));
  CHECK(!mask.Contains(4, 0));
  CHECK(!mask.Contains(0, -1));
  CHECK(!mask.Contains(0, 1));

  // Top-down rows, transparent margins and padded stride remain exact.
  pixels.assign(3 * 20, 0);
  pixels[3] = 255;
  pixels[2 * 20 + 3 * 4 + 3] = 255;
  pixels[19] = 255;  // Padding is not a fifth pixel.
  CHECK(mask.Build(pixels.data(), pixels.size(), 4, 3, 20));
  CHECK(mask.Contains(0, 0));
  CHECK(mask.Contains(3, 2));
  CHECK(!mask.Contains(0, 2));
  CHECK(!mask.Contains(3, 0));
  CHECK(!mask.Contains(4, 0));

  // Identical silhouettes skip native region work even if RGB/opacity change.
  Mask same;
  pixels[0] = 55;
  pixels[3] = 16;
  CHECK(same.Build(pixels.data(), pixels.size(), 4, 3, 20));
  CHECK(mask.SameShape(same));
  pixels[3] = 15;
  CHECK(same.Build(pixels.data(), pixels.size(), 4, 3, 20));
  CHECK(!mask.SameShape(same));

  // Opaque runs merge vertically, preserving holes between limbs.
  pixels.assign(8 * 6 * 4, 0);
  for (int y = 0; y < 6; ++y) {
    for (int x : {1, 2, 5, 6}) pixels[(y * 8 + x) * 4 + 3] = 255;
  }
  CHECK(mask.Build(pixels.data(), pixels.size(), 8, 6, 32));
  CHECK(mask.rectangles().size() == 2);
  CHECK(mask.rectangles()[0].top == 0);
  CHECK(mask.rectangles()[0].bottom == 6);
  CHECK(mask.Contains(1, 3));
  CHECK(!mask.Contains(3, 3));
  CHECK(!mask.Contains(4, 3));
  CHECK(mask.Contains(6, 3));

  // Compare run rectangles with every original pixel, including changing runs.
  uint32_t random = 0x91827364;
  for (int sample = 0; sample < 100; ++sample) {
    const int width = 5 + sample % 29;
    const int height = 3 + sample % 23;
    const size_t stride = static_cast<size_t>(width) * 4 + 8;
    pixels.assign(stride * height, 0);
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        random = random * 1664525u + 1013904223u;
        pixels[y * stride + x * 4 + 3] = (random >> 24) % 32;
      }
    }
    CHECK(mask.Build(pixels.data(), pixels.size(), width, height, stride));
    for (size_t index = 0; index < mask.rectangles().size(); ++index) {
      const auto& rect = mask.rectangles()[index];
      CHECK(rect.left >= 0 && rect.left < rect.right && rect.right <= width);
      CHECK(rect.top >= 0 && rect.top < rect.bottom && rect.bottom <= height);
      if (index > 0) {
        const auto& previous = mask.rectangles()[index - 1];
        CHECK(previous.top < rect.top ||
              (previous.top == rect.top && previous.left < rect.left));
      }
    }
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        int region_coverage = 0;
        for (const auto& rect : mask.rectangles()) {
          if (x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom) {
            ++region_coverage;
          }
        }
        const bool expected = pixels[y * stride + x * 4 + 3] >= 16;
        CHECK(mask.Contains(x, y) == expected);
        CHECK(region_coverage == (expected ? 1 : 0));
      }
    }
  }

  // Allocation/geometry failures and oversized input never retain an old mask.
  pixels.assign(16, 255);
  CHECK(mask.Build(pixels.data(), pixels.size(), 2, 2, 8));
  CHECK(!mask.Build(pixels.data(), 15, 2, 2, 8));
  CHECK(mask.Empty());
  CHECK(!mask.Contains(0, 0));
  CHECK(!mask.Build(nullptr, 16, 2, 2, 8));
  CHECK(!mask.Build(pixels.data(), 16, -1, 2, 8));
  CHECK(!mask.Build(pixels.data(), 16, 2, 2, 7));
  CHECK(!mask.Build(pixels.data(), 16, 2, 0, 8));
  CHECK(!mask.Build(pixels.data(), std::numeric_limits<size_t>::max(),
                    std::numeric_limits<int>::max(), 2,
                    std::numeric_limits<size_t>::max()));

  // A checkerboard cannot produce unlimited GDI rectangles.
  constexpr int fragmented_size = 257;
  pixels.assign(fragmented_size * fragmented_size * 4, 0);
  for (int y = 0; y < fragmented_size; ++y) {
    for (int x = 0; x < fragmented_size; ++x) {
      if ((x + y) % 2 == 0) pixels[(y * fragmented_size + x) * 4 + 3] = 255;
    }
  }
  CHECK(!mask.Build(pixels.data(), pixels.size(), fragmented_size,
                    fragmented_size, fragmented_size * 4));
  CHECK(mask.Empty());
  CHECK(!mask.Contains(0, 0));

  pixels.assign(64 * 64 * 4, 255);
  CHECK(mask.Build(pixels.data(), pixels.size(), 64, 64, 256));
  CHECK(mask.rectangles().size() == 1);
  mask.Clear();
  CHECK(mask.Empty());
  CHECK(!mask.Contains(0, 0));
  pixels.assign(64 * 64 * 4, 0);
  CHECK(mask.Build(pixels.data(), pixels.size(), 64, 64, 256));
  CHECK(mask.Empty());
  CHECK(!mask.Contains(63, 63));

  std::cout << "DesktopAvatarAlphaMask: pixel, region, lifecycle and bounds checks passed\n";
}
