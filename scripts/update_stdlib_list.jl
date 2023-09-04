#!/usr/bin/julia

include("utils.jl")

function list_packages(stdlib_dir)
    stdlibs = Dict{String,String}()
    for dir in readdir(stdlib_dir, join=true)
        isdir(dir) || continue
        for proj_name in project_toml_names
            proj_file = joinpath(dir, proj_name)
            isfile(proj_file) || continue
            d = TOML.parsefile(proj_file)
            name = get(d, "name", nothing)
            uuid = get(d, "uuid", nothing)
            if name === nothing || uuid === nothing
                continue
            end
            stdlibs[uuid] = name
        end
    end
    return stdlibs
end

const context = Context()

function update_stdlib_list(ctx, stdlibs)
    old_stdlibs = get(ctx.global_info, "StdLibs", nothing)
    if old_stdlibs !== nothing && old_stdlibs == stdlibs
        @info "StdLibs list already up to date."
        return
    end
    ctx.global_info["StdLibs"] = stdlibs
    open(joinpath(ctx.pkgsdir, "global.toml"), "w") do io
        TOML.print(io, ctx.global_info)
    end
    @info "StdLibs list updated."
end

update_stdlib_list(context, list_packages(ARGS[1]))
