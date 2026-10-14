# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

# google/visqol C++ API over libvisqol. Build libvisqol first:
#   zig build -Doptimize=ReleaseFast --prefix /path/to/prefix
#   cmake -S src/cpp -B build/cpp -DCMAKE_PREFIX_PATH=/path/to/prefix
# Consumers link `visqol::cpp` and keep upstream's include paths.
cmake_minimum_required(VERSION 3.20)
project(visqol_cpp VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(absl CONFIG REQUIRED)
find_package(protobuf CONFIG REQUIRED)
find_path(VISQOL_INCLUDE_DIR visqol.h REQUIRED)
find_library(VISQOL_LIBRARY NAMES visqol REQUIRED)

# Generate protos at src/proto/*.pb.h to match upstream's Bazel include paths.
set(PROTO_ROOT ${CMAKE_CURRENT_BINARY_DIR}/protoroot)
set(PROTO_OUT ${CMAKE_CURRENT_BINARY_DIR}/gen)
file(MAKE_DIRECTORY ${PROTO_ROOT}/src/proto ${PROTO_OUT})
set(PROTO_SRCS)
set(PROTO_HDRS)
foreach(p similarity_result visqol_config)
  configure_file(${CMAKE_CURRENT_SOURCE_DIR}/proto/${p}.proto ${PROTO_ROOT}/src/proto/${p}.proto COPYONLY)
  add_custom_command(
    OUTPUT ${PROTO_OUT}/src/proto/${p}.pb.cc ${PROTO_OUT}/src/proto/${p}.pb.h
    COMMAND protobuf::protoc --cpp_out=${PROTO_OUT} -I${PROTO_ROOT} ${PROTO_ROOT}/src/proto/${p}.proto
    DEPENDS ${PROTO_ROOT}/src/proto/${p}.proto
    VERBATIM)
  list(APPEND PROTO_SRCS ${PROTO_OUT}/src/proto/${p}.pb.cc)
  list(APPEND PROTO_HDRS ${PROTO_OUT}/src/proto/${p}.pb.h)
endforeach()

add_library(visqol_cpp src/visqol_compat.cc ${PROTO_SRCS})
add_library(visqol::cpp ALIAS visqol_cpp)
target_include_directories(visqol_cpp PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<BUILD_INTERFACE:${PROTO_OUT}>
  $<INSTALL_INTERFACE:include/visqol_cpp>
  ${VISQOL_INCLUDE_DIR})
target_link_libraries(visqol_cpp PUBLIC
  ${VISQOL_LIBRARY} protobuf::libprotobuf
  absl::status absl::statusor absl::strings absl::span)

include(CTest)
if(BUILD_TESTING)
  add_executable(visqol_cpp_test tests/compat_test.cc)
  target_link_libraries(visqol_cpp_test PRIVATE visqol::cpp)
  add_test(NAME visqol_cpp_test COMMAND visqol_cpp_test
           WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../..)
endif()

include(GNUInstallDirs)
install(TARGETS visqol_cpp EXPORT visqol_cpp-targets)
install(FILES include/visqol_api.h include/visqol_manager.h include/file_path.h
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/visqol_cpp)
install(FILES ${PROTO_HDRS} DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/visqol_cpp/src/proto)
