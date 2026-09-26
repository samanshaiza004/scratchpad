#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
COMMAND=${1:-test}
if [ "$#" -gt 0 ]; then shift; fi
case "$COMMAND" in build|test|run|smoke|measure) ;; *) printf 'Usage: sh tools/gpui.sh [build|test|run|smoke|measure] [gpui-dev options]\n' >&2; exit 2 ;; esac

if [ -n "${CALIBER_ROOT:-}" ]; then
    case "${SCRATCHPAD_DEV_DEPS:-}" in
        1|true|yes|TRUE|YES) "$SCRIPT_DIR/caliber.sh" sync --project-root "$PROJECT_ROOT" --override "caliber=$CALIBER_ROOT" --allow-dirty-overrides ;;
        *) "$SCRIPT_DIR/caliber.sh" sync --project-root "$PROJECT_ROOT" --override "caliber=$CALIBER_ROOT" ;;
    esac
else
    "$SCRIPT_DIR/caliber.sh" sync --project-root "$PROJECT_ROOT"
fi

cd "$PROJECT_ROOT"
if [ -n "${CALIBER_ROOT:-}" ]; then
    case "${SCRATCHPAD_DEV_DEPS:-}" in
        1|true|yes|TRUE|YES) exec go run ./cmd/gpui-dev "$COMMAND" "$@" --caliber-root "$CALIBER_ROOT" --allow-caliber-revision ;;
    esac
    exec go run ./cmd/gpui-dev "$COMMAND" "$@" --caliber-root "$CALIBER_ROOT"
else
    exec go run ./cmd/gpui-dev "$COMMAND" "$@"
fi
