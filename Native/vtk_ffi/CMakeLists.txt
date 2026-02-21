cmake_minimum_required(VERSION 3.18)
project(vtk_ffi LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if (CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(AUTOSAGE_PLATFORM_DARWIN TRUE)
elseif (CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(AUTOSAGE_PLATFORM_LINUX TRUE)
else()
    message(FATAL_ERROR "Unsupported platform for vtk_ffi: ${CMAKE_SYSTEM_NAME}")
endif()

set(VTK_COMPONENTS
    CommonCore
    CommonDataModel
    FiltersCore
    FiltersGeneral
    IOGeometry
    IOImage
    ImagingCore
    RenderingCore
    RenderingOpenGL2
)

find_package(
    VTK
    REQUIRED
    COMPONENTS
        ${VTK_COMPONENTS}
)

add_library(vtk_ffi SHARED src/vtk_ffi.cpp)
target_include_directories(vtk_ffi PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(vtk_ffi PRIVATE ${VTK_LIBRARIES})
set_target_properties(vtk_ffi PROPERTIES OUTPUT_NAME vtk_ffi)

if (AUTOSAGE_PLATFORM_DARWIN)
    target_include_directories(vtk_ffi PRIVATE /opt/homebrew/include /usr/local/include)
    target_link_directories(vtk_ffi PRIVATE /opt/homebrew/lib /usr/local/lib)
    set_target_properties(
        vtk_ffi
        PROPERTIES
        INSTALL_RPATH "@loader_path;@loader_path/../lib;/opt/homebrew/lib;/usr/local/lib"
    )
elseif (AUTOSAGE_PLATFORM_LINUX)
    target_link_directories(vtk_ffi PRIVATE /usr/local/lib /usr/lib)
    set_target_properties(
        vtk_ffi
        PROPERTIES
        INSTALL_RPATH "$ORIGIN:$ORIGIN/../lib:/usr/local/lib:/usr/lib"
    )

    # Prefer EGL for Linux headless rendering, fall back to OSMesa when available.
    find_package(OpenGL QUIET COMPONENTS OpenGL EGL)
    if (TARGET OpenGL::OpenGL)
        target_link_libraries(vtk_ffi PRIVATE OpenGL::OpenGL)
    endif()
    if (TARGET OpenGL::EGL)
        target_link_libraries(vtk_ffi PRIVATE OpenGL::EGL)
        target_compile_definitions(vtk_ffi PRIVATE AUTOSAGE_VTK_HAS_EGL=1)
    endif()

    find_library(
        OSMESA_LIBRARY
        NAMES OSMesa
        PATHS /usr/lib /usr/local/lib /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu
    )
    if (OSMESA_LIBRARY)
        target_link_libraries(vtk_ffi PRIVATE ${OSMESA_LIBRARY})
        target_compile_definitions(vtk_ffi PRIVATE AUTOSAGE_VTK_HAS_OSMESA=1)
    endif()

    if (NOT TARGET OpenGL::EGL AND NOT OSMESA_LIBRARY)
        message(WARNING "Neither EGL nor OSMesa was found; Linux headless VTK context creation may fail.")
    endif()
endif()

if(COMMAND vtk_module_autoinit)
    vtk_module_autoinit(
        TARGETS vtk_ffi
        MODULES ${VTK_LIBRARIES}
    )
endif()
