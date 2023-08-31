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
