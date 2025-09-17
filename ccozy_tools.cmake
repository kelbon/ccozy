
include_guard(GLOBAL)

# visits all targets in your project         (if WHAT_VISIT == BUILDSYSTEM_TARGETS)
#                    or all imported targets (if WHAT_VISIT == IMPORTED_TARGETS)
# and invokes `visitor` with such arguments:
#   <name> <type> <binary_dir>
# WHAT_VISIT may be BUILDSYSTEM_TARGETS or IMPORTED_TARGETS
macro(ccozy_visit_project_targets visitor WHAT_VISIT)
    if(${WHAT_VISIT} STREQUAL "BUILDSYSTEM_TARGETS")
    elseif(${WHAT_VISIT} STREQUAL "IMPORTED_TARGETS")
    else()
        message(FATAL_ERROR
            "ccozy: invalid WHAT_VISIT='${WHAT_VISIT}'. Must be BUILDSYSTEM_TARGETS or IMPORTED_TARGETS.")
    endif()

    if(NOT COMMAND ${visitor})
        message(FATAL_ERROR "ccozy: visitor '${visitor}' not found")
    endif()

    macro(ccozy_collect dir)
        get_property(local_targets DIRECTORY "${dir}" PROPERTY ${WHAT_VISIT})

        foreach(tgt IN LISTS local_targets)
            if(NOT TARGET "${tgt}")
                continue()
            endif()

            get_target_property(tgt_type "${tgt}" TYPE)
            # skip utility targets
            if(${tgt_type} STREQUAL "UTILITY")
                continue()
            endif()

            # where target declared
            get_target_property(src_dir "${tgt}" SOURCE_DIR)
            if(NOT src_dir)
                continue()
            endif()

            if (${WHAT_VISIT} STREQUAL "BUILDSYSTEM_TARGETS")
                # skip targets ourside of ${CMAKE_SOURCE_DIR}
                file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${src_dir}")
                if(_rel MATCHES "^[.][.]")  # starts with `..`
                    continue()
                endif()
            endif()

            # binary directory corresponding to the target's source directory
            get_property(bin_dir DIRECTORY "${src_dir}" PROPERTY BINARY_DIR)

            # invoke visitor: <name> <type> <binary_dir>
            cmake_language(CALL ${visitor} "${tgt}" "${tgt_type}" "${bin_dir}")
        endforeach()

        # recursive
        get_property(subdirs DIRECTORY "${dir}" PROPERTY SUBDIRECTORIES)
        foreach(sub IN LISTS subdirs)
            ccozy_collect("${sub}")
        endforeach()
    endmacro()

    ccozy_collect("${CMAKE_SOURCE_DIR}")
endmacro()

# For each target created for your project adds configuration for running it into "${CMAKE_SOURCE_DIR}/.vscode/launch.json"
# Do not adds if configuration with name `<target_name> <binary_dir>` already exist in launch.json file
# its recomended to call `ccozy_generate_launch_json_file` when configuration ends
function(ccozy_generate_launch_json_file)
  set(launch_file "${CMAKE_SOURCE_DIR}/.vscode/launch.json")
  file(MAKE_DIRECTORY "${CMAKE_SOURCE_DIR}/.vscode")

  # use -B directiry as key in launch json configurations
  # so for each build directory targets are different
  file(RELATIVE_PATH RELATIVE_BINARY_DIR 
    ${CMAKE_SOURCE_DIR} 
    ${PROJECT_BINARY_DIR}
  )
  message(STATUS "ccozy: processing .vscode/launch.json with target configurations...")

  set(new_configs "")

  macro(append_launch_configuration name type binary_dir)
    if(${type} STREQUAL "EXECUTABLE")
        string(REGEX REPLACE "/$" "" binary_dir_clean "${binary_dir}")
        if(WIN32)
          set(exec_path "${binary_dir_clean}/${name}.exe")
        else()
          set(exec_path "${binary_dir_clean}/${name}")
        endif()
        
    if(WIN32)
        set(config_json
"{
    \"name\": \"${name} (${RELATIVE_BINARY_DIR})\",
    \"type\": \"cppvsdbg\",
    \"request\": \"launch\",
    \"program\": \"${exec_path}\",
    \"args\": [],
    \"stopAtEntry\": false,
    \"cwd\": \"${binary_dir_clean}\",
    \"environment\": [],
    \"console\": \"externalTerminal\"
}"
        )
    else()
        set(config_json
"{
    \"name\": \"${name} (${RELATIVE_BINARY_DIR})\",
    \"type\": \"cppdbg\",
    \"request\": \"launch\",
    \"program\": \"${exec_path}\",
    \"args\": [],
    \"stopAtEntry\": false,
    \"cwd\": \"${binary_dir_clean}\",
    \"environment\": [],
    \"externalConsole\": false,
    \"MIMode\": \"gdb\",
    \"setupCommands\": [
        {
            \"description\": \"Enable pretty-printing for gdb\",
            \"text\": \"-enable-pretty-printing\",
            \"ignoreFailures\": true
        },
        {
            \"description\": \"Set Disassembly Flavor to Intel\",
            \"text\": \"-gdb-set disassembly-flavor intel\",
            \"ignoreFailures\": true
        }
    ]
}"
        )
    endif()

        list(APPEND new_configs "${config_json}")
    endif()
  endmacro()

  ccozy_visit_project_targets(append_launch_configuration BUILDSYSTEM_TARGETS)

  if(NOT new_configs)
    message(STATUS "ccozy: no executable targets found, nothing to add to launch.json.")
    return()
  endif()

  if(NOT EXISTS ${launch_file})
    message(STATUS "ccozy: creating new .vscode/launch.json...")
    string(JOIN ",\n    " configs_joined ${new_configs})
    file(WRITE ${launch_file}
"{
    \"version\": \"0.2.0\",
    \"configurations\": [
    ${configs_joined}
    ]
}"
    )
  else()
    message(STATUS "ccozy: adding new configurations to existing .vscode/launch.json if not present...")
    file(READ ${launch_file} existing_content)
    set(existing_json "${existing_content}")

    # Get configurations array
    string(JSON configs_json ERROR_VARIABLE err GET "${existing_json}" "configurations")
    if(err)
      message(WARNING "ccozy: failed to get 'configurations' from existing launch.json: ${err}. Assuming empty array.")
      set(configs_json "[]")
    endif()

    # Check type
    string(JSON conf_type TYPE "${existing_json}" "configurations")
    if(NOT conf_type STREQUAL "ARRAY")
      message(WARNING "ccozy: 'configurations' is not an array in existing launch.json. Resetting to empty array.")
      set(configs_json "[]")
    endif()

    string(JSON num_configs LENGTH "${configs_json}")

    set(existing_names "")
    if(num_configs GREATER 0)
      math(EXPR last_index "${num_configs} - 1")
      foreach(i RANGE 0 ${last_index})
        string(JSON cfg_json GET "${configs_json}" ${i})
        string(JSON cfg_name ERROR_VARIABLE name_err GET "${cfg_json}" "name")
        if(name_err)
          message(WARNING "ccozy: configuration at index ${i} missing 'name': ${name_err}. Skipping.")
          continue()
        endif()
        list(APPEND existing_names "${cfg_name}")
      endforeach()
    endif()

    set(added FALSE)
    foreach(new_cfg_json IN LISTS new_configs)
      string(JSON new_name ERROR_VARIABLE new_name_err GET "${new_cfg_json}" "name")
      if(new_name_err)
        message(WARNING "ccozy: new configuration missing 'name': ${new_name_err}. Skipping.")
        continue()
      endif()
      if(NOT "${new_name}" IN_LIST existing_names)
        string(JSON configs_json SET "${configs_json}" ${num_configs} "${new_cfg_json}")
        math(EXPR num_configs "${num_configs} + 1")
        list(APPEND existing_names "${new_name}")
        set(added TRUE)
      endif()
    endforeach()

    if(added)
      string(JSON updated_json SET "${existing_json}" "configurations" "${configs_json}")
      file(WRITE ${launch_file} "${updated_json}")
      message(STATUS "ccozy: new configurations added successfully.")
    else()
      message(STATUS "ccozy: all configurations already exist, no changes made.")
    endif()
  endif()
endfunction()

# generates launch json file with launch config for each target in this project
# also REPLACES compile_commands.json in this directory with new (configurated now)
function(ccozy_on_configuration_end_vscode)

  if(NOT PROJECT_IS_TOP_LEVEL)
      message(STATUS "ccozy: skipped, ${PROJECT_NAME} is not top-level project")
      return()
  endif()

  set(src "${CMAKE_BINARY_DIR}/compile_commands.json")
  set(dst "${CMAKE_CURRENT_SOURCE_DIR}/compile_commands.json")

  if(NOT EXISTS "${src}")
      message(FATAL_ERROR "ccozy: compile_commands.json not found at: ${src}")
  endif()

  file(COPY_FILE "${src}" "${dst}" ONLY_IF_DIFFERENT)
  message(STATUS "ccozy: ${dst} replaced by ${src}")

  ccozy_generate_launch_json_file()

endfunction()
