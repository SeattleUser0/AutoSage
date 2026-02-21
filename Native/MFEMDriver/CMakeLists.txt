cmake_minimum_required(VERSION 3.18)
project(mfem_driver LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)

find_package(MFEM REQUIRED)
find_package(nlohmann_json QUIET)

add_executable(
    mfem-driver
    Solvers/AMRLaplace.cpp
    Solvers/AnisotropicDiffusion.cpp
    Solvers/Advection.cpp
    Solvers/AcousticWave.cpp
    Solvers/CompressibleEuler.cpp
    Solvers/DPGLaplace.cpp
    Solvers/Elastodynamics.cpp
    Solvers/DarcyFlow.cpp
    Solvers/Eigenvalue.cpp
    Solvers/FractionalPDE.cpp
    Solvers/ElectromagneticModal.cpp
    Solvers/ElectromagneticScattering.cpp
    Solvers/Electromagnetics.cpp
    Solvers/Electrostatics.cpp
    Solvers/JouleHeating.cpp
    main.cpp
    Solvers/HeatTransfer.cpp
    Solvers/Hyperelasticity.cpp
    Solvers/IncompressibleElasticity.cpp
    Solvers/LinearElasticity.cpp
    Solvers/Magnetostatics.cpp
    Solvers/NavierStokes.cpp
    Solvers/SurfacePDE.cpp
    Solvers/StokesFlow.cpp
    Solvers/StructuralModal.cpp
    Solvers/TransientMaxwell.cpp
)
if (TARGET MFEM::mfem)
    target_link_libraries(mfem-driver PRIVATE MFEM::mfem)
elseif (TARGET mfem)
    target_link_libraries(mfem-driver PRIVATE mfem)
else()
    target_link_libraries(mfem-driver PRIVATE ${MFEM_LIBRARIES})
    target_include_directories(mfem-driver PRIVATE ${MFEM_INCLUDE_DIRS})
endif()

if (TARGET nlohmann_json::nlohmann_json)
    target_link_libraries(mfem-driver PRIVATE nlohmann_json::nlohmann_json)
else()
    message(STATUS "nlohmann_json package not found; expecting <nlohmann/json.hpp> on include path.")
endif()

if (BUILD_TESTING)
    add_executable(
        mfem-driver-structural-modal-fallback-test
        tests/StructuralModalFallbackIntegrationTest.cpp
    )

    if (TARGET nlohmann_json::nlohmann_json)
        target_link_libraries(mfem-driver-structural-modal-fallback-test PRIVATE nlohmann_json::nlohmann_json)
    endif()

    add_test(
        NAME mfem_driver_structural_modal_fallback_integration
        COMMAND
            mfem-driver-structural-modal-fallback-test
            $<TARGET_FILE:mfem-driver>
    )

    add_executable(
        mfem-driver-electromagnetic-modal-test
        tests/ElectromagneticModalIntegrationTest.cpp
    )

    if (TARGET nlohmann_json::nlohmann_json)
        target_link_libraries(mfem-driver-electromagnetic-modal-test PRIVATE nlohmann_json::nlohmann_json)
    endif()

    add_test(
        NAME mfem_driver_electromagnetic_modal_integration
        COMMAND
            mfem-driver-electromagnetic-modal-test
            $<TARGET_FILE:mfem-driver>
    )
    set_tests_properties(
        mfem_driver_electromagnetic_modal_integration
        PROPERTIES SKIP_RETURN_CODE 77
    )

    add_executable(
        mfem-driver-electromagnetic-scattering-test
        tests/ElectromagneticScatteringIntegrationTest.cpp
    )

    if (TARGET nlohmann_json::nlohmann_json)
        target_link_libraries(mfem-driver-electromagnetic-scattering-test PRIVATE nlohmann_json::nlohmann_json)
    endif()

    add_test(
        NAME mfem_driver_electromagnetic_scattering_integration
        COMMAND
            mfem-driver-electromagnetic-scattering-test
            $<TARGET_FILE:mfem-driver>
    )
    set_tests_properties(
        mfem_driver_electromagnetic_scattering_integration
        PROPERTIES SKIP_RETURN_CODE 77
    )

    add_executable(
        mfem-driver-joule-heating-test
        tests/JouleHeatingIntegrationTest.cpp
    )

    if (TARGET nlohmann_json::nlohmann_json)
        target_link_libraries(mfem-driver-joule-heating-test PRIVATE nlohmann_json::nlohmann_json)
    endif()

    add_test(
        NAME mfem_driver_joule_heating_integration
        COMMAND
            mfem-driver-joule-heating-test
            $<TARGET_FILE:mfem-driver>
    )
    set_tests_properties(
        mfem_driver_joule_heating_integration
        PROPERTIES SKIP_RETURN_CODE 77
    )

    add_executable(
        mfem-driver-surface-pde-test
        tests/SurfacePDEIntegrationTest.cpp
    )

    if (TARGET nlohmann_json::nlohmann_json)
        target_link_libraries(mfem-driver-surface-pde-test PRIVATE nlohmann_json::nlohmann_json)
    endif()

    add_test(
        NAME mfem_driver_surface_pde_integration
        COMMAND
            mfem-driver-surface-pde-test
            $<TARGET_FILE:mfem-driver>
    )
    set_tests_properties(
        mfem_driver_surface_pde_integration
        PROPERTIES SKIP_RETURN_CODE 77
    )

    add_executable(
        mfem-driver-incompressible-elasticity-test
        tests/IncompressibleElasticityIntegrationTest.cpp
    )

    if (TARGET nlohmann_json::nlohmann_json)
        target_link_libraries(mfem-driver-incompressible-elasticity-test PRIVATE nlohmann_json::nlohmann_json)
    endif()

    add_test(
        NAME mfem_driver_incompressible_elasticity_integration
        COMMAND
            mfem-driver-incompressible-elasticity-test
            $<TARGET_FILE:mfem-driver>
    )
    set_tests_properties(
        mfem_driver_incompressible_elasticity_integration
        PROPERTIES SKIP_RETURN_CODE 77
    )
endif()
