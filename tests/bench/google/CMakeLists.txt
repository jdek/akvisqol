# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

# Upstream ViSQOL (minus main.cc) plus a timing driver. Source trees come from
# `nix build .#google-visqol`. Without TFLITE_PREFIX the lattice mapper is stubbed.
cmake_minimum_required(VERSION 3.20)
project(google_visqol_bench C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(VISQOL_SRC "" CACHE PATH "google/visqol source tree")
set(LIBSVM_SRC "" CACHE PATH "libsvm v324 source tree")
set(PFFFT_SRC "" CACHE PATH "pffft source tree")
set(ARMADILLO_INCLUDE "" CACHE PATH "Armadillo include/ directory (headers only, as upstream)")
set(TFLITE_PREFIX "" CACHE PATH "TensorFlow Lite static install (tflite.nix); empty: stub the lattice mapper")
foreach(v VISQOL_SRC LIBSVM_SRC PFFFT_SRC ARMADILLO_INCLUDE)
  if(NOT ${v})
    message(FATAL_ERROR "${v} must be set")
  endif()
endforeach()

# Upstream's Bazel build has no LTO, so out-of-line AMatrix accessors stay calls in hot loops.
option(GOOGLE_VISQOL_LTO "Build with link-time optimisation" OFF)
if(GOOGLE_VISQOL_LTO)
  set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
endif()
option(GOOGLE_VISQOL_PYTHON "Also build upstream's visqol_lib_py Python module" OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(absl CONFIG REQUIRED)
find_package(protobuf CONFIG REQUIRED)

# So upstream's `#include "src/proto/x.pb.h"` resolves.
set(PROTO_OUT ${CMAKE_CURRENT_BINARY_DIR}/gen)
file(MAKE_DIRECTORY ${PROTO_OUT}/src/proto)
set(PROTO_SRCS)
foreach(p similarity_result visqol_config)
  set(cc ${PROTO_OUT}/src/proto/${p}.pb.cc)
  add_custom_command(
    OUTPUT ${cc} ${PROTO_OUT}/src/proto/${p}.pb.h
    COMMAND protobuf::protoc --cpp_out=${PROTO_OUT} -I${VISQOL_SRC} ${VISQOL_SRC}/src/proto/${p}.proto
    DEPENDS ${VISQOL_SRC}/src/proto/${p}.proto
    VERBATIM)
  list(APPEND PROTO_SRCS ${cc})
endforeach()

file(GLOB VISQOL_CC ${VISQOL_SRC}/src/*.cc)
list(FILTER VISQOL_CC EXCLUDE REGEX "/main\\.cc$")
if(NOT TFLITE_PREFIX)
  list(FILTER VISQOL_CC EXCLUDE REGEX "/tflite_quality_mapper\\.cc$")
  list(APPEND VISQOL_CC stub/tflite_quality_mapper.cc)
endif()

add_library(google_visqol OBJECT
  ${VISQOL_CC}
  ${PROTO_SRCS}
  ${LIBSVM_SRC}/svm.cpp
  ${PFFFT_SRC}/pffft.c)
if(TFLITE_PREFIX)
  # TFLite's archives (its abseil is in its own inline namespace), less
  # the fft2d variants TFLite does not link, which redefine fftsg's symbols.
  file(GLOB TFLITE_LIBS ${TFLITE_PREFIX}/lib/*.a)
  list(FILTER TFLITE_LIBS EXCLUDE REGEX "libfft2d_(fft4f2d|shrtdct|fftsg3d)\\.a$")
  target_include_directories(google_visqol PUBLIC ${TFLITE_PREFIX}/include)
  target_link_libraries(google_visqol PUBLIC ${TFLITE_LIBS})
  # Upstream's mapper gets absl::StrCat transitively under Bazel.
  set_source_files_properties(${VISQOL_SRC}/src/tflite_quality_mapper.cc PROPERTIES
    COMPILE_OPTIONS "-include;absl/strings/str_cat.h")
else()
  # Shadows upstream's TFLite header.
  target_include_directories(google_visqol PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/stub)
endif()
target_include_directories(google_visqol PUBLIC
  ${VISQOL_SRC}
  ${VISQOL_SRC}/src/include
  ${VISQOL_SRC}/src/proto
  ${PROTO_OUT}
  ${LIBSVM_SRC}
  ${PFFFT_SRC}
  ${ARMADILLO_INCLUDE})
target_link_libraries(google_visqol PUBLIC
  protobuf::libprotobuf
  absl::status absl::statusor absl::strings absl::synchronization
  absl::span absl::memory absl::raw_logging_internal absl::optional
  absl::flags absl::flags_parse absl::flags_usage)

add_executable(visqol_google_bench visqol_google_bench.cc)
target_link_libraries(visqol_google_bench PRIVATE google_visqol)
install(TARGETS visqol_google_bench)

include(GNUInstallDirs)
set(MODEL_DIR ${CMAKE_INSTALL_FULL_DATADIR}/google-visqol)
set(LATTICE_MODEL lattice_tcditugenmeetpackhref_ls2_nl60_lr12_bs2048_learn.005_ep2400_train1_7_raw.tflite)
install(FILES ${VISQOL_SRC}/model/libsvm_nu_svr_model.txt ${VISQOL_SRC}/model/${LATTICE_MODEL}
        DESTINATION ${MODEL_DIR})
target_compile_definitions(visqol_google_bench PRIVATE
  VISQOL_DEFAULT_MODEL="${MODEL_DIR}/libsvm_nu_svr_model.txt"
  VISQOL_DEFAULT_LATTICE_MODEL="${MODEL_DIR}/${LATTICE_MODEL}")

if(GOOGLE_VISQOL_PYTHON)
  # Upstream's setup.py layout.
  find_package(Python COMPONENTS Interpreter Development.Module REQUIRED)
  find_package(pybind11 CONFIG REQUIRED)
  find_package(pybind11_abseil CONFIG REQUIRED)
  find_package(pybind11_protobuf CONFIG REQUIRED)
  pybind11_add_module(visqol_lib_py MODULE ${VISQOL_SRC}/python/visqol_lib_py.cc)
  target_link_libraries(visqol_lib_py PRIVATE google_visqol
    pybind11_abseil::absl_casters pybind11_abseil::status_casters
    pybind11_protobuf::pybind11_native_proto_caster)

  set(PY_OUT ${CMAKE_CURRENT_BINARY_DIR}/pb2)
  file(MAKE_DIRECTORY ${PY_OUT})
  set(PB2)
  foreach(p similarity_result visqol_config)
    add_custom_command(
      OUTPUT ${PY_OUT}/${p}_pb2.py
      COMMAND protobuf::protoc --python_out=${PY_OUT} -I${VISQOL_SRC}/src/proto ${VISQOL_SRC}/src/proto/${p}.proto
      DEPENDS ${VISQOL_SRC}/src/proto/${p}.proto
      VERBATIM)
    list(APPEND PB2 ${PY_OUT}/${p}_pb2.py)
  endforeach()
  add_custom_target(visqol_pb2 ALL DEPENDS ${PB2})

  set(PY_DEST ${GOOGLE_VISQOL_PYTHON_SITE}/visqol)
  install(TARGETS visqol_lib_py DESTINATION ${PY_DEST})
  install(FILES ${PB2} DESTINATION ${PY_DEST}/pb2)
  install(FILES ${VISQOL_SRC}/model/libsvm_nu_svr_model.txt ${VISQOL_SRC}/model/${LATTICE_MODEL}
          DESTINATION ${PY_DEST}/model)
  install(CODE "file(TOUCH \${CMAKE_INSTALL_PREFIX}/${PY_DEST}/__init__.py \${CMAKE_INSTALL_PREFIX}/${PY_DEST}/pb2/__init__.py \${CMAKE_INSTALL_PREFIX}/${PY_DEST}/model/__init__.py)")
endif()
