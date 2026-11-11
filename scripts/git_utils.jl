#!/usr/bin/julia

import LibGit2

# (repopath, url) pairs that have already been fetched in this run.
# The same repopath may be shared by multiple URLs (packages with the same name)
# so the URL is part of the key.
const _fetched_repos = Set{Tuple{String,String}}()
const _fetched_repos_lock = ReentrantLock()

_is_fetched(repopath, url) =
    @lock _fetched_repos_lock (repopath, url) in _fetched_repos

# Lock for each repo directory.
# Everything that uses a repo directory (fetching, checking out
# and reading the checked out files) must hold the lock for the directory.
const _repo_locks = Dict{String,ReentrantLock}()
const _repo_locks_lock = ReentrantLock()

function with_repo_lock(f, repopath)
    l = @lock _repo_locks_lock get!(ReentrantLock, _repo_locks, repopath)
    return @lock l f()
end

"""
    with_repo(f, url, name, workdir; need=nothing)

Call `f(repo)` with the repo for `url` (see `get_repo`)
while holding the lock for the repo directory.
"""
function with_repo(f, url, name, workdir; need=nothing)
    return with_repo_lock(joinpath(workdir, name)) do
        return LibGit2.with(f, get_repo(url, name, workdir, need=need))
    end
end

function _fetch_repo(repo, repopath, url)
    LibGit2.with(LibGit2.GitRemoteAnon(repo, url)) do remote
        fetch_opts = LibGit2.FetchOptions(download_tags=true)
        LibGit2.fetch(remote, String["+refs/heads/*:refs/remotes/origin/*"],
                      msg="from $(url)", options=fetch_opts)
    end
    @lock _fetched_repos_lock push!(_fetched_repos, (repopath, url))
    return
end

function _has_object(repo, hash)
    obj = try
        LibGit2.GitObject(repo, LibGit2.GitHash(hash))
    catch e
        e isa LibGit2.GitError || rethrow()
        return false
    end
    close(obj)
    return true
end

function _open_repo(repopath, url, need)
    repo = try
        LibGit2.GitRepo(repopath)
    catch
        return
    end
    try
        # Skip fetching if we already have what we need
        # or if the repo was already fetched from the same URL in this run.
        if (need !== nothing && _has_object(repo, need)) ||
            _is_fetched(repopath, url)
            return repo
        end
        _fetch_repo(repo, repopath, url)
        return repo
    catch
        close(repo)
        return
    end
end

"""
    get_repo(url, name, workdir; need=nothing)

Open (or clone) the repo for `url` at `workdir/name`.
The repo is fetched from `url` unless it was already fetched from `url`
in this run or the object `need` (if not `nothing`) already exists locally.

The caller must hold the lock for the repo directory (see `with_repo_lock`)
if this may be called from multiple threads.
"""
function get_repo(url, name, workdir; need=nothing)
    repopath = joinpath(workdir, name)
    if isdir(repopath)
        repo = _open_repo(repopath, url, need)
        if repo !== nothing
            return repo
        end
        rm(repopath, recursive=true, force=true)
    end
    # Anything previously fetched into this path is gone now.
    @lock _fetched_repos_lock filter!(k->k[1] != repopath, _fetched_repos)
    fetch_opts = LibGit2.FetchOptions(download_tags=true)
    repo = LibGit2.clone(url, repopath, LibGit2.CloneOptions(fetch_opts=fetch_opts))
    @lock _fetched_repos_lock push!(_fetched_repos, (repopath, url))
    return repo
end

function reset_commit(repo, hash)
    LibGit2.reset!(repo, LibGit2.GitHash(hash), LibGit2.Consts.RESET_HARD)
end

function reset_tree(repo, hash)
    opts = LibGit2.CheckoutOptions(
        checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE
    )
    LibGit2.with(LibGit2.GitObject(repo, LibGit2.GitHash(hash))) do tree
        LibGit2.checkout_tree(repo, tree, options=opts)
    end
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
    return LibGit2.with(LibGit2.GitRemoteAnon(repo, url)) do remote
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

function _find_commit_for_tree(tree, commit, visited, toplevel_only)
    hash = LibGit2.GitHash(commit)
    if hash in visited
        return
    end
    push!(visited, hash)
    # First iterate parent to find the first commit with the tree hash
    for i in 1:parentcount(commit)
        res = LibGit2.with(parent(commit, i)) do p
            return _find_commit_for_tree(tree, p, visited, toplevel_only)
        end
        if res !== nothing
            return res
        end
    end
    return LibGit2.with(LibGit2.GitTree(commit)) do commit_toplevel
        if LibGit2.GitHash(commit_toplevel) == tree
            return hash
        end
        if toplevel_only
            return
        end
        if _tree_contains(commit_toplevel, tree)
            return hash
        end
        return
    end
end

mutable struct _TreeSearch
    const target::LibGit2.GitHash
    found::Bool
end

function _tree_search_cb(root::Cstring, entry::Ptr{Cvoid}, s::_TreeSearch)::Cint
    oid = unsafe_load(ccall((:git_tree_entry_id, :libgit2), Ptr{LibGit2.GitHash},
                            (Ptr{Cvoid},), entry))
    if oid == s.target
        s.found = true
        return -1 # Stop the walk
    end
    return 0
end

# Whether `target` is in `tree` recursively.
# Not using `LibGit2.treewalk` since it uses libgit2's last error to tell
# whether the walk was stopped by the callback. The last error is per OS thread
# and `LibGit2.Error.last_error` may yield (it takes a lock) and resume
# the task on another thread so a successful search may be reported as an error.
function _tree_contains(tree::LibGit2.GitTree, target::LibGit2.GitHash)
    s = _TreeSearch(target, false)
    cb = @cfunction(_tree_search_cb, Cint, (Cstring, Ptr{Cvoid}, Ref{_TreeSearch}))
    err = ccall((:git_tree_walk, :libgit2), Cint,
                (Ptr{Cvoid}, Cint, Ptr{Cvoid}, Any),
                tree.ptr, 0 #= GIT_TREEWALK_PRE =#, cb, s)
    s.found && return true
    if err < 0
        throw(LibGit2.GitError(err))
    end
    return false
end

function find_commit_for_tree(repo, tree, head, last_commit, url)
    visited_full = Set{LibGit2.GitHash}()
    visited_toponly = Set{LibGit2.GitHash}()
    if head !== nothing
        res = LibGit2.with(LibGit2.GitCommit(repo, head)) do head_commit
            for toplevel_only in (true, false)
                visited = toplevel_only ? visited_toponly : visited_full
                if last_commit !== nothing
                    push!(visited, last_commit)
                end
                res = _find_commit_for_tree(tree, head_commit, visited,
                                            toplevel_only)
                if res !== nothing
                    return res
                end
                if last_commit !== nothing
                    empty!(visited)
                    res = _find_commit_for_tree(tree, head_commit, visited,
                                                toplevel_only)
                    if res !== nothing
                        return res
                    end
                end
            end
            return
        end
        if res !== nothing
            return res
        end
    end
    remote_heads = LibGit2.with(LibGit2.GitRemoteAnon(repo, url)) do remote
        connect(remote, :fetch)
        return ls(remote)
    end
    for toplevel_only in (true, false)
        visited = toplevel_only ? visited_toponly : visited_full
        for head in remote_heads
            remote_head_commit = try
                LibGit2.GitCommit(repo, head.oid)
            catch
                @warn "Cannot find commit for remote head $(head)"
                continue
            end
            res = LibGit2.with(remote_head_commit) do c
                return _find_commit_for_tree(tree, c, visited, toplevel_only)
            end
            if res !== nothing
                return res
            end
        end
    end
    return nothing
end

function find_package_commit(url, name, workdir, branch, tree, last_commit)
    if last_commit !== nothing
        last_commit = LibGit2.GitHash(last_commit)
    end
    tree = LibGit2.GitHash(tree)
    return with_repo(url, name, workdir) do repo
        remote_head = find_remote_head_commit(repo, url, branch)
        if remote_head === nothing && branch !== nothing
            @warn "Cannot find remote branch $(branch) at $(url), try remote default branch."
            remote_head = find_remote_head_commit(repo, url)
        end
        if remote_head === nothing
            @warn "Cannot find remote default branch at $(url)."
        elseif !_has_object(repo, remote_head)
            # The fetch may have been skipped or done earlier in this run
            # before the remote was updated.
            _fetch_repo(repo, joinpath(workdir, name), url)
        end
        return find_commit_for_tree(repo, tree, remote_head, last_commit, url)
    end
end
