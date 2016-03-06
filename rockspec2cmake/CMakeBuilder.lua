local Template = require 'pl.text'.Template
local subst = require 'pl.template'.substitute

module("rockspec2cmake", package.seeall)

-- All valid supported_platforms from rockspec file and their cmake counterparts
local rock2cmake_platform =
{
    ["unix"] = "UNIX",
    ["windows"] = "WIN32",
    ["win32"] = "WIN32",
    ["cygwin"] = "CYGWIN",
    ["macosx"] = "APPLE",
    ["linux"] = "UNIX", -- ?
    ["freebsd"] = "UNIX" -- ?
}

local ident = "    "

local intro = Template[[
# Generated Cmake file begin
cmake_minimum_required(VERSION 3.1)

project(${package_name} C CXX)

find_package(Lua)

## INSTALL DEFAULTS (Relative to CMAKE_INSTALL_PREFIX)
# Primary paths
set(INSTALL_BIN bin CACHE PATH "Where to install binaries to.")
set(INSTALL_LIB lib CACHE PATH "Where to install libraries to.")
set(INSTALL_ETC etc CACHE PATH "Where to store configuration files")
set(INSTALL_SHARE share CACHE PATH "Directory for shared data.")

set(INSTALL_LMOD ${dollar}{INSTALL_LIB}/lua CACHE PATH "Directory to install Lua modules.")
set(INSTALL_CMOD ${dollar}{INSTALL_LIB}/lua CACHE PATH "Directory to install Lua binary modules.")

]]

local fatal_error = Template[[
message(FATAL_ERROR "${message}")

]]

local unsupported_platform_check = Template [[
if (${platform})
    message(FATAL_ERROR "Unsupported platform (your platform was explicitly marked as not supported)")
endif()

]]

local supported_platform_check = Template [[
if (${expr})
    message(FATAL_ERROR "Unsupported platform (your platform is not in list of supported platforms)")
endif()

]]

local set_variable = Template [[
set(${name} ${value})
]]

local platform_specific_block = Template[[
if (${platform})
${definitions}
endif()

]]

local build_install_copy = Template[[
install(FILES ${dollar}{BUILD_COPY_DIRECTORIES} DESTINATION ${dollar}{CMAKE_INSTALL_PREFIX})
install(DIRECTORY ${dollar}{BUILD_INSTALL_LUA} DESTINATION ${dollar}{INSTALL_LMOD})
install(DIRECTORY ${dollar}{BUILD_INSTALL_LIB} DESTINATION ${dollar}{INSTALL_LIB})
install(DIRECTORY ${dollar}{BUILD_INSTALL_CONF} DESTINATION ${dollar}{INSTALL_ETC})
install(DIRECTORY ${dollar}{BUILD_INSTALL_BIN} DESTINATION ${dollar}{INSTALL_BIN})

]]

local install_lua_module = Template[[
install(FILES ${dollar}{${name}_SOURCES} DESTINATION ${dollar}{INSTALL_LMOD}/${dest} RENAME ${new_name})
]]

local cxx_module = Template [[
add_library(${name} ${dollar}{${name}_SOURCES})

foreach(LIBRARY ${dollar}{${name}_LIBRARIES})
    find_library(${dollar}{LIBRARY} ${dollar}{LIBRARY} ${dollar}{${name}_LIBDIRS})
endforeach(LIBRARY)

target_include_directories(${name} PRIVATE ${dollar}{${name}_INCDIRS})
target_compile_definitions(${name} PRIVATE ${dollar}{${name}_DEFINES})
target_link_libraries(${name} PRIVATE ${dollar}{${name}_LIBRARIES})
install(TARGETS ${name} DESTINATION ${dollar}{INSTALL_CMOD})

]]

-- CMakeBuilder
CMakeBuilder = {}

function CMakeBuilder:new(o, package_name)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    -- Tables with string values, for *_platforms tables, only values in
    -- rock2cmake_platform are inserted
    self.errors = {}
    self.supported_platforms = {}
    self.unsupported_platforms = {}

    -- Variables created from rockspec definitions, ["variable_name"] = "value"
    --
    -- Variables not depending on module name have their names formed from rockspec
    -- table hierarchy with dots replaced by underscores, for example BUILD_INSTALL_LUA
    --
    -- Variables depending on module name have form of
    -- MODULENAME_{SOURCES|LIBRARIES|DEFINES|INCDIRS|LIBDIRS}
    self.cmake_variables = {}
    self.override_cmake_variables = {}

    -- Tables containing only names of targets, override_*_targets can contain default
    -- targets, target is platform specific only if it is contained in override_*_targets and not in
    -- corresponding targets table
    self.lua_targets = {}
    self.override_lua_targets = {}
    self.cxx_targets = {}
    self.override_cxx_targets = {}

    self.package_name = package_name
    return o
end

function CMakeBuilder:platform_valid(platform)
    if rock2cmake_platform[platform] == nil then
        fatal_error("CMake alternative to platform '" .. platform .. "' was not defined," ..
            "cmake actions for this platform were not generated")
        return nil
    end

    return true
end

function CMakeBuilder:fatal_error(message)
    table.insert(self.errors, message)
end

function CMakeBuilder:add_unsupported_platform(platform)
    if platform_valid(platform) then
        table.insert(self.unsupported_platforms, platform)
    end
end

function CMakeBuilder:add_supported_platform(platform)
    if platform_valid(platform) then
        table.insert(self.supported_platforms, platform)
    end
end

function CMakeBuilder:set_cmake_variable(name, value, platform)
    if platform ~= nil then
        if platform_valid(platform) then
            self.override_cmake_variables[platform][name] = value
        end
    else
        self.cmake_variables[name] = value
    end
end

function CMakeBuilder:add_lua_module(name, platform)
    if platform ~= nil then
        if platform_valid(platform) then
            table.insert(self.lua_targets[platform], name)
        end
    else
        table.insert(tbl.override_lua_targets, name)
    end
end

function CMakeBuilder:add_cxx_target(name, platform)
    if platform ~= nil then
        if platform_valid(platform) then
            table.insert(self.cxx_targets[platform], name)
        end
    else
        table.insert(self.override_cxx_targets, name)
    end
end

function CMakeBuilder:generate()
    local res = ""

    res = res .. intro:substitute({package_name = self.package_name, dollar = "$"})

    -- Print all fatal errors at the beginning
    for _, error_msg in pairs(self.errors) do
        res = res .. fatal_error:substitute({message = error_msg})
    end

    -- Unsupported platforms
    for _, plat in pairs(self.unsupported_platforms) do
        res = res .. unsupported_platform_check:substitute({platform = rock2cmake_platform[plat]})
    end

    -- Supported platforms
    if #self.supported_platforms ~= 0 then
        local supported_platforms_check_str = ""
        for _, plat in pairs(self.supported_platforms) do
            if supported_platforms_check_str == "" then
                supported_platforms_check_str = "NOT " .. rock2cmake_platform[plat]
            else
                supported_platforms_check_str = supported_platforms_check_str .. " AND NOT " .. rock2cmake_platform[plat]
            end
        end

        res = res .. supported_platform_check:substitute({expr = supported_platforms_check_str})
    end

    -- Default (not overriden) variables
    for name, value in pairs(self.cmake_variables) do
        res = res .. set_variable:substitute({name = name, value = value})
    end

    -- Platform overrides if present
    for platform, variables in pairs(self.override_cmake_variables) do
        local definitions = ""
        for name, value in pairs(variables) do
            definitions = definitions .. ident .. set_variable:substitute({name = name, value = value})
        end

        res = res .. platform_specific_block:substitute(platform = platform, definitions = definitions)
    end

    -- install.{lua|conf|bin|lib} and copy_directories
    res = res .. build_install_copy:substitute({dollar = "$"})

    -- Lua targets, install only
    for _, name in pairs(self.lua_targets) do
        -- Force install file as name.lua, rename if needed
        res = res .. install_lua_module:substitute({name = name, dest = name:gsub("%.", "/"),
            new_name = name:match("([^.]+)$") .. ".lua", dollar = "$"})
    end

    -- Platform specific Lua targets
    for platform, targets in pairs(self.override_lua_targets) do
        local definitions = ""
        for _, name in pairs(targets) do
            if self.lua_targets[name] == nil then
                -- Force install file as name.lua, rename if needed
                definitions = definitions .. ident .. install_lua_module:substitute({name = name, dest = name:gsub("%.", "/"),
                    new_name = name:match("([^.]+)$") .. ".lua", dollar = "$"})
            end
        end

        if definitions ~= "" then
            res = res .. platform_specific_block:substitute(platform = platform, definitions = definitions)
        end
    end

    -- Cxx targets
    for _, name in pairs(self.cxx_targets) do
        res = res .. cxx_module:substitute({name = name, dollar = "$"})
    end

    -- Platform specific cxx targets
    for platform, targets in pairs(self.override_cxx_targets) do
        local definitions = ""
        for _, name in pairs(targets) do
            if self.cxx_targets[name] == nil then
                res = res .. cxx_module:substitute({name = name, dollar = "$"})
            end
        end

        if definitions ~= "" then
            res = res .. platform_specific_block:substitute(platform = platform, definitions = definitions)
        end
    end

    return res
end

return CMakeBuilder
