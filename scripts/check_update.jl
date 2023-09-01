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

const pkgsdir = joinpath(@__DIR__, "../pkgs")

const registry = find_general_registry()

const packages_info = load_packages(pkgsdir)
