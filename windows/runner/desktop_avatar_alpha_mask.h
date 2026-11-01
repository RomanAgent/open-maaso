#ifndef RUNNER_DESKTOP_AVATAR_ALPHA_MASK_H_
#define RUNNER_DESKTOP_AVATAR_ALPHA_MASK_H_

#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

// Platform-independent silhouette of an already composited, top-down BGRA DIB.
// The same binary pixels drive point tests and the native window region.
class DesktopAvatarAlphaMask {
 public:
  struct Rect {
    int left;
    int top;
    int right;
    int bottom;
  };

  static constexpr unsigned char kMinimumAlpha = 16;
  static constexpr size_t kMaximumPixels = 16 * 1024 * 1024;
  static constexpr size_t kMaximumRectangles = 16384;

  bool Build(const unsigned char* bgra,
             size_t bytes,
             int width,
             int height,
             size_t stride) noexcept {
    Clear();
    if (bgra == nullptr || width <= 0 || height <= 0 ||
        static_cast<size_t>(width) > kMaximumPixels /
                                          static_cast<size_t>(height) ||
        stride < static_cast<size_t>(width) * 4 ||
        stride > bytes / static_cast<size_t>(height)) {
      return false;
    }
    try {
      width_ = width;
      height_ = height;
      pixels_.resize(static_cast<size_t>(width) * height);
      struct Run {
        int left;
        int right;
        size_t rectangle;
      };
      std::vector<Run> previous;
      std::vector<Run> current;
      for (int y = 0; y < height; ++y) {
        current.clear();
        size_t previous_index = 0;
        const auto* row = bgra + static_cast<size_t>(y) * stride;
        auto* mask_row = pixels_.data() + static_cast<size_t>(y) * width;
        int x = 0;
        while (x < width) {
          if (row[static_cast<size_t>(x) * 4 + 3] < kMinimumAlpha) {
            mask_row[x++] = 0;
            continue;
          }
          const int left = x;
          do {
            mask_row[x++] = 1;
          } while (x < width &&
                   row[static_cast<size_t>(x) * 4 + 3] >= kMinimumAlpha);
          const int right = x;
          while (previous_index < previous.size() &&
                 (previous[previous_index].left < left ||
                  (previous[previous_index].left == left &&
                   previous[previous_index].right < right))) {
            ++previous_index;
          }
          size_t rectangle;
          if (previous_index < previous.size() &&
              previous[previous_index].left == left &&
              previous[previous_index].right == right) {
            rectangle = previous[previous_index].rectangle;
            rectangles_[rectangle].bottom = y + 1;
          } else {
            // A fragmented or corrupt frame must not allocate an unbounded
            // GDI region, nor fall back to a rectangle that blocks other apps.
            if (rectangles_.size() == kMaximumRectangles) {
              Clear();
              return false;
            }
            rectangle = rectangles_.size();
            rectangles_.push_back(Rect{left, y, right, y + 1});
          }
          current.push_back(Run{left, right, rectangle});
        }
        previous.swap(current);
      }
      return true;
    } catch (...) {
      Clear();
      return false;
    }
  }

  bool Contains(int x, int y) const noexcept {
    return x >= 0 && y >= 0 && x < width_ && y < height_ &&
           pixels_[static_cast<size_t>(y) * width_ + x] != 0;
  }

  bool Empty() const noexcept { return rectangles_.empty(); }

  bool SameShape(const DesktopAvatarAlphaMask& other) const noexcept {
    return width_ == other.width_ && height_ == other.height_ &&
           pixels_ == other.pixels_;
  }

  void Clear() noexcept {
    width_ = 0;
    height_ = 0;
    pixels_.clear();
    rectangles_.clear();
  }

  const std::vector<Rect>& rectangles() const noexcept { return rectangles_; }

 private:
  int width_ = 0;
  int height_ = 0;
  std::vector<unsigned char> pixels_;
  std::vector<Rect> rectangles_;
};

#endif  // RUNNER_DESKTOP_AVATAR_ALPHA_MASK_H_
