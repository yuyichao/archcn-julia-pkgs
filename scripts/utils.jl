#!/usr/bin/julia

using Pkg
using TOML

const project_toml_names = ("Project.toml", "JuliaProject.toml")

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

struct Context
    pkgsdir::String
    workdir::String
    registry::Pkg.Registry.RegistryInstance
    packages_info::Dict{Base.UUID,Any}
    global_info::Dict{String,Any}
    package_paths::Dict{Base.UUID,String}
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
                   deepcopy(packages_info), deepcopy(global_info))
    end
end

function write_back_info(ctx::Context)
    if ctx.global_info != ctx._global_info
        open(joinpath(ctx.pkgsdir, "global.toml"), "w") do io
            TOML.print(io, ctx.global_info)
        end
    end
    for (k, v) in ctx.packages_info
        if v == ctx._packages_info[k]
            continue
        end
        open(joinpath(ctx.package_paths[k], "info.toml"), "w") do io
            TOML.print(io, v)
        end
    end
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
    arch_info = ctx.packages_info[uuid]
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
