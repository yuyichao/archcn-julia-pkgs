#!/usr/bin/julia

include("utils.jl")

const context = Context()

const repo_dir = ARGS[1]
const new_packages = ARGS[2:end]

update_packages(context, repo_dir, new_packages)
