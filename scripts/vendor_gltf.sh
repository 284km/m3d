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
# two containers, so they are each other's oracle: the first of `scripts/gltf_check.sh`'s
# four readers requires the loader to produce identical ACCESSOR DATA from both, and that
# check needs nothing external. (This comment used to name a `container_check.sh` that has
# never existed -- a comment claiming a file is not a file.)
#
# WHICH MODELS. The default list is the 49 of Khronos's 66 `core` models whose glTF
# variant is at most 2 MB; the cap, the 17 it leaves out, and what that costs in feature
# coverage are written down in test/data/gltf/CORPUS.md. Pass names to fetch just those.
#
# Usage:  sh scripts/vendor_gltf.sh [model ...]
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models"
DATE="$(date -u +%Y-%m-%d)"
T="${TMPDIR:-/tmp}/m3d_vendor.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

# The 49, in the alphabetical order the index gives them. Two names are here to be
# awkward on purpose -- one has spaces and one has non-ASCII characters -- because a
# vendoring script that cannot fetch those has a bug that only shows up on the model
# nobody chose to test with.
CORE_UNDER_2MB="AnimatedCube AnimatedMorphCube AnimatedTriangle Box BoxAnimated
BoxInterleaved BoxTextured BoxTexturedNonPowerOfTwo BoxVertexColors Cameras CesiumMan
CesiumMilkTruck CompareMetallic CompareNormal CompareRoughness Cube Duck Fox
InterpolationTest MetalRoughSpheresNoTextures MorphPrimitivesTest MorphStressTest
MultipleScenes MultiUVTest NegativeScaleTest NormalTangentMirrorTest NormalTangentTest
OrientationTest PrimitiveModeNormalsTest RecursiveSkeletons RiggedFigure RiggedSimple
SimpleMaterial SimpleMeshes SimpleMorph SimpleSkin SimpleSparseAccessor SimpleTexture
Suzanne TextureCoordinateTest TextureEncodingTest TextureLinearInterpolationTest
TextureSettingsTest Triangle TriangleWithoutIndices TwoSidedPlane VertexColorTest"

if [ "$#" -gt 0 ]; then
  models="$*"
else
  # `for` on an unquoted variable splits on whitespace, which the two awkward names
  # break, so they are appended after the split rather than living in the list.
  models="$CORE_UNDER_2MB"
fi

# THE FILE LIST COMES FROM ONE REQUEST, NOT NINETY-EIGHT.
#
# Which files a model is made of is in its directory listing, which the raw host does not
# serve. Asking the contents API per model per variant is two requests each, and
# UNAUTHENTICATED GITHUB ALLOWS SIXTY AN HOUR -- so a 49-model run got through about
# thirty models and then every remaining directory came back 403. The script printed
# those as "absent", which is a DIFFERENT FACT from "refused": "this model has no
# glTF-Binary variant" is a property of the corpus, and it is what a reader of that log
# would have concluded. One call to the git-tree API lists the whole repository instead.
fetch_tree() {
  # An offline tree, for testing this script's own guards without a network round trip.
  if [ -n "${VENDOR_TREE:-}" ]; then cp "$VENDOR_TREE" "$T/tree.json"
  else
    # A token raises the limit from sixty an hour to five thousand. `gh` is asked for one
    # only if the environment has not supplied it, and its absence is not an error --
    # one request fits inside the anonymous limit, it is the retries that do not.
    tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    [ -n "$tok" ] || tok=$(gh auth token 2>/dev/null || true)
    set -- -sSL --fail -o "$T/tree.json"
    [ -n "$tok" ] && set -- "$@" -H "Authorization: Bearer $tok"
    curl "$@" \
      "https://api.github.com/repos/KhronosGroup/glTF-Sample-Assets/git/trees/main?recursive=1" \
      || { echo "vendor_gltf: the GitHub tree API refused the request." >&2
           echo "  Sixty an hour is the unauthenticated limit; one run needs one request," >&2
           echo "  so this is usually something else having spent them. Wait for the reset," >&2
           echo "  or set GH_TOKEN (or run 'gh auth login'). NOTHING has been written." >&2
           exit 1; }
  fi
  # A truncated tree is a partial answer that looks like a complete one.
  python3 - "$T/tree.json" <<'PY' || exit 1
import json, sys
t = json.load(open(sys.argv[1]))
if t.get("truncated"):
    print("vendor_gltf: the tree came back TRUNCATED, so a missing file cannot be told "
          "from an unlisted one. Refusing to fetch from it.", file=sys.stderr)
    sys.exit(1)
PY
}

# The files of one model/variant, one per line, from the cached tree. Empty output means
# the variant is genuinely not in the repository -- which is now a fact about the corpus
# and not about a rate limit.
files_of() {
  python3 - "$T/tree.json" "$1" "$2" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
want = f"Models/{sys.argv[2]}/{sys.argv[3]}/"
for e in t["tree"]:
    if e["type"] == "blob" and e["path"].startswith(want):
        rest = e["path"][len(want):]
        if "/" not in rest:
            print(rest)
PY
}

fetch_one() {
  m="$1"
  d="$ROOT/test/data/gltf/$m"
  # THE RECORD IS BUILT ASIDE AND MOVED IN ON SUCCESS. Truncating the real one first is
  # how a rate-limited run destroyed the PROVENANCE of two models it already had and was
  # not re-fetching: the script wrote its record before it had the thing the record
  # describes.
  prov="$T/PROVENANCE.staged"
  echo "# $m -- from KhronosGroup/glTF-Sample-Assets, fetched $DATE" > "$prov"
  got=0
  for variant in glTF glTF-Binary; do
    names=$(files_of "$m" "$variant")
    [ -n "$names" ] || { echo "  $m/$variant: not in the repository"; continue; }
    mkdir -p "$d/$variant"
    # A file name can contain a space, so the list is walked a line at a time.
    printf '%s\n' "$names" | while IFS= read -r n; do
      [ -n "$n" ] || continue
      # A name can contain a space or a non-ASCII character (Box With Spaces,
      # Unicode<3>Test); --data-urlencode is not right for a path, so the URL is
      # built by python and curl is handed the finished thing.
      url=$(python3 -c "import urllib.parse,sys; print(sys.argv[1] + '/' + '/'.join(urllib.parse.quote(p) for p in sys.argv[2:]))" "$BASE" "$m" "$variant" "$n")
      curl -sSL --fail -o "$d/$variant/$n" "$url"
      sum=$(shasum -a 256 "$d/$variant/$n" | cut -d' ' -f1)
      echo "$variant/$n  $sum  $url" >> "$prov"
      echo "  $m/$variant/$n"
    done
    got=1
  done
  if [ "$got" = 1 ]; then
    mkdir -p "$d"
    mv "$prov" "$d/PROVENANCE"
  else
    echo "  $m: nothing fetched, leaving anything already here alone"
  fi
}

fetch_tree
# shellcheck disable=SC2086
for m in $models; do fetch_one "$m"; done
# The two names that whitespace splitting cannot carry. Only when the whole default list
# is being fetched -- an explicit argument list means exactly what it says.
if [ "$#" -eq 0 ]; then
  fetch_one "Box With Spaces"
  fetch_one "Unicode❤♻Test"
fi
echo "vendor_gltf: done"
