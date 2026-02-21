cmake_minimum_required(VERSION 3.18)
project(quartet_ffi LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(QUARTET_ROOT_HINTS "")
if(DEFINED ENV{QUARTET_ROOT} AND NOT "$ENV{QUARTET_ROOT}" STREQUAL "")
    list(APPEND QUARTET_ROOT_HINTS "$ENV{QUARTET_ROOT}")
endif()

find_path(
    QUARTET_INCLUDE_DIR
    NAMES make_tet_mesh.h
    HINTS ${QUARTET_ROOT_HINTS}
    PATH_SUFFIXES include src
)

find_library(
    QUARTET_LIBRARY
    NAMES quartet libquartet
    HINTS ${QUARTET_ROOT_HINTS}
    PATH_SUFFIXES lib lib64 build
)

if(NOT QUARTET_INCLUDE_DIR OR NOT QUARTET_LIBRARY)
    message(FATAL_ERROR "Could not locate Quartet headers or library. Set QUARTET_ROOT or install Quartet.")
endif()

add_library(quartet_ffi SHARED src/quartet_ffi.cpp)
target_include_directories(
    quartet_ffi
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${QUARTET_INCLUDE_DIR}
)
target_link_libraries(quartet_ffi PRIVATE ${QUARTET_LIBRARY})

set_target_properties(
    quartet_ffi
    PROPERTIES
    OUTPUT_NAME quartet_ffi
)
