#!/usr/bin/julia

using Pkg
using TOML

include("Resolve/Resolve.jl")

const project_toml_names = ("Project.toml", "JuliaProject.toml")

_get(d, key, default) = if d === nothing
    return default
else
    return get(d, key, default)
end

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
    paths = Dict{Base.UUID,String}()
    for dir in readdir(pkgsdir, join=true)
        isdir(dir) || continue
        try
            d = TOML.parsefile(joinpath(dir, "info.toml"))
            uuid = Base.UUID(d["Pkg"]["uuid"])
            res[uuid] = d
            paths[uuid] = dir
        catch e
            @error e
        end
    end
    return res, paths
end

function get_pkg_uuids(registry::Pkg.Registry.RegistryInstance, pkg)
    if length(pkg) == 36 && contains(pkg, "-")
        return [Base.UUID(pkg)]
    end
    return Pkg.Registry.uuids_from_name(registry, pkg)
end

function get_unique_uuid(reg_or_ctx, pkg)
    uuids = get_pkg_uuids(reg_or_ctx, pkg)
    if length(uuids) == 0
        error("Package $(name) not found in registry")
    elseif length(uuids) > 1
        error("Package $(name) not unique in registry")
    end
    return uuids[1]
end

struct RemoveDeps
    version::Pkg.Versions.VersionSpec
    remove::Vector{Base.UUID}
end

# These are stored in global info instead of the package info
# since we may need this before we add the package
# and won't have a package info to add it to
function load_remove_deps(registry, global_info)
    remove_deps = Dict{Base.UUID,Vector{RemoveDeps}}()

    _remove_deps = _get(get(global_info, "Overrides", nothing), "RemoveDeps", nothing)
    if _remove_deps === nothing
        return remove_deps
    end

    for _r in _remove_deps
        uuid = get_unique_uuid(registry, _r["pkg"])
        rs = get!(remove_deps, uuid) do
            return RemoveDeps[]
        end
        push!(rs, RemoveDeps(Pkg.Versions.semver_spec(_r["version"]),
                             [get_unique_uuid(registry, p) for p in _r["remove"]]))
    end

    return remove_deps
end

struct DepsVersionOvr
    version::Pkg.Versions.VersionSpec
    dep::Base.UUID
    depversion::Pkg.Versions.VersionSpec
end

function load_deps_version_ovr(registry, global_info)
    deps_version_ovr = Dict{Base.UUID,Vector{DepsVersionOvr}}()

    _deps_version_ovr = _get(get(global_info, "Overrides", nothing),
                             "DepsVersion", nothing)
    if _deps_version_ovr === nothing
        return deps_version_ovr
    end

    for _r in _deps_version_ovr
        uuid = get_unique_uuid(registry, _r["pkg"])
        rs = get!(deps_version_ovr, uuid) do
            return DepsVersionOvr[]
        end
        push!(rs, DepsVersionOvr(Pkg.Versions.semver_spec(_r["version"]),
                                 get_unique_uuid(registry, _r["dep"]),
                                 Pkg.Versions.semver_spec(_r["depversion"])))
    end

    return deps_version_ovr
end

struct Context
    pkgsdir::String
    workdir::String
    registry::Pkg.Registry.RegistryInstance
    packages_info::Dict{Base.UUID,Any}
    global_info::Dict{String,Any}
    package_paths::Dict{Base.UUID,String}
    remove_deps::Dict{Base.UUID,Vector{RemoveDeps}}
    deps_version_ovr::Dict{Base.UUID,Vector{DepsVersionOvr}}
    _packages_info::Dict{Base.UUID,Any}
    _global_info::Dict{String,Any}
    function Context()
        pkgsdir = joinpath(@__DIR__, "../pkgs")
        workdir = get(ENV, "JL_ARCHCN_WORKDIR",
                      joinpath(Base.DEPOT_PATH[1], "archcn"))
        mkpath(workdir)
        registry = find_general_registry()
        packages_info, paths = load_packages(pkgsdir)
        global_info = TOML.parsefile(joinpath(pkgsdir, "global.toml"))
        return new(pkgsdir, workdir, registry, packages_info, global_info, paths,
                   load_remove_deps(registry, global_info),
                   load_deps_version_ovr(registry, global_info),
                   deepcopy(packages_info), deepcopy(global_info))
    end
end

function write_back_info(ctx::Context)
    changed = false
    if ctx.global_info != ctx._global_info
        changed = true
        open(joinpath(ctx.pkgsdir, "global.toml"), "w") do io
            TOML.print(io, ctx.global_info)
        end
    end
    for (k, v) in ctx.packages_info
        if v == get(ctx._packages_info, k, nothing)
            continue
        end
        changed = true
        open(joinpath(ctx.package_paths[k], "info.toml"), "w") do io
            TOML.print(io, v)
        end
    end
    return changed
end

function get_pkg_uuid_names(ctx::Context, pkgs)
    info = Dict{String,Any}[]
    for uuid in pkgs
        entry = ctx.registry[uuid]
        push!(info, Dict{String,Any}("name"=>entry.name,
                                     "uuid"=>string(uuid)))
    end
    sort!(info, by=x->(x["name"], x["uuid"]))
    return info
end

function checkout_pkg_ver(ctx::Context, uuid, ver)
    pkgentry = ctx.registry[uuid]
    pkginfo = Pkg.Registry.registry_info(pkgentry)
    name = pkgentry.name
    url = pkginfo.repo
    hash = pkginfo.version_info[ver].git_tree_sha1.bytes
    workdir = joinpath(ctx.workdir, "gitcache")
    return LibGit2.with(get_repo(url, name, workdir)) do repo
        reset_tree(repo, hash)
        return LibGit2.workdir(repo)
    end
end

include("git_utils.jl")
include("jll_utils.jl")

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

const JLLWrappers_UUID = Base.UUID("692b3bcd-3c85-4b1f-b108-f13ce0eb3210")

function get_compat_info(ctx::Context, pkgentry)
    pkginfo = Pkg.Registry.registry_info(pkgentry)
    compat_infos = Pkg.Registry.compat_info(pkginfo)
    remove_deps = get(ctx.remove_deps, pkgentry.uuid, nothing)
    if remove_deps !== nothing
        for r in remove_deps
            for (ver, compat_info) in compat_infos
                ver in r.version || continue
                for d in r.remove
                    delete!(compat_info, d)
                end
            end
        end
    end
    deps_version_ovr = get(ctx.deps_version_ovr, pkgentry.uuid, nothing)
    if deps_version_ovr !== nothing
        for r in deps_version_ovr
            for (ver, compat_info) in compat_infos
                ver in r.version || continue
                if r.dep in keys(compat_info)
                    compat_info[r.dep] = r.depversion
                end
            end
        end
    end
    return compat_infos
end

function check_missing_deps(ctx::Context, pkgentry, new_ver, is_jll,
                            out::MissingDepsInfo)
    stdlibs = get(Dict{String,Any}, ctx.global_info, "StdLibs")
    pkginfo = Pkg.Registry.registry_info(pkgentry)

    compat_info = get_compat_info(ctx, pkgentry)[new_ver]
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
    # Do not treat missing weak dependencies as hard break
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

struct PkgCommitMissing
    tree_hash::String
end

function todict(ctx::Context, info::PkgCommitMissing)
    res = Dict{String,Any}("type"=>"commit_missing")
    res["hash"] = info.tree_hash
    return res
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
    had_issues = haskey(arch_info, "Issues")

    missing_deps_info = MissingDepsInfo()
    jll_changes = JLLChanges()
    for new_ver in keys(pkginfo.version_info)
        new_ver >= version || continue
        if new_ver == version && !had_issues
            # Only rescan current version if we had some issue for this package
            # to see if it is resolved.
            continue
        end
        ver_ok = true

        try
            ver_ok &= check_missing_deps(ctx, pkgentry, new_ver, is_jll,
                                         missing_deps_info)
        catch
            @show current_exceptions()
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
                @show current_exceptions()
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
                @show current_exceptions()
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
            elseif isa(issue, PkgCommitMissing)
                issue_dict = todict(ctx, issue)
                push!(get!(Vector{Any}, new_issues, ver_str), issue_dict)
                if issue_dict in get(old_issues, ver_str, empty_issue)
                    continue
                end
                push!(messages, "Package commit not found for $(pkgprefix):\n$(sprint(TOML.print, issue_dict))")
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

function resolve_new_versions(ctx::Context, check_results)
    @info "Computing new versions"

    compat = Dict{Base.UUID,Dict{VersionNumber,
                                 Dict{Base.UUID,Pkg.Versions.VersionSpec}}}()
    compat_weak = Dict{Base.UUID,Dict{VersionNumber,Set{Base.UUID}}}()
    uuid_to_name = Dict{Base.UUID,String}()
    reqs = Dict{Base.UUID,Pkg.Versions.VersionSpec}()
    fixed = Dict{Base.UUID,Resolve.Fixed}()

    ver_ub = Pkg.Versions.VersionBound("*")

    for (uuid, arch_info) in ctx.packages_info
        versions = check_results[uuid].good_versions
        name = arch_info["Pkg"]["name"]
        uuid_to_name[uuid] = name
        cur_ver = VersionNumber(arch_info["Status"]["version"])
        reqs[uuid] = Pkg.Versions.VersionSpec(Pkg.Versions.VersionRange(
            Pkg.Versions.VersionBound(cur_ver), ver_ub))

        pkgentry = ctx.registry[uuid]
        pkginfo = Pkg.Registry.registry_info(pkgentry)

        push!(versions, cur_ver)

        _compat = Dict{VersionNumber,Dict{Base.UUID,Pkg.Versions.VersionSpec}}()
        compat[uuid] = _compat

        compat_info = get_compat_info(ctx, pkgentry)

        # deps = Set{Base.UUID}()
        for ver in versions
            # empty!(deps)
            deps = Set{Base.UUID}()
            for (vrange, vdeps) in pkginfo.deps
                ver in vrange || continue
                union!(deps, values(vdeps))
            end
            __compat = Dict{Base.UUID,Pkg.Versions.VersionSpec}()
            _compat[ver] = __compat
            if haskey(compat_info, ver)
                for (dep_uuid, dep_ver) in compat_info[ver]
                    if haskey(ctx.packages_info, dep_uuid) && (dep_uuid in deps)
                        dep_pkgentry = get(ctx.registry, dep_uuid, nothing)
                        if (dep_pkgentry !== nothing &&
                            endswith(dep_pkgentry.name, "_jll"))
                            __compat[dep_uuid] = Pkg.Versions.VersionSpec("*")
                        else
                            __compat[dep_uuid] = dep_ver
                        end
                    end
                end
            end
        end
    end

    graph = Resolve.Graph(compat, compat_weak, uuid_to_name, reqs, fixed,
                              true, nothing)
    for (uuid, ver) in Resolve.resolve(graph)
        arch_info = ctx.packages_info[uuid]
        arch_info_status = arch_info["Status"]
        old_version = VersionNumber(arch_info_status["version"])
        if ver == old_version
            continue
        end
        issues = check_results[uuid].issues
        filter!(kv->kv.first >= ver, issues)
        arch_info["Status"]["version"] = string(ver)
        res = find_package_commit(ctx, uuid, ver, arch_info)
        if res isa PkgCommitMissing
            push!(get!(Vector{Any}, issues, ver), res)
        else
            verfile = joinpath(ctx.package_paths[uuid], "version")
            write(verfile, "version: $(ver)@$(res)\n")
        end
    end
end

function find_package_commit(ctx::Context, uuid, ver, arch_info)
    package_path = get(ctx.package_paths, uuid, nothing)
    last_commit = nothing
    if package_path !== nothing
        verfile = joinpath(package_path, "version")
        if isfile(verfile)
            verstrs = split(read(verfile, String), '@')
            if length(verstrs) == 2
                hash_str = strip(verstrs[2])
                if length(hash_str) == 40
                    last_commit = hash_str
                end
            end
        end
    end
    pkgentry = ctx.registry[uuid]
    pkginfo = Pkg.Registry.registry_info(pkgentry)
    name = pkgentry.name
    url = pkginfo.repo
    tree = pkginfo.version_info[ver].git_tree_sha1
    commit = find_package_commit(url, name, joinpath(ctx.workdir, "gitcache"),
                                 _get(_get(arch_info, "Pkg", nothing),
                                      "branch", nothing),
                                 tree.bytes, last_commit)
    if commit === nothing
        return PkgCommitMissing(string(tree))
    else
        return commit
    end
end

function scan(ctx::Context)
    messages = String[]
    check_results = Dict{Base.UUID,PackageVersionInfo}()
    npackages = length(ctx.packages_info)
    for (idx, (uuid, arch_info)) in enumerate(ctx.packages_info)
        pkgentry = ctx.registry[uuid]
        @info "($(idx)/$(npackages)) Checking $(pkgentry.name) [$uuid]"
        check_res = find_new_versions(ctx, uuid,
                                      VersionNumber(arch_info["Status"]["version"]))
        check_results[uuid] = check_res
    end
    resolve_new_versions(ctx, check_results)
    @info "Collecting messages"
    for (uuid, arch_info) in ctx.packages_info
        collect_messages(ctx, uuid, check_results[uuid], messages)
    end
    @info "Writing back info"
    changed = write_back_info(ctx)
    return messages, changed
end

struct JLLPkgInfo
    products::Dict{String,Vector{Tuple{String,String}}}
end

struct NormalPkgInfo
    deps_build::Bool
    artifacts::Bool
end

struct FullPkgInfo
    name::String
    uuid::Base.UUID
    url::String
    ver::VersionNumber
    commit::String

    extra::Union{JLLPkgInfo,NormalPkgInfo}
end

function collect_full_pkg_info(ctx::Context, uuid, ver)
    pkgentry = ctx.registry[uuid]
    pkginfo = Pkg.Registry.registry_info(pkgentry)
    name = pkgentry.name
    url = pkginfo.repo
    @info "Collecting info for package $(name) [$(uuid)] @ $(ver)"
    tree = pkginfo.version_info[ver].git_tree_sha1
    # TODO: guess branch name
    commit = find_package_commit(ctx, uuid, ver,
                                 get(ctx.packages_info, uuid, nothing))
    if commit isa PkgCommitMissing
        @warn "Cannot find commit hash for $(name)[$(uuid)]@$(ver)"
        exit(1)
    else
        commit = string(commit)
    end

    repopath = checkout_pkg_ver(ctx, uuid, ver)

    if endswith(name, "_jll")
        extra = JLLPkgInfo(Dict(k=>sort!([(name, path) for (name, path) in v])
                                for (k, v) in collect_jll_products(repopath)))
    else
        deps_build = isfile(joinpath(repopath, "deps/build.jl"))
        artifacts = isfile(joinpath(repopath, "Artifacts.toml"))
        extra = NormalPkgInfo(deps_build, artifacts)
    end
    return FullPkgInfo(name, uuid, url, ver, commit, extra)
end

function resolve_all_dependencies(ctx::Context, uuids)
    uuids = Set{Base.UUID}(uuids)
    for (uuid, v) in ctx.packages_info
        push!(uuids, uuid)
    end
    todo_pkgs = copy(uuids)
    done_pkgs = Set{Base.UUID}()

    compat = Dict{Base.UUID,Dict{VersionNumber,
                                 Dict{Base.UUID,Pkg.Versions.VersionSpec}}}()
    compat_weak = Dict{Base.UUID,Dict{VersionNumber,Set{Base.UUID}}}()
    uuid_to_name = Dict{Base.UUID,String}()
    reqs = Dict{Base.UUID,Pkg.Versions.VersionSpec}()
    fixed = Dict{Base.UUID,Resolve.Fixed}()

    ver_ub = Pkg.Versions.VersionBound("*")
    stdlibs = get(Dict{String,Any}, ctx.global_info, "StdLibs")

    function process_package(uuid)
        pkgentry = ctx.registry[uuid]
        pkginfo = Pkg.Registry.registry_info(pkgentry)
        name = pkgentry.name
        uuid_to_name[uuid] = name

        arch_info = get(ctx.packages_info, uuid, nothing)
        arch_info_status = _get(arch_info, "Status", nothing)
        old_ver = VersionNumber(_get(arch_info_status, "version", "0"))

        if uuid in uuids
            reqs[uuid] = Pkg.Versions.VersionSpec(Pkg.Versions.VersionRange(
                Pkg.Versions.VersionBound(old_ver), ver_ub))
        end

        _compat = Dict{VersionNumber,Dict{Base.UUID,Pkg.Versions.VersionSpec}}()
        compat[uuid] = _compat

        compat_info = get_compat_info(ctx, pkgentry)

        # deps = Set{Base.UUID}()
        for ver in keys(pkginfo.version_info)
            ver >= old_ver || continue
            # empty!(deps)
            deps = Set{Base.UUID}()
            for (vrange, vdeps) in pkginfo.deps
                ver in vrange || continue
                union!(deps, values(vdeps))
            end

            __compat = Dict{Base.UUID,Pkg.Versions.VersionSpec}()
            _compat[ver] = __compat

            for (dep_uuid, dep_ver) in compat_info[ver]
                if dep_uuid == Pkg.Registry.JULIA_UUID ||
                    haskey(stdlibs, string(dep_uuid))
                    continue
                end
                if dep_uuid == JLLWrappers_UUID
                    continue
                end
                if !(dep_uuid in deps)
                    continue
                end
                if !haskey(ctx.registry, dep_uuid)
                    @warn "Unkown package UUID $(dep_uuid) as dependency for $(name)[$(uuid)]@$(ver)"
                    continue
                end
                if !(dep_uuid in done_pkgs)
                    push!(todo_pkgs, dep_uuid)
                end
                dep_pkgentry = get(ctx.registry, dep_uuid, nothing)
                if (dep_pkgentry !== nothing &&
                    endswith(dep_pkgentry.name, "_jll"))
                    __compat[dep_uuid] = Pkg.Versions.VersionSpec("*")
                else
                    __compat[dep_uuid] = dep_ver
                end
            end
        end
    end

    while !isempty(todo_pkgs)
        uuid = pop!(todo_pkgs)
        push!(done_pkgs, uuid)
        process_package(uuid)
    end

    graph = Resolve.Graph(compat, compat_weak, uuid_to_name, reqs, fixed,
                              true, nothing)
    return Resolve.resolve(graph)
end

function collect_all_pkg_info(ctx::Context, versions)
    res = Dict{Base.UUID,FullPkgInfo}()
    for (uuid, ver) in versions
        arch_info = get(ctx.packages_info, uuid, nothing)
        arch_info_status = _get(arch_info, "Status", nothing)
        old_ver = VersionNumber(_get(arch_info_status, "version", "0"))
        if old_ver == ver
            continue
        end
        res[uuid] = collect_full_pkg_info(ctx, uuid, ver)
    end
    return res
end

function write_additional_extra_info(ctx::Context, arch_info, pkgdir,
                                     extra_info::JLLPkgInfo)
    products = get!(Dict{String,Vector{String}},
                    get!(Dict{String,Any}, arch_info, "JLL"), "products")
    for key in ("library", "executable", "file")
        new_ps = get(extra_info.products, key, nothing)
        ps = get(products, key, nothing)
        jlltoml_key = key
        if key == "executable"
            jlltoml_key = "binary"
        end

        if new_ps !== nothing
            new_p_names = [p[1] for p in new_ps]
            if ps !== nothing
                add = setdiff(Set(new_p_names), ps)
                remove = setdiff(ps, new_p_names)
                resize!(ps, length(new_ps))
                ps .= new_p_names
                if isempty(add) && isempty(remove)
                    continue
                end
                open(joinpath(pkgdir, "jll.toml"), "a") do io
                    if !isempty(add)
                        for p in new_ps
                            if p[1] in add
                                println(io)
                                println(io, "[[$(jlltoml_key)]]")
                                println(io, "name = \"$(p[1])\"")
                                if p[1] != p[2]
                                    println(io, "file = \"$(p[2])\"")
                                end
                            end
                        end
                    end
                    if !isempty(remove)
                        for p in remove
                            println(io, "# $(jlltoml_key) product removed: $(p)")
                        end
                    end
                end
            else
                products[key] = new_p_names
                open(joinpath(pkgdir, "jll.toml"), "a") do io
                    for p in new_ps
                        println(io)
                        println(io, "[[$(jlltoml_key)]]")
                        println(io, "name = \"$(p[1])\"")
                        if p[1] != p[2]
                            println(io, "file = \"$(p[2])\"")
                        end
                    end
                end
            end
        elseif ps !== nothing
            delete!(products, key)
            open(joinpath(pkgdir, "jll.toml"), "a") do io
                for p in ps
                    println(io, "# $(key) product removed: $(p)")
                end
            end
        end
    end
end

function write_additional_extra_info(ctx::Context, arch_info, pkgdir,
                                     extra_info::NormalPkgInfo)
    arch_info_pkg = arch_info["Pkg"]
    has_deps_build = get(arch_info_pkg, "has_deps_build", false)
    has_artifacts = get(arch_info_pkg, "has_artifacts", false)

    if has_deps_build == extra_info.deps_build &&
        has_artifacts == extra_info.artifacts
        return
    end
    open(joinpath(pkgdir, "PKGBUILD"), "a") do io
        if has_deps_build != extra_info.deps_build
            println(io, "# deps_build: $(has_deps_build) -> $(extra_info.deps_build)")
            if extra_info.deps_build
                arch_info_pkg["has_deps_build"] = true
            else
                delete!(arch_info_pkg, "has_deps_build")
            end
        end
        if has_artifacts != extra_info.artifacts
            println(io, "# artifacts: $(has_artifacts) -> $(extra_info.artifacts)")
            if extra_info.artifacts
                arch_info_pkg["has_artifacts"] = true
            else
                delete!(arch_info_pkg, "has_artifacts")
            end
        end
    end
    return
end

function write_new_package(ctx::Context, arch_info, pkgdir,
                           full_pkg_info, extra_info::JLLPkgInfo)
    arch_info["Pkg"]["is_jll"] = true
    products = get!(Dict{String,Vector{String}},
                    get!(Dict{String,Any}, arch_info, "JLL"), "products")
    first_item = Ref(true)
    for key in ("library", "executable", "file")
        ps = get(extra_info.products, key, nothing)
        if ps === nothing
            continue
        end
        jlltoml_key = key
        if key == "executable"
            jlltoml_key = "binary"
        end

        p_names = [p[1] for p in ps]
        products[key] = p_names
        open(joinpath(pkgdir, "jll.toml"), "a") do io
            for p in ps
                if first_item[]
                    first_item[] = false
                else
                    println(io)
                end
                println(io, "[[$(jlltoml_key)]]")
                println(io, "name = \"$(p[1])\"")
                if p[1] != p[2]
                    println(io, "file = \"$(p[2])\"")
                end
            end
        end
    end
    arch_pkg_name = "julia-git-$(lowercase(full_pkg_info.name))-src"
    write("$(pkgdir)/PKGBUILD", """
pkgname=$(arch_pkg_name)
pkgver=$(full_pkg_info.ver)
_commit=$(full_pkg_info.commit)
pkgrel=1
pkgdesc="$(full_pkg_info.name).jl"
url="$(full_pkg_info.url)"
arch=('any')
license=('MIT')
# TODO: Add dependency on the libraries
makedepends=(git julia-pkg-scripts)
depends=(julia-git)
source=("git+$(full_pkg_info.url)#commit=\$_commit"
        jll.toml)
sha256sums=('SKIP')

build() {
  cd $(full_pkg_info.name).jl

  julia /usr/lib/julia/julia-gen-jll.jl $(full_pkg_info.name) ../jll.toml
}

package() {
  cd $(full_pkg_info.name).jl

  JULIA_INSTALL_SRCPKG=1 . /usr/lib/julia/julia-install-pkg.sh $(full_pkg_info.name) "\${pkgdir}" "\${pkgname}" julia-git
}
""")
    return
end

function write_new_package(ctx::Context, arch_info, pkgdir,
                           full_pkg_info, extra_info::NormalPkgInfo)
    arch_info_pkg = arch_info["Pkg"]
    if extra_info.deps_build
        arch_info_pkg["has_deps_build"] = true
    else
        delete!(arch_info_pkg, "has_deps_build")
    end
    if extra_info.artifacts
        arch_info_pkg["has_artifacts"] = true
    else
        delete!(arch_info_pkg, "has_artifacts")
    end
    arch_pkg_name = "julia-git-$(lowercase(full_pkg_info.name))-src"
    open("$(pkgdir)/PKGBUILD", "w") do fh
        write(fh, """
pkgname=$(arch_pkg_name)
pkgver=$(full_pkg_info.ver)
_commit=$(full_pkg_info.commit)
pkgrel=1
pkgdesc="$(full_pkg_info.name).jl"
url="$(full_pkg_info.url)"
arch=('any')
license=('MIT')
makedepends=(git julia-pkg-scripts)
depends=(julia-git)
source=("git+$(full_pkg_info.url)#commit=\$_commit")
sha256sums=('SKIP')

""")

        if extra_info.deps_build
            println(fh, "# TODO: handle deps/build.jl\n")
        end
        if extra_info.artifacts
            println(fh, "# TODO: handle artifacts\n")
        end

        write(fh, """
package() {
  cd $(full_pkg_info.name).jl

  JULIA_INSTALL_SRCPKG=1 . /usr/lib/julia/julia-install-pkg.sh $(full_pkg_info.name) "\${pkgdir}" "\${pkgname}" julia-git
}
""")
    end
    return
end

function write_repo(ctx::Context, pkg_infos, repodir)
    new_packages = Set{String}()
    for (uuid, full_pkg_info) in pkg_infos
        name = full_pkg_info.name
        arch_pkg_name = "julia-git-$(lowercase(name))-src"

        pkgdir = joinpath(repodir, "archlinuxcn", arch_pkg_name)
        pkgbuild_path = joinpath(pkgdir, "PKGBUILD")

        pkg_exist = isfile(pkgbuild_path)

        arch_info = get!(Dict{String,Any}, ctx.packages_info, uuid)
        arch_info_pkg = get!(Dict{String,Any}, arch_info, "Pkg")
        arch_info_pkg["name"] = name
        arch_info_pkg["uuid"] = string(uuid)
        arch_info_status = get!(Dict{String,Any}, arch_info, "Status")
        arch_info_status["version"] = string(full_pkg_info.ver)

        pkginfo_path = get!(()->joinpath(ctx.pkgsdir, name),
                            ctx.package_paths, uuid)
        mkpath(pkginfo_path)
        verfile = joinpath(pkginfo_path, "version")
        write(verfile, "version: $(full_pkg_info.ver)@$(full_pkg_info.commit)\n")
        if pkg_exist
            @info "Update PKGBUILD for $(name) [$(uuid)] @ $(full_pkg_info.ver)"
            write_additional_extra_info(ctx, arch_info, pkgdir, full_pkg_info.extra)
        else
            @info "Generate PKGBUILD for $(name) [$(uuid)] @ $(full_pkg_info.ver)"
            push!(new_packages, name)
            mkpath(pkgdir)
            cp(joinpath(@__DIR__, "lilac-common.py"), joinpath(pkgdir, "lilac.py"))
            write("$(pkgdir)/lilac.yaml", """
maintainers:
  - github: yuyichao

post_build: git_pkgbuild_commit

repo_depends:
  - julia-git
  - openspecfun-git
  - openlibm-git
  - llvm-julia: llvm-libs-julia
  - julia-pkg-scripts

update_on:
  - source: regex
    url: https://raw.githubusercontent.com/yuyichao/archcn-julia-pkgs/master/pkgs/$(name)/version
    regex: 'version: *([^ ]*@[^ ]*)'
  - source: manual
    manual: 1
""")
            write_new_package(ctx, arch_info, pkgdir, full_pkg_info,
                              full_pkg_info.extra)
        end
    end
    new_packages = sort!(collect(new_packages))
    edit_precompiled_pkgfile(joinpath(repodir, "archlinuxcn",
                                      "julia-git-precompiled-packages",
                                      "lilac.yaml"),
                             new_packages)
    edit_precompiled_pkgfile(joinpath(repodir, "archlinuxcn",
                                      "julia-git-precompiled-packages",
                                      "PKGBUILD"),
                             new_packages)
    edit_precompiled_pkgfile(joinpath(repodir, "archlinuxcn",
                                      "julia-git-precompiled-packages",
                                      "package.list"),
                             new_packages)
    edit_precompiled_pkgfile(joinpath(repodir, "archlinuxcn",
                                      "julia-git-packages-meta",
                                      "lilac.yaml"),
                             new_packages)
    edit_precompiled_pkgfile(joinpath(repodir, "archlinuxcn",
                                      "julia-git-packages-meta",
                                      "PKGBUILD"),
                             new_packages)
    edit_precompiled_pkgfile(joinpath(repodir, "alarmcn",
                                      "julia-git-precompiled-packages",
                                      "lilac.yaml"),
                             new_packages)
    edit_precompiled_pkgfile(joinpath(repodir, "alarmcn",
                                      "julia-git-precompiled-packages",
                                      "PKGBUILD"),
                             new_packages)
    edit_precompiled_pkgfile(joinpath(repodir, "alarmcn",
                                      "julia-git-precompiled-packages",
                                      "package.list"),
                             new_packages)
end

function edit_precompiled_pkgfile(path, new_packages)
    @info "Updating $(path)"
    mv(path, "$(path).bak")
    try
        open(path, "w") do io
            _edit_precompiled_pkgfile(io, eachline("$(path).bak"), new_packages)
        end
        rm("$(path).bak")
    catch
        mv("$(path).bak", path, force=true)
        rethrow()
    end
end

function _edit_precompiled_pkgfile(fout, linein, new_packages)
    for line in linein
        println(fout, line)
        if line == "###=== JLPKG_UPDATE_ON_LIST {{"
            @info "Found update_on list"
            items = ["  - alias: alpm-lilac\n    alpm: julia-git-$(lowercase(pkg))-src"
                     for pkg in new_packages]
            insert_lines_sorted(fout, linein, items, 2,
                                "###=== }} JLPKG_UPDATE_ON_LIST")
        elseif line == "###=== JLPKG_DEPEND_LIST {{"
            @info "Found depend list"
            items = ["  - julia-git-$(lowercase(pkg))-src"
                     for pkg in new_packages]
            insert_lines_sorted(fout, linein, items, 1,
                                "###=== }} JLPKG_DEPEND_LIST")
        elseif line == "###=== JLPKG_UPDATE_ON_BUILD_LIST {{"
            @info "Found update_on_build list"
            items = ["  - pkgbase: julia-git-$(lowercase(pkg))-src"
                     for pkg in new_packages]
            insert_lines_sorted(fout, linein, items, 1,
                                "###=== }} JLPKG_UPDATE_ON_BUILD_LIST")
        elseif line == "###=== JLPKG_JLNAME_LIST {{"
            @info "Found _jlpackages list"
            items = ["  $(pkg)" for pkg in new_packages]
            insert_lines_sorted(fout, linein, items, 1,
                                "###=== }} JLPKG_JLNAME_LIST")
        elseif line == "###=== JLPKG_PACKAGE_LIST {{"
            @info "Found packages.list"
            items = ["julia-git-$(lowercase(pkg))" for pkg in new_packages]
            insert_lines_sorted(fout, linein, items, 1,
                                "###=== }} JLPKG_PACKAGE_LIST")
        end
    end
end

function next_lines(line_it, nline, endline)
    line1, _ = iterate(line_it)
    if line1 == endline
        return
    end
    if nline == 1
        return line1
    end
    buf = IOBuffer()
    write(buf, line1)
    for i in 2:nline
        line, _ = iterate(line_it)
        write(buf, "\n")
        write(buf, line)
    end
    return String(take!(buf))
end

function insert_lines_sorted(fout, linein, new_items, nline, endline)
    item_idx = 1
    nitems = length(new_items)
    while true
        line = next_lines(linein, nline, endline)
        if line === nothing
            while item_idx <= nitems
                println(fout, new_items[item_idx])
                item_idx += 1
            end
            println(fout, endline)
            return
        end
        while item_idx <= nitems && new_items[item_idx] < line
            println(fout, new_items[item_idx])
            item_idx += 1
        end
        println(fout, line)
    end
end

get_pkg_uuids(ctx::Context, pkg) = get_pkg_uuids(ctx.registry, pkg)

function _add_pkg_uuids(ctx::Context, uuids, new_packages)
    for name in new_packages
        pkg_uuids = get_pkg_uuids(ctx, name)
        if length(pkg_uuids) == 0
            @error "Package $(name) not found in registry"
            exit(1)
        elseif length(pkg_uuids) != 1
            buf = IOBuffer()
            println(buf, "Package $(name) not unique in registry. Possible matches:")
            for uuid in pkg_uuids
                println(buf, "  $(uuid)")
            end
            println(buf, "Please specify the package using the UUID instead.")
            @error String(take!(buf))
            exit(1)
        end
        push!(uuids, pkg_uuids[1])
    end
end

function update_packages(ctx::Context, repodir, new_packages=nothing)
    uuids = Base.UUID[]
    if new_packages !== nothing
        _add_pkg_uuids(ctx, uuids, new_packages)
    end
    versions = resolve_all_dependencies(ctx, uuids)
    full_pkg_infos = collect_all_pkg_info(ctx, versions)
    write_repo(ctx, full_pkg_infos, repodir)
    write_back_info(ctx)
    return
end

function find_dependents(ctx::Context, pkg)
    pkg_uuids = get_pkg_uuids(ctx, pkg)
    if length(pkg_uuids) == 0
        error("Package $(pkg) not found in registry")
    elseif length(pkg_uuids) != 1
        buf = IOBuffer()
        println(buf, "Package $(pkg) not unique in registry. Possible matches:")
        for uuid in pkg_uuids
            println(buf, "  $(uuid)")
        end
        println(buf, "Please specify the package using the UUID instead.")
        error(String(take!(buf)))
    end
    pkg_uuid = pkg_uuids[1]
    dependents = Set{Base.UUID}()
    for (uuid, arch_info) in ctx.packages_info
        cur_ver = VersionNumber(arch_info["Status"]["version"])
        pkgentry = ctx.registry[uuid]
        pkginfo = Pkg.Registry.registry_info(pkgentry)
        for (vrange, vdeps) in pkginfo.deps
            cur_ver in vrange || continue
            if pkg_uuid in values(vdeps)
                push!(dependents, uuid)
                break
            end
        end
    end
    return dependents
end

show_pkg_info(ctx::Context, uuid) = show_pkg_info(stdout, ctx, uuid)

function show_pkg_info(io::IO, ctx::Context, uuid)
    pkgentry = get(ctx.registry, uuid, nothing)
    if pkgentry === nothing
        println(io, "Unknown package [$uuid]")
        return
    end
    println(io, "$(pkgentry.name) [$uuid]")
    return
end
