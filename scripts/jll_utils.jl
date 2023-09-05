#!/usr/bin/julia

function get_jll_content(url, name, hash, workdir)
    LibGit2.with(get_repo(url, name, workdir)) do repo
        reset_tree(repo, hash)
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

struct JLLChanges
    add::Dict{String,Vector{String}}
    remove::Dict{String,Vector{String}}
    JLLChanges() = new(Dict{String,Vector{String}}(), Dict{String,Vector{String}}())
end

Base.isempty(changes::JLLChanges) = isempty(changes.add) && isempty(changes.remove)

function todict(ctx::Context, changes::JLLChanges)
    res = Dict{String,Any}("type"=>"jll_changes")
    if !isempty(changes.add)
        res["add"] = changes.add
    end
    if !isempty(changes.remove)
        res["remove"] = changes.remove
    end
    return res
end

function check_jll_content(ctx::Context, pkginfo, arch_info, new_ver,
                           out::JLLChanges)
    name = arch_info["Pkg"]["name"]
    url = pkginfo.repo
    hash = pkginfo.version_info[new_ver].git_tree_sha1.bytes
    workdir = joinpath(ctx.workdir, "gitcache")
    products = get_jll_content(url, name, hash, workdir)
    old_products = get!(Dict{String,Vector{String}},
                        get!(Dict{String,Any}, arch_info, "JLL"), "products")
    for key in ("library", "executable", "file")
        has_type = haskey(products, key)
        had_type = haskey(old_products, key)
        if has_type && had_type
            p = products[key]
            old_p = old_products[key]
            add = setdiff(p, old_p)
            if !isempty(add)
                out.add[key] = add
            end
            remove = setdiff(old_p, p)
            if !isempty(remove)
                out.remove[key] = remove
            end
        elseif has_type
            p = products[key]
            if !isempty(p)
                out.add[key] = p
            end
        elseif had_type
            old_p = old_products[key]
            if !isempty(old_p)
                out.remove[key] = old_p
            end
        end
    end
    return isempty(out)
end
