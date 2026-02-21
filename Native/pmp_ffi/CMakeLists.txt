cmake_minimum_required(VERSION 3.18)
project(pmp_ffi LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(PMP CONFIG QUIET)
if (NOT PMP_FOUND)
    find_package(pmp CONFIG QUIET)
endif()

add_library(pmp_ffi SHARED src/pmp_ffi.cpp)
target_include_directories(pmp_ffi PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

if (TARGET PMP::pmp)
    target_link_libraries(pmp_ffi PRIVATE PMP::pmp)
elseif (TARGET pmp::pmp)
    target_link_libraries(pmp_ffi PRIVATE pmp::pmp)
elseif (TARGET pmp)
    target_link_libraries(pmp_ffi PRIVATE pmp)
elseif (DEFINED PMP_LIBRARIES)
    target_link_libraries(pmp_ffi PRIVATE ${PMP_LIBRARIES})
    if (DEFINED PMP_INCLUDE_DIRS)
        target_include_directories(pmp_ffi PRIVATE ${PMP_INCLUDE_DIRS})
    endif()
else()
    message(FATAL_ERROR "Could not find PMP library target. Install/configure pmp-library with CMake package support.")
endif()

set_target_properties(
    pmp_ffi
    PROPERTIES
    OUTPUT_NAME pmp_ffi
)
