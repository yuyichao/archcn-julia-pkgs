#!/usr/bin/julia

using LibGit2

function _open_repo(repopath, url)
    try
        repo = LibGit2.GitRepo(repopath)
        LibGit2.fetch(repo, remoteurl=url)
        return repo
    catch
        return
    end
end

function get_repo(url, name, workdir)
    repopath = joinpath(workdir, name)
    if isdir(repopath)
        repo = _open_repo(repopath, url)
        if repo !== nothing
            return repo
        end
        rm(repopath, recursive=true, force=true)
    end
    return LibGit2.clone(url, repopath)
end

function reset_commit(repo, hash)
    LibGit2.reset!(repo, LibGit2.GitHash(hash), LibGit2.Consts.RESET_HARD)
end

function reset_tree(repo, hash)
    tree = LibGit2.GitObject(repo, LibGit2.GitHash(hash))
    opts = LibGit2.CheckoutOptions(
        checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE
    )
    LibGit2.checkout_tree(repo, tree, options=opts)
end

function connect(r::LibGit2.GitRemote, direction::Symbol)
    if direction === :fetch
        dir = Cint(0) # LibGit2.Consts.DIRECTION_FETCH
    elseif direction == :push
        dir = Cint(1) # LibGit2.Consts.DIRECTION_PUSH
    else
        throw(ArgumentError("direction can be :fetch or :push, got :$direction"))
    end
    LibGit2.@check ccall((:git_remote_connect, :libgit2),
                         Cint, (Ptr{Cvoid}, Cint, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                         r.ptr, dir, C_NULL, C_NULL, C_NULL)
    return r
end

function default_branch(r::LibGit2.GitRemote)
    buf_ref = Ref(LibGit2.Buffer())
    LibGit2.@check ccall((:git_remote_default_branch, :libgit2), Cint,
                         (Ptr{LibGit2.Buffer}, Ptr{Cvoid}), buf_ref, r.ptr)
    buf = buf_ref[]
    str = unsafe_string(buf.ptr, buf.size)
    LibGit2.free(buf_ref)
    return str
end

struct _GitRemoteHead
    available_local::Cint
    oid::LibGit2.GitHash
    loid::LibGit2.GitHash
    name::Cstring
    symref_target::Cstring
end

struct GitRemoteHead
    available_local::Bool
    oid::LibGit2.GitHash
    loid::LibGit2.GitHash
    name::String
    symref_target::Union{Nothing,String}
    function GitRemoteHead(head::_GitRemoteHead)
        name = unsafe_string(head.name)
        symref_target = (head.symref_target != C_NULL ?
            unsafe_string(head.symref_target) : nothing)
        return new(head.available_local != 0,
                   head.oid, head.loid, name, symref_target)
    end
end

function ls(r::LibGit2.GitRemote)
    nheads = Ref{Csize_t}()
    head_refs = Ref{Ptr{Ptr{_GitRemoteHead}}}()
    LibGit2.@check ccall((:git_remote_ls, :libgit2), Cint,
                         (Ptr{Ptr{Ptr{_GitRemoteHead}}}, Ptr{Csize_t}, Ptr{Cvoid}),
                         head_refs, nheads, r.ptr)
    head_ptr = head_refs[]
    return [GitRemoteHead(unsafe_load(unsafe_load(head_ptr, i)))
            for i in 1:nheads[]]
end

parentcount(c::LibGit2.GitCommit) =
    Int(ccall((:git_commit_parentcount, :libgit2), Cuint, (Ptr{Cvoid},), c))
function parent(c::LibGit2.GitCommit, n)
    ptr_ref = Ref{Ptr{Cvoid}}()
    LibGit2.@check ccall((:git_commit_parent, :libgit2), Cint,
                         (Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, Cuint), ptr_ref, c, n - 1)
    return LibGit2.GitCommit(c.owner, ptr_ref[])
end
function parent_id(c::LibGit2.GitCommit, n)
    oid_ptr = ccall((:git_commit_parent_id, :libgit2), Ptr{LibGit2.GitHash},
                    (Ptr{Cvoid}, Cuint), c, n - 1)
    if oid_ptr == C_NULL
        throw(LibGit2.GitError(LibGit2.Error.Invalid,
                               LibGit2.Error.ENOTFOUND,
                               "parent $(n - 1) does not exist"))
    end
    return unsafe_load(oid_ptr)
end

function find_remote_head_commit(repo, url, branch=nothing)
    return with(LibGit2.GitRemoteAnon(repo, url)) do remote
        connect(remote, :fetch)
        remote_ref = (branch === nothing ? default_branch(remote) :
            "refs/heads/$(branch)")
        remote_heads = ls(remote)
        for head in remote_heads
            if head.name == remote_ref
                return head.oid
            end
        end
        return
    end
end
