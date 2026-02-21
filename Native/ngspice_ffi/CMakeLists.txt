cmake_minimum_required(VERSION 3.18)
project(ngspice_ffi LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(NGSPICE_ROOT "" CACHE PATH "Root prefix for ngspice installation (contains include/ and lib/)")

find_path(
    NGSPICE_INCLUDE_DIR
    NAMES sharedspice.h
    HINTS ${NGSPICE_ROOT} $ENV{NGSPICE_ROOT}
    PATH_SUFFIXES include include/ngspice ngspice
)

find_library(
    NGSPICE_LIBRARY
    NAMES ngspice libngspice
    HINTS ${NGSPICE_ROOT} $ENV{NGSPICE_ROOT}
    PATH_SUFFIXES lib lib64
)

if (NOT NGSPICE_INCLUDE_DIR OR NOT NGSPICE_LIBRARY)
    message(FATAL_ERROR "Could not find ngspice shared library and headers. Build ngspice with --with-ngshared, then pass -DNGSPICE_ROOT=/path/to/install.")
endif()

add_library(ngspice_ffi SHARED src/ngspice_ffi.cpp)
target_include_directories(
    ngspice_ffi
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${NGSPICE_INCLUDE_DIR}
)
target_link_libraries(ngspice_ffi PRIVATE ${NGSPICE_LIBRARY})

set_target_properties(
    ngspice_ffi
    PROPERTIES
    OUTPUT_NAME ngspice_ffi
)

if (CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    target_link_directories(ngspice_ffi PRIVATE /opt/homebrew/lib /usr/local/lib)
    set_target_properties(
        ngspice_ffi
        PROPERTIES
        INSTALL_RPATH "@loader_path;@loader_path/../lib;/opt/homebrew/lib;/usr/local/lib"
    )
elseif (CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_directories(ngspice_ffi PRIVATE /usr/local/lib /usr/lib)
    set_target_properties(
        ngspice_ffi
        PROPERTIES
        INSTALL_RPATH "$ORIGIN:$ORIGIN/../lib:/usr/local/lib:/usr/lib"
    )
else()
    message(FATAL_ERROR "Unsupported platform for ngspice_ffi: ${CMAKE_SYSTEM_NAME}")
endif()
