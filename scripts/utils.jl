#!/usr/bin/julia

using Pkg
using TOML

include("git_utils.jl")
include("jll_utils.jl")

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
    unknown_packages::Set{Base.UUID}
    messages::Vector{String}
    function Context()
        pkgsdir = joinpath(@__DIR__, "../pkgs")
        workdir = get(ENV, "JL_ARCHCN_WORKDIR",
                      joinpath(Base.DEPOT_PATH[1], "archcn"))
        mkpath(workdir)
        registry = find_general_registry()
        packages_info = load_packages(pkgsdir)
        global_info = TOML.parsefile(joinpath(pkgsdir, "global.toml"))
        return new(pkgsdir, workdir, registry, packages_info,
                   global_info, Set{Base.UUID}(), String[])
    end
end