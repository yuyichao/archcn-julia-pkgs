#!/usr/bin/julia

include("utils.jl")

const context = Context()

struct MissingDepsInfo
    deps::Set{Base.UUID}
    weak_deps::Set{Base.UUID}
    unknown::Set{Base.UUID}
    function MissingDepsInfo()
        return new(Set{Base.UUID}(), Set{Base.UUID}(), Set{Base.UUID}())
    end
end

Base.isempty(info::MissingDepsInfo) =
    isempty(info.deps) && isempty(info.weak_deps) && isempty(info.unknown)

function check_missing_deps(ctx::Context, pkginfo, new_ver, out::MissingDepsInfo)
    stdlibs = get(Dict{String,Any}, ctx.global_info, "StdLibs")

    compat_info = Pkg.Registry.compat_info(pkginfo)[new_ver]
    for (uuid, ver) in compat_info
        if uuid == Pkg.Registry.JULIA_UUID || haskey(stdlibs, string(uuid))
            continue
        end
        uuid in keys(ctx.packages_info) && continue
        if !haskey(ctx.registry, uuid)
            push!(out.unknown, uuid)
            continue
        end
        push!(out.deps, uuid)
    end

    _weak_compat_info = Pkg.Registry.weak_compat_info(pkginfo)
    if _weak_compat_info === nothing
        return isempty(out.deps)
    end
    for (uuid, ver) in _weak_compat_info[new_ver]
        if uuid == Pkg.Registry.JULIA_UUID || haskey(stdlibs, string(uuid))
            continue
        end
        uuid in keys(ctx.packages_info) && continue
        if !haskey(ctx.registry, uuid)
            push!(out.unknown, uuid)
            continue
        end
        push!(out.weak_deps, uuid)
    end
    # Do not treat missing weak dependencies as hard break for now
    return isempty(out.deps)
end

struct PackageVersionInfo
    issues::Dict{VersionNumber,Vector{Any}}
    good_versions::Set{VersionNumber}
    PackageVersionInfo() =
        new(Dict{VersionNumber,Vector{Any}}(), Set{VersionNumber}())
end

function find_new_versions(ctx::Context, uuid, version)
    pkgentry = ctx.registry[uuid]
    pkginfo = Pkg.Registry.registry_info(pkgentry)
    arch_info = ctx.packages_info[uuid]
    is_jll = get(arch_info["Pkg"], "is_jll", false)

    pkg_ver_info = PackageVersionInfo()

    missing_deps_info = MissingDepsInfo()
    jll_changes = JLLChanges()
    for new_ver in keys(pkginfo.version_info)
        new_ver > version || continue
        ver_ok = check_missing_deps(ctx, pkginfo, new_ver, missing_deps_info)
        if !isempty(missing_deps_info)
            push!(get!(Vector{Any}, pkg_ver_info.issues, new_ver), missing_deps_info)
            missing_deps_info = MissingDepsInfo()
        end
        if is_jll
            ver_ok &= check_jll_content(ctx, pkginfo, arch_info, new_ver, jll_changes)
            if !isempty(jll_changes)
                push!(get!(Vector{Any}, pkg_ver_info.issues, new_ver),
                      jll_changes)
                jll_changes = JLLChanges()
            end
        end

        if ver_ok
            push!(pkg_ver_info.good_versions, new_ver)
        end
    end

    return pkg_ver_info
end

function scan(ctx::Context)
    for (uuid, arch_info) in ctx.packages_info
        find_new_versions(ctx, uuid, VersionNumber(arch_info["Status"]["version"]))
    end
end

scan(context)
