#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
COMMAND=${1:-test}
if [ "$#" -gt 0 ]; then shift; fi
case "$COMMAND" in
    build|test|smoke|run) ;;
    *) printf 'Usage: sh tools/alicorn.sh [build|test|smoke|run] [alicorn-dev options]\n' >&2; exit 2 ;;
esac

GO_EXEC=${SCRATCHPAD_GO:-go}
if ! command -v "$GO_EXEC" >/dev/null 2>&1; then
    printf 'Go executable not found: %s. Install Go with cgo enabled or set SCRATCHPAD_GO.\n' "$GO_EXEC" >&2
    exit 1
fi

"$SCRIPT_DIR/caliber.sh" sync --project-root "$PROJECT_ROOT"
cd "$PROJECT_ROOT"
exec "$GO_EXEC" run ./cmd/alicorn-dev "$COMMAND" --go "$GO_EXEC" "$@"
