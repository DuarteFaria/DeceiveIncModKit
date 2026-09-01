cmake_minimum_required(VERSION 3.21)
project(DINativeSpectator LANGUAGES CXX)

# Stage 0 (no-op load test) and Stage 1 (read-only diagnostic hook) were removed
# once Stage 2 superseded them; their test harnesses went with them. Only the
# two modules the shipping profiles inject are built here.
set(MINHOOK_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(MINHOOK_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/minhook EXCLUDE_FROM_ALL)

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

# Stage 3 is dedicated-server-only and hooks UObject::ProcessEvent to invoke
# parameterless UFunctions on the game thread and to trace RPCs. It is inert
# until Lua drops a one-shot invoke/trace marker. The spectator free/follow
# functions it was built for turned out to be compiled-out stubs, but it remains
# the only game-thread invoker available for any non-stubbed function.
add_library(DINativeSpectatorStage3 SHARED src/invoker.cpp)
target_compile_features(DINativeSpectatorStage3 PRIVATE cxx_std_17)
target_compile_definitions(DINativeSpectatorStage3 PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(DINativeSpectatorStage3 PRIVATE minhook)
set_target_properties(DINativeSpectatorStage3 PROPERTIES
    OUTPUT_NAME DINativeSpectatorStage3
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/bin")
if(MSVC)
    target_compile_options(DINativeSpectatorStage3 PRIVATE /W4 /WX /permissive- /guard:cf)
    target_link_options(DINativeSpectatorStage3 PRIVATE /DYNAMICBASE /NXCOMPAT /guard:cf)
endif()
