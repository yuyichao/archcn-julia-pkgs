#!/usr/bin/julia

function _get_name_from_expr(@nospecialize expr)
    if isa(expr, QuoteNode)
        return expr.value
    elseif !isa(expr, Expr)
        return expr
    end
    if Meta.isexpr(expr, :., 2)
        return _get_name_from_expr(expr.args[2])
    end
    return expr
end

function _collect_jll_products(products, expr::Expr)
    if Meta.isexpr(expr, :macrocall) && length(expr.args) >= 2
        macro_name = _get_name_from_expr(expr.args[1])
        if macro_name == Symbol("@declare_executable_product")
            # product_name
            name = string(expr.args[end]::Symbol)
            get!(get!(Dict{String,String}, products, "executable"), name, name)
            return products
        elseif macro_name == Symbol("@init_executable_product")
            # product_name, product_path
            name = string(expr.args[end - 1]::Symbol)
            path = expr.args[end]
            get!(Dict{String,String}, products, "executable")[name] = basename(path)
            return products
        elseif macro_name == Symbol("@declare_file_product")
            # product_name
            name = string(expr.args[end]::Symbol)
            get!(get!(Dict{String,String}, products, "file"), name, name)
            return products
        elseif macro_name == Symbol("@init_file_product")
            # product_name, product_path
            name = string(expr.args[end - 1]::Symbol)
            path = expr.args[end]
            get!(Dict{String,String}, products, "file")[name] = basename(path)
            return products
        elseif macro_name == Symbol("@declare_library_product")
            # product_name, product_soname
            name = string(expr.args[end - 1]::Symbol)
            soname = expr.args[end]
            get!(get!(Dict{String,String}, products, "library"), name,
                 replace(soname, r"\.so.*"=>""))
            return products
        elseif macro_name == Symbol("@init_library_product")
            # product_name, product_path, dlopen_flags
            name = string(expr.args[end - 2]::Symbol)
            path = expr.args[end - 1]
            get!(Dict{String,String}, products, "library")[name] = basename(path)
            return products
        end
    end
    for arg in expr.args
        if isa(arg, Expr)
            _collect_jll_products(products, arg)
        end
    end
    return products
end

function collect_jll_products(repopath)
    wrappersdir = joinpath(repopath, "src/wrappers")
    products = Dict{String,Dict{String,String}}()
    for file in readdir(wrappersdir)
        m = match(r"x86_64-(.*-|)linux-(.*-|)gnu.*\.jl", file)
        if m === nothing
            continue
        end
        exprs = Meta.parseall(read(joinpath(wrappersdir, file), String))
        return _collect_jll_products(products, exprs)
    end
    return products
end

function collect_jll_product_names(repopath)
    return Dict(k=>sort!(collect(keys(v)))
                for (k, v) in collect_jll_products(repopath))
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

function check_jll_content(ctx::Context, arch_info, new_ver, out::JLLChanges)
    repopath = checkout_pkg_ver(ctx, Base.UUID(arch_info["Pkg"]["uuid"]), new_ver)
    products = collect_jll_product_names(repopath)
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
