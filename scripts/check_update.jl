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
    res = Dict{String,Any}()
    for dir in readdir(pkgsdir, join=true)
        try
            d = TOML.parsefile(joinpath(dir, "info.toml"))
            res[d["Pkg"]["uuid"]] = d
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
    packages_info::Dict{String,Any}
    function Context()
        pkgsdir = joinpath(@__DIR__, "../pkgs")
        workdir = get(ENV, "JL_ARCHCN_WORKDIR",
                      joinpath(Base.DEPOT_PATH[1], "archcn"))
        registry = find_general_registry()
        packages_info = load_packages(pkgsdir)
        return new(pkgsdir, workdir, registry, packages_info)
    end
end

const context = Context()
