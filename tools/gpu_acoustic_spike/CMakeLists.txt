cmake_minimum_required(VERSION 3.24)
project(bugu_gpu_acoustic_spike LANGUAGES C CXX)

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

add_subdirectory("${BUGU_GPU_ROOT}" "${CMAKE_BINARY_DIR}/in_dreaming_gpu")

add_executable(bugu_gpu_acoustic_spike main.c)
target_link_libraries(bugu_gpu_acoustic_spike PRIVATE gpu)
target_compile_definitions(bugu_gpu_acoustic_spike PRIVATE _CRT_SECURE_NO_WARNINGS)

if(MSVC)
    target_compile_options(bugu_gpu_acoustic_spike PRIVATE /W4 /WX)
else()
    target_compile_options(bugu_gpu_acoustic_spike PRIVATE -Wall -Wextra -Werror -pedantic)
endif()

add_dependencies(bugu_gpu_acoustic_spike slang-rhi-copy-files)

add_custom_command(TARGET bugu_gpu_acoustic_spike POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_LIST_DIR}/gpu_acoustic.slang"
        "$<TARGET_FILE_DIR:bugu_gpu_acoustic_spike>/gpu_acoustic.slang"
)

add_custom_command(TARGET bugu_gpu_acoustic_spike POST_BUILD
    COMMAND ${CMAKE_COMMAND}
        -D SRC_DIR="${CMAKE_BINARY_DIR}/in_dreaming_gpu/modules/3rd/slang-rhi"
        -D DST_DIR="$<TARGET_FILE_DIR:bugu_gpu_acoustic_spike>"
        -P "${BUGU_GPU_ROOT}/cmake/CopySlangRhiRuntime.cmake"
)

add_custom_command(TARGET bugu_gpu_acoustic_spike POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:SDL3-shared>"
        "$<TARGET_FILE_DIR:bugu_gpu_acoustic_spike>/"
)
