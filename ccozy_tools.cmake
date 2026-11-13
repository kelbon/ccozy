
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

option(CCOZY_CLANGD "create / update .clangd file in source directory of top level project" ON)
set(CCOZY_CLANGD_CXX_STANDARD 23 CACHE STRING "C++ standard for headers in .clangd file, 0 to not set standard")

# Creates "${CMAKE_SOURCE_DIR}/.clangd" or updates part of it between ccozy markers
# (other content of file is not changed):
#  * clangd uses compile_commands.json from build directory (last configured)
#  * headers (they have no compile commands) use C++ standard from CCOZY_CLANGD_CXX_STANDARD
# Does nothing if option CCOZY_CLANGD is OFF or compile_commands.json is not generated
# (CMAKE_EXPORT_COMPILE_COMMANDS is not enabled)
function(ccozy_generate_clangd_file)
  if(NOT CCOZY_CLANGD)
    return()
  endif()
  if(NOT CMAKE_EXPORT_COMPILE_COMMANDS)
    message(STATUS "ccozy: .clangd skipped, CMAKE_EXPORT_COMPILE_COMMANDS is not enabled")
    return()
  endif()
  set(clangd_file "${CMAKE_SOURCE_DIR}/.clangd")
  set(begin_marker "# >>> ccozy: generated on cmake configuration, do not edit")
  set(end_marker "# <<< ccozy")

  # relative path if build directory is inside of source directory, so file does not depend on machine
  file(RELATIVE_PATH database_dir "${CMAKE_SOURCE_DIR}" "${CMAKE_BINARY_DIR}")
  if(database_dir MATCHES "^[.][.]" OR IS_ABSOLUTE "${database_dir}")
    set(database_dir "${CMAKE_BINARY_DIR}")
  endif()

  # each `---` starts new fragment of config. Fragments are combined by clangd:
  # lists (Add) are joined, for single values (CompilationDatabase) last fragment in file wins
  set(block "${begin_marker}\n---\nCompileFlags:\n  CompilationDatabase: \"${database_dir}\"\n")
  if(CCOZY_CLANGD_CXX_STANDARD)
    set(std_flag "-std=c++${CCOZY_CLANGD_CXX_STANDARD}")
    # .h may be C header
    get_property(languages GLOBAL PROPERTY ENABLED_LANGUAGES)
    if("C" IN_LIST languages)
      set(header_regex ".*\\.(hpp|hh|hxx|h\\+\\+|ipp|tpp|inl)")
    else()
      set(header_regex ".*\\.(h|hpp|hh|hxx|h\\+\\+|ipp|tpp|inl)")
    endif()
    string(APPEND block "---\nIf:\n  PathMatch: '${header_regex}'\nCompileFlags:\n  Add: [\"${std_flag}\"]\n")
  endif()
  string(APPEND block "${end_marker}\n")

  if(NOT EXISTS "${clangd_file}")
    set(content "${block}")
  else()
    file(READ "${clangd_file}" content)
    string(FIND "${content}" "${begin_marker}" begin_pos)
    string(FIND "${content}" "${end_marker}" end_pos)
    if(begin_pos EQUAL -1 OR end_pos EQUAL -1 OR end_pos LESS begin_pos)
      # no ccozy part in file, add it to the end
      if(NOT content STREQUAL "" AND NOT content MATCHES "\n$")
        string(APPEND content "\n")
      endif()
      string(APPEND content "${block}")
    else()
      string(SUBSTRING "${content}" 0 ${begin_pos} before)
      string(LENGTH "${end_marker}" end_len)
      math(EXPR after_pos "${end_pos} + ${end_len}")
      string(SUBSTRING "${content}" ${after_pos} -1 after)
      # block ends with newline
      string(REGEX REPLACE "^\n" "" after "${after}")
      set(content "${before}${block}${after}")
    endif()
  endif()

  set(old_content "")
  if(EXISTS "${clangd_file}")
    file(READ "${clangd_file}" old_content)
  endif()
  if(content STREQUAL old_content)
    message(STATUS "ccozy: .clangd is up to date")
  else()
    file(WRITE "${clangd_file}" "${content}")
    message(STATUS "ccozy: .clangd updated, compilation database: ${database_dir}")
  endif()
endfunction()

# generates launch json file with launch config for each target in this project
# also creates / updates .clangd file (see ccozy_generate_clangd_file)
function(ccozy_on_configuration_end_vscode)

  if(NOT PROJECT_IS_TOP_LEVEL)
      message(STATUS "ccozy: skipped, ${PROJECT_NAME} is not top-level project")
      return()
  endif()

  ccozy_generate_clangd_file()
  ccozy_generate_launch_json_file()

endfunction()
