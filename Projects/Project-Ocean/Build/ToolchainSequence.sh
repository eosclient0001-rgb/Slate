#!/usr/bin/env bash
# Frontier/Projects/Project-Ocean/Build/ToolchainSequence.sh
#   Serves Project-Ocean (a WebGPU page: index.html + ES modules + WGSL) from Source/ over HTTP. No compiler, no npm,
#   no C++: the only toolchain is the browser. Uses python3's http.server with the WGSL MIME type registered.
#
#     bash Projects/Project-Ocean/Build/ToolchainSequence.sh                 # http://localhost:8766/
#     bash Projects/Project-Ocean/Build/ToolchainSequence.sh --port 9001
#     bash Projects/Project-Ocean/Build/ToolchainSequence.sh --bind 0.0.0.0  # reachable from another machine / a preview proxy
#     bash Projects/Project-Ocean/Build/ToolchainSequence.sh --check         # validate the source tree only
#
#   Stop with Ctrl-C.

set -euo pipefail
ScriptRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SourceRoot="$(cd "$ScriptRoot/../Source" && pwd)"
Port=8766
Bind=127.0.0.1
CheckOnly=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)  Port="$2"; shift 2 ;;
        --bind)  Bind="$2"; shift 2 ;;
        --check) CheckOnly=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

Required=(index.html GameExecution.js SwellSolver.js ShoalSolver.js HorizonProjection.js OceanStructure.js TimingMetrics.js
          Shaders/SeaStructure.wgsl Shaders/SwellSolver.wgsl Shaders/FoamSolver.wgsl Shaders/ShoalSolver.wgsl Shaders/HorizonProjection.wgsl)
for Relative in "${Required[@]}"; do
    if [[ ! -f "$SourceRoot/$Relative" ]]; then
        echo "Project-Ocean: missing $Relative" >&2
        exit 1
    fi
    case "$Relative" in
        *.js|*.wgsl)
            Width=$(head -n 1 "$SourceRoot/$Relative" | python3 -c 'import sys; print(len(sys.stdin.read().rstrip("\n")))')
            if [[ "$Width" != "142" ]]; then
                echo "Project-Ocean: $Relative header is $Width characters, expected 142" >&2
                exit 1
            fi ;;
    esac
done
echo "Project-Ocean: ${#Required[@]} source files present, headers 142 wide"
[[ $CheckOnly -eq 1 ]] && exit 0

echo "Project-Ocean: serving $SourceRoot at http://$Bind:$Port/  (Ctrl-C to stop)"
cd "$SourceRoot"
exec python3 - "$Bind" "$Port" <<'EOF'
import http.server, mimetypes, sys
mimetypes.add_type("text/wgsl", ".wgsl")
mimetypes.add_type("text/javascript", ".js")

class NoStore(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

http.server.ThreadingHTTPServer((sys.argv[1], int(sys.argv[2])), NoStore).serve_forever()
EOF
