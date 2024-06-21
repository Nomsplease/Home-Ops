#!/bin/bash

patchesPath=patches

patches=()

# Iterate over each file in the directory
for patch in "$patchesPath"/*; do
  # Check if the file name starts with "controlplane-"
  if [[ "$(basename "$patch")" == controlplane-* ]]; then
    # Append --config-patch-control-plane to the file path and add it to the array
    patches+=("--config-patch-control-plane" "@$patch")
  else
    # Append --config-patch to the file path and add it to the array
    patches+=("--config-patch" "@$patch")
  fi
done

# Output the array
echo "${patches[@]}" --output render/