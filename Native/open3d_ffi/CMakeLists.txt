cmake_minimum_required(VERSION 3.18)
project(open3d_ffi LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Open3D CONFIG QUIET)
if (NOT Open3D_FOUND)
    find_package(open3d CONFIG QUIET)
endif()

add_library(open3d_ffi SHARED src/open3d_ffi.cpp)
target_include_directories(open3d_ffi PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

if (TARGET Open3D::Open3D)
    target_link_libraries(open3d_ffi PRIVATE Open3D::Open3D)
elseif (TARGET open3d::Open3D)
    target_link_libraries(open3d_ffi PRIVATE open3d::Open3D)
elseif (DEFINED Open3D_LIBRARIES)
    target_link_libraries(open3d_ffi PRIVATE ${Open3D_LIBRARIES})
    if (DEFINED Open3D_INCLUDE_DIRS)
        target_include_directories(open3d_ffi PRIVATE ${Open3D_INCLUDE_DIRS})
    endif()
elseif (DEFINED OPEN3D_LIBRARIES)
    target_link_libraries(open3d_ffi PRIVATE ${OPEN3D_LIBRARIES})
    if (DEFINED OPEN3D_INCLUDE_DIRS)
        target_include_directories(open3d_ffi PRIVATE ${OPEN3D_INCLUDE_DIRS})
    endif()
else()
    message(FATAL_ERROR "Could not find Open3D library target. Install/configure Open3D with CMake package support.")
endif()

set_target_properties(
    open3d_ffi
    PROPERTIES
    OUTPUT_NAME open3d_ffi
)
