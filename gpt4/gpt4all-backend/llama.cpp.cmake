#
# Copyright (c) 2023 Nomic, Inc. All rights reserved.
#
# This software is licensed under the terms of the Software for Open Models License (SOM),
# version 1.0, as detailed in the LICENSE_SOM.txt file. A copy of this license should accompany
# this software. Except as expressly granted in the SOM license, all rights are reserved by Nomic, Inc.
#

cmake_minimum_required(VERSION 3.12) # Don't bump this version for no reason

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if (NOT XCODE AND NOT MSVC AND NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS "Debug" "Release" "MinSizeRel" "RelWithDebInfo")
endif()

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(LLAMA_STANDALONE ON)

    # configure project version
    # TODO
else()
    set(LLAMA_STANDALONE OFF)
endif()

if (EMSCRIPTEN)
    set(BUILD_SHARED_LIBS_DEFAULT OFF)

    option(LLAMA_WASM_SINGLE_FILE "llama: embed WASM inside the generated llama.js" ON)
else()
    if (MINGW)
        set(BUILD_SHARED_LIBS_DEFAULT OFF)
    else()
        set(BUILD_SHARED_LIBS_DEFAULT ON)
    endif()
endif()


#
# Option list
#
# some of the options here are commented out so they can be set "dynamically" before calling include_ggml()

# general
option(LLAMA_STATIC                 "llama: static link libraries"                          OFF)
option(LLAMA_NATIVE                 "llama: enable -march=native flag"                      OFF)
option(LLAMA_LTO                    "llama: enable link time optimization"                  OFF)

# debug
option(LLAMA_ALL_WARNINGS           "llama: enable all compiler warnings"                   ON)
option(LLAMA_ALL_WARNINGS_3RD_PARTY "llama: enable all compiler warnings in 3rd party libs" OFF)
option(LLAMA_GPROF                  "llama: enable gprof"                                   OFF)

# sanitizers
option(LLAMA_SANITIZE_THREAD        "llama: enable thread sanitizer"                        OFF)
option(LLAMA_SANITIZE_ADDRESS       "llama: enable address sanitizer"                       OFF)
option(LLAMA_SANITIZE_UNDEFINED     "llama: enable undefined sanitizer"                     OFF)

# instruction set specific
#option(LLAMA_AVX                    "llama: enable AVX"                                     ON)
#option(LLAMA_AVX2                   "llama: enable AVX2"                                    ON)
#option(LLAMA_AVX512                 "llama: enable AVX512"                                  OFF)
#option(LLAMA_AVX512_VBMI            "llama: enable AVX512-VBMI"                             OFF)
#option(LLAMA_AVX512_VNNI            "llama: enable AVX512-VNNI"                             OFF)
#option(LLAMA_FMA                    "llama: enable FMA"                                     ON)
# in MSVC F16C is implied with AVX2/AVX512
#if (NOT MSVC)
#    option(LLAMA_F16C               "llama: enable F16C"                                    ON)
#endif()

# 3rd party libs
option(LLAMA_ACCELERATE             "llama: enable Accelerate framework"                    ON)
option(LLAMA_OPENBLAS               "llama: use OpenBLAS"                                   OFF)
#option(LLAMA_CUBLAS                 "llama: use cuBLAS"                                     OFF)
#option(LLAMA_CLBLAST                "llama: use CLBlast"                                    OFF)
#option(LLAMA_METAL                  "llama: use Metal"                                      OFF)
#option(LLAMA_K_QUANTS               "llama: use k-quants"                                   ON)
set(LLAMA_BLAS_VENDOR "Generic" CACHE STRING "llama: BLAS library vendor")
set(LLAMA_CUDA_DMMV_X "32" CACHE STRING "llama: x stride for dmmv CUDA kernels")
set(LLAMA_CUDA_DMMV_Y "1" CACHE STRING  "llama: y block size for dmmv CUDA kernels")

#
# Compile flags
#

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED true)
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

if (NOT MSVC)
    if (LLAMA_SANITIZE_THREAD)
        add_compile_options(-fsanitize=thread)
        link_libraries(-fsanitize=thread)
    endif()

    if (LLAMA_SANITIZE_ADDRESS)
        add_compile_options(-fsanitize=address -fno-omit-frame-pointer)
        link_libraries(-fsanitize=address)
    endif()

    if (LLAMA_SANITIZE_UNDEFINED)
        add_compile_options(-fsanitize=undefined)
        link_libraries(-fsanitize=undefined)
    endif()
endif()

if (APPLE AND LLAMA_ACCELERATE)
    find_library(ACCELERATE_FRAMEWORK Accelerate)
    if (ACCELERATE_FRAMEWORK)
        message(STATUS "Accelerate framework found")

        add_compile_definitions(GGML_USE_ACCELERATE)
        set(LLAMA_EXTRA_LIBS ${LLAMA_EXTRA_LIBS} ${ACCELERATE_FRAMEWORK})
    else()
        message(WARNING "Accelerate framework not found")
    endif()
endif()

if (LLAMA_OPENBLAS)
    if (LLAMA_STATIC)
        set(BLA_STATIC ON)
    endif()

    set(BLA_VENDOR OpenBLAS)
    find_package(BLAS)
    if (BLAS_FOUND)
        message(STATUS "OpenBLAS found")

        add_compile_definitions(GGML_USE_OPENBLAS)
        add_link_options(${BLAS_LIBRARIES})
        set(LLAMA_EXTRA_LIBS ${LLAMA_EXTRA_LIBS} openblas)

        # find header file
        set(OPENBLAS_INCLUDE_SEARCH_PATHS
            /usr/include
            /usr/include/openblas
            /usr/include/openblas-base
            /usr/local/include
            /usr/local/include/openblas
            /usr/local/include/openblas-base
            /opt/OpenBLAS/include
            $ENV{OpenBLAS_HOME}
            $ENV{OpenBLAS_HOME}/include
            )
        find_path(OPENBLAS_INC NAMES cblas.h PATHS ${OPENBLAS_INCLUDE_SEARCH_PATHS})
        add_compile_options(-I${OPENBLAS_INC})
    else()
        message(WARNING "OpenBLAS not found")
    endif()
endif()

if (LLAMA_KOMPUTE)
    add_compile_definitions(VULKAN_HPP_DISPATCH_LOADER_DYNAMIC=1)
    find_package(Vulkan COMPONENTS glslc REQUIRED)
    find_program(glslc_executable NAMES glslc HINTS Vulkan::glslc)
    if (NOT glslc_executable)
        message(FATAL_ERROR "glslc not found")
    endif()

    set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp-mainline)

    function(compile_shader)
      set(options)
      set(oneValueArgs)
      set(multiValueArgs SOURCES)
      cmake_parse_arguments(compile_shader "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})
      foreach(source ${compile_shader_SOURCES})
        get_filename_component(OP_FILE ${source} NAME)
        set(spv_file ${CMAKE_CURRENT_BINARY_DIR}/${OP_FILE}.spv)
        add_custom_command(
            OUTPUT ${spv_file}
            DEPENDS ${LLAMA_DIR}/${source}
            COMMAND ${glslc_executable} --target-env=vulkan1.2 -o ${spv_file} ${LLAMA_DIR}/${source}
            COMMENT "Compiling ${source} to ${source}.spv"
        )

        get_filename_component(RAW_FILE_NAME ${spv_file} NAME)
        set(FILE_NAME "shader${RAW_FILE_NAME}")
        string(REPLACE ".comp.spv" ".h" HEADER_FILE ${FILE_NAME})
        string(TOUPPER ${HEADER_FILE} HEADER_FILE_DEFINE)
        string(REPLACE "." "_" HEADER_FILE_DEFINE "${HEADER_FILE_DEFINE}")
        set(OUTPUT_HEADER_FILE "${HEADER_FILE}")
        message(STATUS "${HEADER_FILE} generating ${HEADER_FILE_DEFINE}")
        if(CMAKE_GENERATOR MATCHES "Visual Studio") 
            add_custom_command(
              OUTPUT ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo "/*THIS FILE HAS BEEN AUTOMATICALLY GENERATED - DO NOT EDIT*/" > ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo \"\#ifndef ${HEADER_FILE_DEFINE}\" >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo \"\#define ${HEADER_FILE_DEFINE}\" >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo "namespace kp {" >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo "namespace shader_data {" >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_BINARY_DIR}/bin/${CMAKE_BUILD_TYPE}/xxd -i ${spv_file} >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo "}}" >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo \"\#endif // define ${HEADER_FILE_DEFINE}\" >> ${OUTPUT_HEADER_FILE}
              DEPENDS ${spv_file} xxd
              COMMENT "Converting to hpp: ${FILE_NAME} ${CMAKE_BINARY_DIR}/bin/${CMAKE_BUILD_TYPE}/xxd"
            )
        else()
            add_custom_command(
              OUTPUT ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo "/*THIS FILE HAS BEEN AUTOMATICALLY GENERATED - DO NOT EDIT*/" > ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo \"\#ifndef ${HEADER_FILE_DEFINE}\" >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo \"\#define ${HEADER_FILE_DEFINE}\" >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo "namespace kp {" >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo "namespace shader_data {" >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_BINARY_DIR}/bin/xxd -i ${spv_file} >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo "}}" >> ${OUTPUT_HEADER_FILE}
              COMMAND ${CMAKE_COMMAND} -E echo \"\#endif // define ${HEADER_FILE_DEFINE}\" >> ${OUTPUT_HEADER_FILE}
              DEPENDS ${spv_file} xxd
              COMMENT "Converting to hpp: ${FILE_NAME} ${CMAKE_BINARY_DIR}/bin/xxd"
            )
        endif()
      endforeach()
    endfunction()

    if (EXISTS "${LLAMA_DIR}/kompute/CMakeLists.txt")
        message(STATUS "Kompute found")
        add_subdirectory(${LLAMA_DIR}/kompute)

        # Compile our shaders
        compile_shader(SOURCES
          kompute/op_scale.comp
          kompute/op_add.comp
          kompute/op_addrow.comp
          kompute/op_mul.comp
          kompute/op_mulrow.comp
          kompute/op_silu.comp
          kompute/op_relu.comp
          kompute/op_gelu.comp
          kompute/op_softmax.comp
          kompute/op_norm.comp
          kompute/op_rmsnorm.comp
          kompute/op_diagmask.comp
          kompute/op_mul_mat_f16.comp
          kompute/op_mul_mat_q4_0.comp
          kompute/op_mul_mat_q4_1.comp
          kompute/op_getrows_f16.comp
          kompute/op_getrows_q4_0.comp
          kompute/op_getrows_q4_1.comp
          kompute/op_rope.comp
          kompute/op_cpy_f16_f16.comp
          kompute/op_cpy_f16_f32.comp
          kompute/op_cpy_f32_f16.comp
          kompute/op_cpy_f32_f32.comp
        )

        # Create a custom target for our generated shaders
        add_custom_target(generated_shaders DEPENDS
          shaderop_scale.h
          shaderop_add.h
          shaderop_addrow.h
          shaderop_mul.h
          shaderop_mulrow.h
          shaderop_silu.h
          shaderop_relu.h
          shaderop_gelu.h
          shaderop_softmax.h
          shaderop_norm.h
          shaderop_rmsnorm.h
          shaderop_diagmask.h
          shaderop_mul_mat_f16.h
          shaderop_mul_mat_q4_0.h
          shaderop_mul_mat_q4_1.h
          shaderop_getrows_f16.h
          shaderop_getrows_q4_0.h
          shaderop_getrows_q4_1.h
          shaderop_rope.h
          shaderop_cpy_f16_f16.h
          shaderop_cpy_f16_f32.h
          shaderop_cpy_f32_f16.h
          shaderop_cpy_f32_f32.h
        )

        # Create a custom command that depends on the generated_shaders
        add_custom_command(
            OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/ggml-vulkan.stamp
            COMMAND ${CMAKE_COMMAND} -E touch ${CMAKE_CURRENT_BINARY_DIR}/ggml-vulkan.stamp
            DEPENDS generated_shaders
            COMMENT "Ensuring shaders are generated before compiling ggml-vulkan.cpp"
        )

        # Add the stamp to the main sources to ensure dependency tracking
        set(GGML_SOURCES_KOMPUTE ${LLAMA_DIR}/ggml-vulkan.cpp ${LLAMA_DIR}/ggml-vulkan.h ${CMAKE_CURRENT_BINARY_DIR}/ggml-vulkan.stamp)
        add_compile_definitions(GGML_USE_KOMPUTE)
        set(LLAMA_EXTRA_LIBS ${LLAMA_EXTRA_LIBS} kompute)
        set(LLAMA_EXTRA_INCLUDES ${LLAMA_EXTRA_INCLUDES} ${CMAKE_BINARY_DIR})
    else()
        message(WARNING "Kompute not found")
    endif()
endif()

if (LLAMA_ALL_WARNINGS)
    if (NOT MSVC)
        set(c_flags
            -Wall
            -Wextra
            -Wpedantic
            -Wcast-qual
            -Wdouble-promotion
            -Wshadow
            -Wstrict-prototypes
            -Wpointer-arith
        )
        set(cxx_flags
            -Wall
            -Wextra
            -Wpedantic
            -Wcast-qual
            -Wno-unused-function
            -Wno-multichar
        )
    else()
        # todo : msvc
    endif()

    add_compile_options(
            "$<$<COMPILE_LANGUAGE:C>:${c_flags}>"
            "$<$<COMPILE_LANGUAGE:CXX>:${cxx_flags}>"
    )

endif()

if (MSVC)
    add_compile_definitions(_CRT_SECURE_NO_WARNINGS)

    if (BUILD_SHARED_LIBS)
        set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)
    endif()
endif()

if (LLAMA_LTO)
    include(CheckIPOSupported)
    check_ipo_supported(RESULT result OUTPUT output)
    if (result)
        set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
    else()
        message(WARNING "IPO is not supported: ${output}")
    endif()
endif()

# Architecture specific
# TODO: probably these flags need to be tweaked on some architectures
#       feel free to update the Makefile for your architecture and send a pull request or issue
message(STATUS "CMAKE_SYSTEM_PROCESSOR: ${CMAKE_SYSTEM_PROCESSOR}")
if (NOT MSVC)
    if (LLAMA_STATIC)
        add_link_options(-static)
        if (MINGW)
            add_link_options(-static-libgcc -static-libstdc++)
        endif()
    endif()
    if (LLAMA_GPROF)
        add_compile_options(-pg)
    endif()
    if (LLAMA_NATIVE)
        add_compile_options(-march=native)
    endif()
endif()

function(include_ggml DIRECTORY SUFFIX WITH_LLAMA)
    message(STATUS "Configuring ggml implementation target llama${SUFFIX} in ${CMAKE_CURRENT_SOURCE_DIR}/${DIRECTORY}")

    #
    # Build libraries
    #

    set(GGML_CUBLAS_USE NO)
    if (LLAMA_CUBLAS)
        cmake_minimum_required(VERSION 3.17)

        find_package(CUDAToolkit)
        if (CUDAToolkit_FOUND)
            set(GGML_CUBLAS_USE YES)
            message(STATUS "cuBLAS found")

            enable_language(CUDA)

            set(GGML_SOURCES_CUDA ${DIRECTORY}/ggml-cuda.cu ${DIRECTORY}/ggml-cuda.h)

            if (LLAMA_STATIC)
                set(LLAMA_EXTRA_LIBS ${LLAMA_EXTRA_LIBS} CUDA::cudart_static CUDA::cublas_static CUDA::cublasLt_static)
            else()
                set(LLAMA_EXTRA_LIBS ${LLAMA_EXTRA_LIBS} CUDA::cudart CUDA::cublas CUDA::cublasLt)
            endif()

        else()
            message(WARNING "cuBLAS not found")
        endif()
    endif()

    set(GGML_CLBLAST_USE NO)
    if (LLAMA_CLBLAST)
        find_package(CLBlast)
        if (CLBlast_FOUND)
            set(GGML_CLBLAST_USE YES)
            message(STATUS "CLBlast found")

            set(GGML_OPENCL_SOURCE_FILE ggml-opencl.cpp)
            if (NOT EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/${DIRECTORY}/${GGML_OPENCL_SOURCE_FILE})
                set(GGML_OPENCL_SOURCE_FILE ggml-opencl.c)
            endif()

            set(GGML_OPENCL_SOURCES ${DIRECTORY}/${GGML_OPENCL_SOURCE_FILE} ${DIRECTORY}/ggml-opencl.h)

            set(LLAMA_EXTRA_LIBS ${LLAMA_EXTRA_LIBS} clblast)
        else()
            message(WARNING "CLBlast not found")
        endif()
    endif()

    set(GGML_SOURCES_QUANT_K )
    set(GGML_METAL_SOURCES )
    if (LLAMA_K_QUANTS)
        set(GGML_SOURCES_QUANT_K
            ${DIRECTORY}/k_quants.h
            ${DIRECTORY}/k_quants.c)

        if (LLAMA_METAL)
            find_library(FOUNDATION_LIBRARY         Foundation              REQUIRED)
            find_library(METAL_FRAMEWORK            Metal                   REQUIRED)
            find_library(METALKIT_FRAMEWORK         MetalKit                REQUIRED)
            find_library(METALPERFORMANCE_FRAMEWORK MetalPerformanceShaders REQUIRED)

            set(GGML_METAL_SOURCES ${DIRECTORY}/ggml-metal.m ${DIRECTORY}/ggml-metal.h)
            # get full path to the file
            #add_compile_definitions(GGML_METAL_DIR_KERNELS="${CMAKE_CURRENT_SOURCE_DIR}/")

            # copy ggml-metal.metal to bin directory
            configure_file(${DIRECTORY}/ggml-metal.metal bin/ggml-metal.metal COPYONLY)

            set(LLAMA_EXTRA_LIBS ${LLAMA_EXTRA_LIBS}
                ${FOUNDATION_LIBRARY}
                ${METAL_FRAMEWORK}
                ${METALKIT_FRAMEWORK}
                ${METALPERFORMANCE_FRAMEWORK}
            )
        endif()
    endif()

    add_library(ggml${SUFFIX} OBJECT
                ${DIRECTORY}/ggml.c
                ${DIRECTORY}/ggml.h
                ${DIRECTORY}/ggml-alloc.c
                ${DIRECTORY}/ggml-alloc.h
                ${GGML_SOURCES_QUANT_K}
                ${GGML_SOURCES_CUDA}
                ${GGML_METAL_SOURCES}
                ${GGML_OPENCL_SOURCES}
                ${GGML_SOURCES_KOMPUTE})

    if (LLAMA_K_QUANTS)
        target_compile_definitions(ggml${SUFFIX} PUBLIC GGML_USE_K_QUANTS)
    endif()

    if (LLAMA_METAL AND GGML_METAL_SOURCES)
        target_compile_definitions(ggml${SUFFIX} PUBLIC GGML_USE_METAL GGML_METAL_NDEBUG)
    endif()
    target_include_directories(ggml${SUFFIX} PUBLIC ${DIRECTORY})
    target_compile_features(ggml${SUFFIX} PUBLIC c_std_11) # don't bump

    if (BUILD_SHARED_LIBS)
        set_target_properties(ggml${SUFFIX} PROPERTIES POSITION_INDEPENDENT_CODE ON)
    endif()

    if (WITH_LLAMA)
        # Backwards compatibility with old llama.cpp versions
        set(LLAMA_UTIL_SOURCE_FILE llama-util.h)
        if (NOT EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/${DIRECTORY}/${LLAMA_UTIL_SOURCE_FILE})
            set(LLAMA_UTIL_SOURCE_FILE llama_util.h)
        endif()

        add_library(llama${SUFFIX} STATIC
                    ${DIRECTORY}/llama.cpp
                    ${DIRECTORY}/llama.h
                    ${DIRECTORY}/${LLAMA_UTIL_SOURCE_FILE})

        if (LLAMA_METAL AND GGML_METAL_SOURCES)
            target_compile_definitions(llama${SUFFIX} PUBLIC GGML_USE_METAL GGML_METAL_NDEBUG)
        endif()
        target_include_directories(llama${SUFFIX} PUBLIC ${DIRECTORY})
        target_compile_features(llama${SUFFIX} PUBLIC cxx_std_11) # don't bump

        if (BUILD_SHARED_LIBS)
            set_target_properties(llama${SUFFIX} PROPERTIES POSITION_INDEPENDENT_CODE ON)
            target_compile_definitions(llama${SUFFIX} PRIVATE LLAMA_SHARED LLAMA_BUILD)
        endif()
    endif()

    if (GGML_SOURCES_CUDA)
        message(STATUS "GGML CUDA sources found, configuring CUDA architecture")
        set_property(TARGET ggml${SUFFIX} PROPERTY CUDA_ARCHITECTURES OFF)
        set_property(TARGET ggml${SUFFIX} PROPERTY CUDA_SELECT_NVCC_ARCH_FLAGS "Auto")
        if (WITH_LLAMA)
            set_property(TARGET llama${SUFFIX} PROPERTY CUDA_ARCHITECTURES OFF)
        endif()
    endif()

    if (GGML_CUBLAS_USE)
        target_compile_definitions(ggml${SUFFIX} PRIVATE
            GGML_USE_CUBLAS
            GGML_CUDA_DMMV_X=${LLAMA_CUDA_DMMV_X}
            GGML_CUDA_DMMV_Y=${LLAMA_CUDA_DMMV_Y})
        if (WITH_LLAMA)
            target_compile_definitions(llama${SUFFIX} PRIVATE
                GGML_USE_CUBLAS
                GGML_CUDA_DMMV_X=${LLAMA_CUDA_DMMV_X}
                GGML_CUDA_DMMV_Y=${LLAMA_CUDA_DMMV_Y})
        endif()
    endif()
    if (GGML_CLBLAST_USE)
        if (WITH_LLAMA)
            target_compile_definitions(llama${SUFFIX} PRIVATE GGML_USE_CLBLAST)
        endif()
        target_compile_definitions(ggml${SUFFIX} PRIVATE GGML_USE_CLBLAST)
    endif()

    if (${CMAKE_SYSTEM_PROCESSOR} MATCHES "arm" OR ${CMAKE_SYSTEM_PROCESSOR} MATCHES "aarch64")
        message(STATUS "ARM detected")
        if (MSVC)
            # TODO: arm msvc?
        else()
            if (${CMAKE_SYSTEM_PROCESSOR} MATCHES "aarch64")
                target_compile_options(ggml${SUFFIX} PRIVATE -mcpu=native)
            endif()
            # TODO: armv6,7,8 version specific flags
        endif()
    elseif (${CMAKE_SYSTEM_PROCESSOR} MATCHES "^(x86_64|i686|AMD64)$")
        message(STATUS "x86 detected")
        if (MSVC)
            if (LLAMA_AVX512)
                target_compile_options(ggml${SUFFIX} PRIVATE
                    $<$<COMPILE_LANGUAGE:C>:/arch:AVX512>
                    $<$<COMPILE_LANGUAGE:CXX>:/arch:AVX512>)
                # MSVC has no compile-time flags enabling specific
                # AVX512 extensions, neither it defines the
                # macros corresponding to the extensions.
                # Do it manually.
                if (LLAMA_AVX512_VBMI)
                    target_compile_definitions(ggml${SUFFIX} PRIVATE
                        $<$<COMPILE_LANGUAGE:C>:__AVX512VBMI__>
                        $<$<COMPILE_LANGUAGE:CXX>:__AVX512VBMI__>)
                endif()
                if (LLAMA_AVX512_VNNI)
                    target_compile_definitions(ggml${SUFFIX} PRIVATE
                        $<$<COMPILE_LANGUAGE:C>:__AVX512VNNI__>
                        $<$<COMPILE_LANGUAGE:CXX>:__AVX512VNNI__>)
                endif()
            elseif (LLAMA_AVX2)
                target_compile_options(ggml${SUFFIX} PRIVATE
                    $<$<COMPILE_LANGUAGE:C>:/arch:AVX2>
                    $<$<COMPILE_LANGUAGE:CXX>:/arch:AVX2>)
            elseif (LLAMA_AVX)
                target_compile_options(ggml${SUFFIX} PRIVATE
                    $<$<COMPILE_LANGUAGE:C>:/arch:AVX>
                    $<$<COMPILE_LANGUAGE:CXX>:/arch:AVX>)
            endif()
        else()
            if (LLAMA_F16C)
                target_compile_options(ggml${SUFFIX} PRIVATE -mf16c)
            endif()
            if (LLAMA_FMA)
                target_compile_options(ggml${SUFFIX} PRIVATE -mfma)
            endif()
            if (LLAMA_AVX)
                target_compile_options(ggml${SUFFIX} PRIVATE -mavx)
            endif()
            if (LLAMA_AVX2)
                target_compile_options(ggml${SUFFIX} PRIVATE -mavx2)
            endif()
            if (LLAMA_AVX512)
                target_compile_options(ggml${SUFFIX} PRIVATE -mavx512f)
                target_compile_options(ggml${SUFFIX} PRIVATE -mavx512bw)
            endif()
            if (LLAMA_AVX512_VBMI)
                target_compile_options(ggml${SUFFIX} PRIVATE -mavx512vbmi)
            endif()
            if (LLAMA_AVX512_VNNI)
                target_compile_options(ggml${SUFFIX} PRIVATE -mavx512vnni)
            endif()
        endif()
    else()
        # TODO: support PowerPC
        message(STATUS "Unknown architecture")
    endif()

    target_link_libraries(ggml${SUFFIX} PUBLIC Threads::Threads ${LLAMA_EXTRA_LIBS})
    if (WITH_LLAMA)
        target_link_libraries(llama${SUFFIX} PRIVATE ggml${SUFFIX} ${LLAMA_EXTRA_LIBS})
    endif()
endfunction()
