#!/usr/bin/julia

include("utils.jl")

const context = Context()

const messages, changed = scan(context)

using GitHubActions

set_output("has_change", changed ? "1" : "0")
if !isempty(messages)
    set_output("has_messages", "1")
    set_output("messages", join(messages, "\n\n"))
else
    set_output("has_messages", "0")
end
