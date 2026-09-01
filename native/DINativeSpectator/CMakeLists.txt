cmake_minimum_required(VERSION 3.21)
project(DINativeSpectator LANGUAGES CXX)

add_library(DINativeSpectator SHARED src/dllmain.cpp)
target_compile_features(DINativeSpectator PRIVATE cxx_std_17)
target_compile_definitions(DINativeSpectator PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
set_target_properties(DINativeSpectator PROPERTIES
    OUTPUT_NAME DINativeSpectator
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/bin")

if(MSVC)
    target_compile_options(DINativeSpectator PRIVATE /W4 /WX /permissive- /guard:cf)
    target_link_options(DINativeSpectator PRIVATE /DYNAMICBASE /NXCOMPAT /guard:cf)
endif()

add_executable(DINativeSpectatorLoadCycle tests/load_cycle.cpp)
target_compile_features(DINativeSpectatorLoadCycle PRIVATE cxx_std_17)
set_target_properties(DINativeSpectatorLoadCycle PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/bin")

add_executable(DINativeSpectatorDiagnosticHost tests/diagnostic_host.cpp)
target_compile_features(DINativeSpectatorDiagnosticHost PRIVATE cxx_std_17)
set_target_properties(DINativeSpectatorDiagnosticHost PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/bin")

# Stage 1 is a separate artifact so the verified Stage 0 no-op DLL remains
# byte-stable and available as a rollback point.
set(MINHOOK_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(MINHOOK_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/minhook EXCLUDE_FROM_ALL)
add_library(DINativeSpectatorStage1 SHARED src/diagnostic.cpp)
target_compile_features(DINativeSpectatorStage1 PRIVATE cxx_std_17)
target_compile_definitions(DINativeSpectatorStage1 PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(DINativeSpectatorStage1 PRIVATE minhook)
set_target_properties(DINativeSpectatorStage1 PROPERTIES
    OUTPUT_NAME DINativeSpectatorStage1
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/bin")
if(MSVC)
    target_compile_options(DINativeSpectatorStage1 PRIVATE /W4 /WX /permissive- /guard:cf)
    target_link_options(DINativeSpectatorStage1 PRIVATE /DYNAMICBASE /NXCOMPAT /guard:cf)
endif()

# Stage 2 is dedicated-server-only and narrowly hooks the stock
# ReadyToStartMatch implementation. It remains dormant until the Lua login
# designation creates a one-shot marker after assigning faction 210.
add_library(DINativeSpectatorStage2 SHARED src/readiness.cpp)
target_compile_features(DINativeSpectatorStage2 PRIVATE cxx_std_17)
target_compile_definitions(DINativeSpectatorStage2 PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(DINativeSpectatorStage2 PRIVATE minhook)
set_target_properties(DINativeSpectatorStage2 PROPERTIES
    OUTPUT_NAME DINativeSpectatorStage2
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/bin")
if(MSVC)
    target_compile_options(DINativeSpectatorStage2 PRIVATE /W4 /WX /permissive- /guard:cf)
    target_link_options(DINativeSpectatorStage2 PRIVATE /DYNAMICBASE /NXCOMPAT /guard:cf)
endif()
