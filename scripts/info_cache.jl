#!/usr/bin/julia

# Persistent cache for information that is immutable.
#
# * Per-repo map from tree hash to commit hash.
#   Any commit found for a tree hash stays valid,
#   so a found commit never needs to be looked up again.
#   Failed lookups are not cached since the commit may show up later.
# * Information computed from the content of a tree, keyed by the tree hash.
#   Only facts that depend purely on the tree content are stored here.
#   Anything that depends on the registry (e.g. the tree hash for a version)
#   or on the package info in this repo is still computed every time.
#
# The data is stored under a versioned subdirectory so that changes to the
# information extraction code can invalidate the old cache.

import SHA
using TOML

const INFO_CACHE_VERSION = "v1"

struct InfoCache
    dir::String
    commits::Dict{String,Dict{String,Any}}
    trees::Dict{String,Dict{String,Any}}
    # Protects all the in-memory states and the cache files.
    lock::ReentrantLock
    function InfoCache(dir)
        dir = joinpath(abspath(dir), INFO_CACHE_VERSION)
        mkpath(dir)
        return new(dir, Dict{String,Dict{String,Any}}(),
                   Dict{String,Dict{String,Any}}(), ReentrantLock())
    end
end

function _load_cache_file(path)
    isfile(path) || return Dict{String,Any}()
    try
        return TOML.parsefile(path)
    catch
        @warn "Ignoring corrupted cache file $(path)" exception=current_exceptions()
        return Dict{String,Any}()
    end
end

function _save_cache_file(path, data)
    mkpath(dirname(path))
    tmppath = "$(path).tmp.$(getpid())"
    open(tmppath, "w") do io
        TOML.print(io, data, sorted=true)
    end
    mv(tmppath, path, force=true)
    return
end

_commits_cache_path(cache::InfoCache, url) =
    joinpath(cache.dir, "commits", "$(bytes2hex(SHA.sha1(url))).toml")

function _repo_commits(cache::InfoCache, url)
    return get!(cache.commits, url) do
        data = _load_cache_file(_commits_cache_path(cache, url))
        # Sanity check in case of a hash collision
        if get(data, "url", url) != url
            return Dict{String,Any}()
        end
        return get(Dict{String,Any}, data, "commits")
    end
end

"""
    lookup_cached_commit(cache, url, tree)

Return the commit hash (as a string) in the repo `url` that was previously
found for tree hash `tree` or `nothing` if not found.
"""
function lookup_cached_commit(cache::InfoCache, url, tree::AbstractString)
    commit = @lock cache.lock get(_repo_commits(cache, url), tree, nothing)
    return commit isa String ? commit : nothing
end

function cache_commit!(cache::InfoCache, url, tree::AbstractString,
                       commit::AbstractString)
    @lock cache.lock begin
        commits = _repo_commits(cache, url)
        get(commits, tree, nothing) == commit && return
        commits[tree] = String(commit)
        _save_cache_file(_commits_cache_path(cache, url),
                         Dict{String,Any}("url"=>url, "commits"=>commits))
    end
    return
end

_tree_cache_path(cache::InfoCache, tree) =
    joinpath(cache.dir, "trees", tree[1:2], "$(tree).toml")

_tree_info(cache::InfoCache, tree) =
    get!(()->_load_cache_file(_tree_cache_path(cache, tree)), cache.trees, tree)

"""
    get_tree_info(f, cache, tree, key)

Return the information named `key` for the content of tree `tree`.
If the information is not in the cache, compute it with `f()`
(the result must be representable in TOML) and save it in the cache.
The returned value must not be mutated.
"""
function get_tree_info(f, cache::InfoCache, tree::AbstractString, key)
    @lock cache.lock begin
        info = _tree_info(cache, tree)
        if haskey(info, key)
            return info[key]
        end
    end
    # Compute without holding the lock so that other threads can make progress.
    val = f()
    @lock cache.lock begin
        info = _tree_info(cache, tree)
        info[key] = val
        _save_cache_file(_tree_cache_path(cache, tree), info)
    end
    return val
end
