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
    for dir in readdir(pkgsdir, join=true)
        isdir(dir) || continue
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
    global_info::Dict{String,Any}
    function Context()
        pkgsdir = joinpath(@__DIR__, "../pkgs")
        workdir = get(ENV, "JL_ARCHCN_WORKDIR",
                      joinpath(Base.DEPOT_PATH[1], "archcn"))
        mkpath(workdir)
        registry = find_general_registry()
        packages_info = load_packages(pkgsdir)
        global_info = TOML.parsefile(joinpath(pkgsdir, "global.toml"))
        return new(pkgsdir, workdir, registry, packages_info, global_info)
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

include("git_utils.jl")
include("jll_utils.jl")
