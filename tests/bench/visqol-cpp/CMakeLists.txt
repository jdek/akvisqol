# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

# tests/bench/google/visqol_google_bench.cc, unchanged, built against src/cpp/.
cmake_minimum_required(VERSION 3.20)
project(visqol_cpp_bench CXX)

set(BUILD_TESTING OFF)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../src/cpp visqol_cpp)

add_executable(visqol_cpp_bench ${CMAKE_CURRENT_SOURCE_DIR}/../google/visqol_google_bench.cc)
target_link_libraries(visqol_cpp_bench PRIVATE visqol::cpp)
# Empty model paths select libvisqol's embedded models.
target_compile_definitions(visqol_cpp_bench PRIVATE VISQOL_DEFAULT_MODEL="" VISQOL_DEFAULT_LATTICE_MODEL="")
install(TARGETS visqol_cpp_bench)
