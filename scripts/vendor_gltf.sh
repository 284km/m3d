#!/bin/sh
# scripts/vendor_gltf.sh — take models off the Khronos sample set, once, and commit them.
#
# THE REPOSITORY IS 1.7 GB and this needs a handful of small models, so it fetches the
# named files by raw URL rather than cloning. Each model's directory gets a PROVENANCE
# file recording the URL, the date and the SHA-256, because a snapshot with no date is a
# file from an unknown year and one with no digest cannot be told from an edited one.
#
# curl fetches them and not this project's own code: a vendoring tool that uses the
# subject to fetch the input its own gate will read is a shape worth not having -- if both
# were wrong in the same way, the snapshot would be wrong and nothing would say so.
#
# BOTH VARIANTS OF EACH MODEL, deliberately. The .gltf and the .glb hold the same scene in
# two containers, so they are each other's oracle: `scripts/container_check.sh` requires
# the loader to produce identical numbers from both, and that check needs nothing external.
#
# Usage:  sh scripts/vendor_gltf.sh [model ...]
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models"
DATE="$(date -u +%Y-%m-%d)"

models="${*:-Triangle TriangleWithoutIndices Box BoxInterleaved BoxTextured BoxVertexColors SimpleMeshes Cube}"

for m in $models; do
  d="$ROOT/test/data/gltf/$m"
  mkdir -p "$d"
  : > "$d/PROVENANCE"
  echo "# $m -- from KhronosGroup/glTF-Sample-Assets, fetched $DATE" >> "$d/PROVENANCE"
  # Which files a model is made of is in its own directory listing, which the raw host does
  # not serve, so the GitHub API is asked for it. Only the two variants this project reads.
  for variant in glTF glTF-Binary; do
    api="https://api.github.com/repos/KhronosGroup/glTF-Sample-Assets/contents/Models/$m/$variant"
    names=$(curl -sSL --fail "$api" 2>/dev/null \
            | python3 -c 'import json,sys
try:
    for e in json.load(sys.stdin):
        if e["type"] == "file": print(e["name"])
except Exception: pass') || names=""
    [ -n "$names" ] || { echo "  $m/$variant: absent"; continue; }
    mkdir -p "$d/$variant"
    for n in $names; do
      # A name can contain a space or a non-ASCII character (Box With Spaces,
      # Unicode<3>Test); --data-urlencode is not right for a path, so the URL is
      # built by python and curl is handed the finished thing.
      url=$(python3 -c "import urllib.parse,sys; print(sys.argv[1] + '/' + '/'.join(urllib.parse.quote(p) for p in sys.argv[2:]))" "$BASE" "$m" "$variant" "$n")
      curl -sSL --fail -o "$d/$variant/$n" "$url"
      sum=$(shasum -a 256 "$d/$variant/$n" | cut -d' ' -f1)
      echo "$variant/$n  $sum  $url" >> "$d/PROVENANCE"
      echo "  $m/$variant/$n"
    done
  done
done
echo "vendor_gltf: done"
