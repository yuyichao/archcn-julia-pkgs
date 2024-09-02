#!/usr/bin/julia

include("utils.jl")

const context = Context()

const repo_dir = ARGS[1]
const new_packages = ARGS[2:end]

const require_new_env = lowercase(get(ENV, "JL_ARCHCN_REQUIRE_NEW", "1"))

update_packages(context, repo_dir, new_packages,
                require_new_pkg=require_new_env in ("1", "yes", "true"))
