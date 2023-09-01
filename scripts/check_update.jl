#!/usr/bin/julia

using Pkg
using TOML

include("git_utils.jl")
include("jll_utils.jl")

function find_general_registry()
    Pkg.Registry.update("General")
    for reg in Pkg.Registry.reachable_registries()
        if reg.name == "General"
            return reg
        end
    end
end

function load_packages(pkgsdir)
    res = Dict{Base.UUID,Any}()
    for dir in readdir(pkgsdir, join=true)
        try
            d = TOML.parsefile(joinpath(dir, "info.toml"))
            res[Base.UUID(d["Pkg"]["uuid"])] = d
        catch e
            @error e
        end
    end
    return res
end

struct Context
    pkgsdir::String
    workdir::String
    registry::Pkg.Registry.RegistryInstance
    packages_info::Dict{Base.UUID,Any}
    messages::Vector{String}
    function Context()
        pkgsdir = joinpath(@__DIR__, "../pkgs")
        workdir = get(ENV, "JL_ARCHCN_WORKDIR",
                      joinpath(Base.DEPOT_PATH[1], "archcn"))
        mkpath(workdir)
        registry = find_general_registry()
        packages_info = load_packages(pkgsdir)
        return new(pkgsdir, workdir, registry, packages_info, String[])
    end
end

const context = Context()

function check_missing_deps(ctx::Context, pkginfo, new_ver,
                            missed_deps, missed_weak_deps)
    compat_info = Pkg.Registry.compat_info(pkginfo)[new_ver]
    has_miss = false
    for (uuid, ver) in compat_info
        if uuid == Pkg.Registry.JULIA_UUID
            continue
        end
        uuid in keys(ctx.packages_info) && continue
        has_miss = true
        push!(missed_deps, uuid)
    end
    _weak_compat_info = Pkg.Registry.weak_compat_info(pkginfo)
    if weak_compat_info === nothing
        return !has_miss
    end
    for (uuid, ver) in _weak_compat_info[new_ver]
        if uuid == Pkg.Registry.JULIA_UUID
            continue
        end
        uuid in keys(ctx.packages_info) && continue
        # Do not treat missing weak dependencies as hard break for now
        push!(missed_weak_deps, uuid)
    end
    return !has_miss
end

function _get_full_missed_deps_info(ctx::Context, missed_deps)
    info = Dict{String,Any}[]
    for dep_uuid in missed_deps
        dep_entry = ctx.registry[dep_uuid]
        push!(info, Dict{String,Any}("name"=>dep_entry.name,
                                     "uuid"=>dep_uuid))
    end
    sort!(info, by=x->(x["name"], x["uuid"]))
    return info
end

function find_new_versions(ctx::Context, uuid, version)
    pkgentry = ctx.registry[uuid]
    pkginfo = Pkg.Registry.registry_info(pkgentry)
    arch_info = ctx.packages_info[uuid]
    missed_deps = Set{Base.UUID}()
    missed_weak_deps = Set{Base.UUID}()
    for new_ver in keys(pkginfo.version_info)
        new_ver > version || continue
        check_missing_deps(ctx, pkginfo, new_ver, missed_deps, missed_weak_deps)
    end
    if !(isempty(missed_deps) && isempty(missed_weak_deps))
        missed_deps_section = get!(Dict{String,Any}, arch_info, "MissedDeps")
        missed_deps_info = _get_full_missed_deps_info(ctx, missed_deps)
        missed_weak_deps_info = _get_full_missed_deps_info(ctx, missed_weak_deps)
        if get(missed_deps_section, "deps", nothing) != missed_deps_info ||
            get(missed_deps_section, "weakdeps", nothing) != missed_weak_deps_info

            missed_deps_section["deps"] = missed_deps_info
            missed_deps_section["weakdeps"] = missed_weak_deps_info
            push!(ctx.messages,
                  "Missing dependencies for $(pkgentry.name) [$(pkgentry.uuid)]:\n$(sprint(TOML.print, missed_deps_section))")
        end
    end
end

function scan(ctx::Context)
    for (uuid, arch_info) in ctx.packages_info
        find_new_versions(ctx, uuid, VersionNumber(arch_info["Status"]["version"]))
    end
end

scan(context)
