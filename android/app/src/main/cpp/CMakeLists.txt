cmake_minimum_required(VERSION 3.22.1)

project(maaso_live_rtc LANGUAGES CXX)

add_library(
    maaso_live_rtc
    SHARED
    live_rtc_audio_bridge.cpp
)

find_library(log_library log)
find_library(android_library android)
find_library(egl_library EGL)
find_library(gles_library GLESv3)

target_compile_features(maaso_live_rtc PRIVATE cxx_std_17)
target_compile_options(maaso_live_rtc PRIVATE -Wall -Wextra -Werror)
target_link_libraries(
    maaso_live_rtc
    PRIVATE
    ${log_library}
    ${android_library}
    ${egl_library}
    ${gles_library}
)
