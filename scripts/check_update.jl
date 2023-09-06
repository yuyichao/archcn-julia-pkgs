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

function todict(ctx::Context, info::MissingDepsInfo)
    res = Dict{String,Any}("type"=>"missing_deps")
    if !isempty(info.deps)
        res["deps"] = get_pkg_uuid_names(ctx, info.deps)
    end
    if !isempty(info.weak_deps)
        res["weak_deps"] = get_pkg_uuid_names(ctx, info.weak_deps)
    end
    if !isempty(info.unknown)
        res["unknown"] = sort!(collect(info.unknown))
    end
    return res
end

JLLWrappers_UUID = Base.UUID("692b3bcd-3c85-4b1f-b108-f13ce0eb3210")

function check_missing_deps(ctx::Context, pkginfo, new_ver, is_jll,
                            out::MissingDepsInfo)
    stdlibs = get(Dict{String,Any}, ctx.global_info, "StdLibs")

    compat_info = Pkg.Registry.compat_info(pkginfo)[new_ver]
    for (uuid, ver) in compat_info
        if uuid == Pkg.Registry.JULIA_UUID || haskey(stdlibs, string(uuid))
            continue
        end
        if is_jll && uuid == JLLWrappers_UUID
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
        if is_jll && uuid == JLLWrappers_UUID
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

struct ExternInfo
    deps_build::Int8 # -1: removed, 1: added, 0: unchanged
    artifacts::Int8
end

Base.isempty(info::ExternInfo) = info.deps_build == 0 && info.artifacts == 0

function todict(ctx::Context, info::ExternInfo)
    res = Dict{String,Any}("type"=>"extern")
    if info.deps_build != 0
        res["deps_build"] = info.deps_build
    end
    if info.artifacts != 0
        res["artifacts"] = info.artifacts
    end
    return res
end

function check_extern(ctx::Context, arch_info, new_ver)
    arch_info_pkg = arch_info["Pkg"]
    has_deps_build = get(arch_info_pkg, "has_deps_build", false)
    has_artifacts = get(arch_info_pkg, "has_artifacts", false)
    repopath = checkout_pkg_ver(ctx, Base.UUID(arch_info_pkg["uuid"]), new_ver)

    found_deps_build = isfile(joinpath(repopath, "deps/build.jl"))
    found_artifacts = isfile(joinpath(repopath, "Artifacts.toml"))
    return ExternInfo(found_deps_build - has_deps_build,
                      found_artifacts - has_artifacts)
end

struct CheckError
    e
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
        ver_ok = true

        try
            ver_ok &= check_missing_deps(ctx, pkginfo, new_ver, is_jll,
                                         missing_deps_info)
        catch
            ver_ok = false
            push!(get!(Vector{Any}, pkg_ver_info.issues, new_ver),
                  CheckError(current_exceptions()))
        end
        if !isempty(missing_deps_info)
            push!(get!(Vector{Any}, pkg_ver_info.issues, new_ver), missing_deps_info)
            missing_deps_info = MissingDepsInfo()
        end
        if is_jll
            try
                ver_ok &= check_jll_content(ctx, arch_info, new_ver, jll_changes)
            catch
                ver_ok = false
                push!(get!(Vector{Any}, pkg_ver_info.issues, new_ver),
                      CheckError(current_exceptions()))
            end
            if !isempty(jll_changes)
                push!(get!(Vector{Any}, pkg_ver_info.issues, new_ver),
                      jll_changes)
                jll_changes = JLLChanges()
            end
        else
            try
                extern_info = check_extern(ctx, arch_info, new_ver)
                if !isempty(extern_info)
                    ver_ok = false
                    push!(get!(Vector{Any}, pkg_ver_info.issues, new_ver),
                          extern_info)
                end
            catch
                ver_ok = false
                push!(get!(Vector{Any}, pkg_ver_info.issues, new_ver),
                      CheckError(current_exceptions()))
            end
        end

        if ver_ok
            push!(pkg_ver_info.good_versions, new_ver)
        end
    end

    return pkg_ver_info
end

struct PackageVersionInfo
    issues::Dict{VersionNumber,Vector{Any}}
    good_versions::Set{VersionNumber}
    PackageVersionInfo() =
        new(Dict{VersionNumber,Vector{Any}}(), Set{VersionNumber}())
end

function collect_messages(ctx::Context, uuid, info::PackageVersionInfo,
                          messages)
    arch_info = ctx.packages_info[uuid]
    if isempty(info.issues)
        delete!(arch_info, "Issues")
        return
    end
    empty_issue = []
    name = arch_info["Pkg"]["name"]
    old_issues = get(Dict{String,Any}, arch_info, "Issues")
    new_issues = Dict{String,Any}()
    for (ver, issues) in info.issues
        ver_str = string(ver)
        pkgprefix = "$(name)@$(ver_str) [$(uuid)]"
        for issue in issues
            if isa(issue, MissingDepsInfo)
                issue_dict = todict(ctx, issue)
                push!(get!(Vector{Any}, new_issues, ver_str), issue_dict)
                if issue_dict in get(old_issues, ver_str, empty_issue)
                    continue
                end
                push!(messages, "Missing dependencies for $(pkgprefix):\n$(sprint(TOML.print, issue_dict))")
            elseif isa(issue, JLLChanges)
                issue_dict = todict(ctx, issue)
                push!(get!(Vector{Any}, new_issues, ver_str), issue_dict)
                if issue_dict in get(old_issues, ver_str, empty_issue)
                    continue
                end
                push!(messages, "JLL changed for $(pkgprefix):\n$(sprint(TOML.print, issue_dict))")
            elseif isa(issue, ExternInfo)
                issue_dict = todict(ctx, issue)
                push!(get!(Vector{Any}, new_issues, ver_str), issue_dict)
                if issue_dict in get(old_issues, ver_str, empty_issue)
                    continue
                end
                push!(messages, "External dependencies changed for $(pkgprefix):\n$(sprint(TOML.print, issue_dict))")
            elseif isa(issue, CheckError)
                push!(messages,
                      "Error during version check for $(pkgprefix):\n$(sprint(print, issue.e))")
            else
                push!(messages, "Unknown issue for $(pkgprefix): $(issue)")
            end
        end
    end
    if isempty(new_issues)
        delete!(arch_info, "Issues")
    else
        arch_info["Issues"] = new_issues
    end
    return
end

function scan(ctx::Context)
    messages = String[]
    for (uuid, arch_info) in ctx.packages_info
        check_res = find_new_versions(ctx, uuid,
                                      VersionNumber(arch_info["Status"]["version"]))
        collect_messages(ctx, uuid, check_res, messages)
    end
    write_back_info(ctx)
end

scan(context)
