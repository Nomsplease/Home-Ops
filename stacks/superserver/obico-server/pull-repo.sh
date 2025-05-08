#!/bin/bash

repo_url="https://github.com/TheSpaghettiDetective/obico-server.git"
local_path="obico-server"
branch_name="release"

# Check if the folder exists
if [ ! -d "$local_path" ]; then
    # The folder does not exist, clone the repository
    git clone "$repo_url" "$local_path"
else
    # The folder exists, update the existing Git folder
    pushd "$local_path" > /dev/null
    git pull origin "$branch_name"
    popd > /dev/null
fi