#!/usr/bin/julia

include("utils.jl")

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
        if !haskey(ctx.registry, uuid)
            push!(ctx.unknown_packages, uuid)
            continue
        end
        has_miss = true
        push!(missed_deps, uuid)
    end
    _weak_compat_info = Pkg.Registry.weak_compat_info(pkginfo)
    if _weak_compat_info === nothing
        return !has_miss
    end
    for (uuid, ver) in _weak_compat_info[new_ver]
        if uuid == Pkg.Registry.JULIA_UUID
            continue
        end
        uuid in keys(ctx.packages_info) && continue
        if !haskey(ctx.registry, uuid)
            push!(ctx.unknown_packages, uuid)
            continue
        end
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
