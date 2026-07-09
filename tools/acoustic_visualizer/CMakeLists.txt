cmake_minimum_required(VERSION 3.24)
project(bugu_acoustic_visualizer LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(GPU_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GPU_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GPU_INSTALL OFF CACHE BOOL "" FORCE)
set(SLANG_RHI_ENABLE_WGPU OFF CACHE BOOL "" FORCE)
set(SLANG_RHI_ENABLE_CUDA OFF CACHE BOOL "" FORCE)
set(SLANG_RHI_ENABLE_D3D11 OFF CACHE BOOL "" FORCE)
set(SLANG_RHI_ENABLE_OPTIX OFF CACHE BOOL "" FORCE)

set(BUGU_ROOT "${CMAKE_CURRENT_LIST_DIR}/../..")
set(BUGU_GPU_ROOT "${BUGU_ROOT}/third_party/in_dreaming_gpu")
set(BUGU_ZIG_VISUALIZER_LIB "" CACHE FILEPATH "Zig-built acoustic visualizer static library")

if(NOT BUGU_ZIG_VISUALIZER_LIB)
    message(FATAL_ERROR "BUGU_ZIG_VISUALIZER_LIB must be set")
endif()

add_subdirectory("${BUGU_GPU_ROOT}" "${CMAKE_BINARY_DIR}/in_dreaming_gpu")

add_executable(bugu_acoustic_visualizer main_shim.c)
target_link_libraries(bugu_acoustic_visualizer PRIVATE
    "${BUGU_ZIG_VISUALIZER_LIB}"
    gpu
)
target_compile_definitions(bugu_acoustic_visualizer PRIVATE _CRT_SECURE_NO_WARNINGS)

if(MSVC)
    target_compile_options(bugu_acoustic_visualizer PRIVATE /W4)
    # Zig std on Windows MSVC ABI calls ntdll directly; also avoid libcmt clash.
    target_link_libraries(bugu_acoustic_visualizer PRIVATE ntdll)
    target_link_options(bugu_acoustic_visualizer PRIVATE "/NODEFAULTLIB:libcmt")
else()
    target_compile_options(bugu_acoustic_visualizer PRIVATE -Wall -Wextra -pedantic)
    target_link_libraries(bugu_acoustic_visualizer PRIVATE m pthread dl stdc++)
endif()

add_dependencies(bugu_acoustic_visualizer slang-rhi-copy-files)

foreach(shader acoustic_trace.slang acoustic_draw.slang)
    add_custom_command(TARGET bugu_acoustic_visualizer POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_LIST_DIR}/${shader}"
            "$<TARGET_FILE_DIR:bugu_acoustic_visualizer>/${shader}"
    )
endforeach()

add_custom_command(TARGET bugu_acoustic_visualizer POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${BUGU_ROOT}/examples/data/hello.wav"
        "$<TARGET_FILE_DIR:bugu_acoustic_visualizer>/hello.wav"
)

add_custom_command(TARGET bugu_acoustic_visualizer POST_BUILD
    COMMAND ${CMAKE_COMMAND}
        -D SRC_DIR="${CMAKE_BINARY_DIR}/in_dreaming_gpu/modules/3rd/slang-rhi"
        -D DST_DIR="$<TARGET_FILE_DIR:bugu_acoustic_visualizer>"
        -P "${BUGU_GPU_ROOT}/cmake/CopySlangRhiRuntime.cmake"
)

add_custom_command(TARGET bugu_acoustic_visualizer POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:SDL3-shared>"
        "$<TARGET_FILE_DIR:bugu_acoustic_visualizer>/"
)
