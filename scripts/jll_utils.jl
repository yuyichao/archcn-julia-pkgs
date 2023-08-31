#!/usr/bin/julia

function get_jll_content(url, name, hash, workdir)
    LibGit2.with(get_repo(url, name, workdir)) do repo
        reset_commit(repo, hash)
        repopath = LibGit2.workdir(repo)
        wrappersdir = joinpath(repopath, "src/wrappers")
        for file in readdir(wrappersdir)
            m = match(r"x86_64-(.*-|)linux-(.*-|)gnu.*\.jl", file)
            if m === nothing
                continue
            end
            products = Dict{String,Vector{String}}()
            for line in eachline(joinpath(wrappersdir, file))
                m = match(r"@declare_(library|executable|file)_product\(([^, )]*)",
                          line)
                if m === nothing
                    continue
                end
                push!(get!(Vector{String}, products, m[1]), m[2])
            end
            for (k, v) in products
                sort!(v)
            end
            return products
        end
    end
end
