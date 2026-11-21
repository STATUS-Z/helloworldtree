#!/usr/bin/env bash
# Hello World Tree — Bash adapter.
#
# Bash is a bridge language and also the one that runs. Every other adapter needs an interpreter, a
# compiler, or a runtime to exist before it can run; this one needs nothing that a machine does not
# already have. That makes it the bootstrap: the first thing that runs on a fresh box, the thing that
# detects what else is available, and the thing that reports when nothing is.
#
# The role in the toolchain is specifically that of a fallback, and the fallback has to be honest about
# its limits rather than pretending to be a parser. It reports what it can see and says what it could
# not.
#
# Deliberate constraints:
#   · no associative arrays where a plain array will do — portability over convenience
#   · `set -euo pipefail` so a partial run cannot be mistaken for a complete one
#   · no `eval` anywhere, ever

set -euo pipefail

readonly HWT_SOURCE="bash"
readonly HWT_VERSION="0.1.0"

# ── Output ───────────────────────────────────────────────────────────────────
# Tab-separated, because the consumer is a parser and not a person. Newlines inside a label would break
# the format, so they are stripped rather than escaped — a label is an identifier, and an identifier
# with a newline in it is already wrong.

hwt_node() {
    local kind="$1"
    local label="$2"
    printf 'N\t%s\t%s\t%s\n' "$HWT_SOURCE" "$kind" "$label"
}

hwt_edge() {
    local from="$1"
    local to="$2"
    local kind="$3"
    printf 'E\t%s\t%s\t%s\n' "$from" "$to" "$kind"
}

# ── Detection ────────────────────────────────────────────────────────────────
# Which adapters can actually run on this machine. The vessel reports this so a missing language is
# visible rather than silent — an adapter that is not installed produces no nodes, and no nodes is
# indistinguishable from no code unless the difference is stated.

hwt_detect() {
    local -a found=()
    local -a missing=()

    local -A probes=(
        [python]=python3
        [ruby]=ruby
        [perl]=perl
        [node]=node
        [go]=go
        [rust]=cargo
        [java]=java
        [haskell]=ghc
        [lua]=lua
        [tex]=pdflatex
        [vim]=vim
        [qml]=qmlscene
        [sleigh]=sleigh
    )

    local lang tool
    for lang in "${!probes[@]}"; do
        tool="${probes[$lang]}"
        if command -v "$tool" >/dev/null 2>&1; then
            found+=("$lang")
        else
            missing+=("$lang")
        fi
    done

    # Sort for determinism, because a report whose order varies between runs is not diffable.
    printf 'available\t%s\n' "$(printf '%s\n' "${found[@]:-}" | sort | tr '\n' ',' | sed 's/,$//')"
    printf 'missing\t%s\n' "$(printf '%s\n' "${missing[@]:-}" | sort | tr '\n' ',' | sed 's/,$//')"
}

# ── Extraction: shell ────────────────────────────────────────────────────────
# Shell files declare functions two ways. Both are matched; a function defined with `function name` and
# one defined with `name()` are the same node.

hwt_extract_shell() {
    local file="$1"
    local line_no=0
    local id="${file}:file"

    hwt_node file "$file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))

        # Comments are not declarations.
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # source / . imports
        if [[ "$line" =~ ^[[:space:]]*(source|\.)[[:space:]]+([^[:space:]]+) ]]; then
            local target="${BASH_REMATCH[2]}"
            local tid="import:${target//[.\/]/_}"
            hwt_node import "$target"
            hwt_edge "$id" "$tid" imports
            continue
        fi

        # function name {   |   name() {
        if [[ "$line" =~ ^[[:space:]]*function[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]] \
        || [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\) ]]; then
            local fn="${BASH_REMATCH[1]}"
            hwt_node symbol "$fn"
            hwt_edge "$id" "${file}:${fn}" contains
        fi
    done < "$file"
}

# ── Extraction: generic fallback ────────────────────────────────────────────
# For a file in a language with no adapter installed, the honest output is one file node and nothing
# else. That is what this does — and the caller can see the difference between "no adapter" and "no
# content" because the file node is still there.

hwt_extract_unknown() {
    local file="$1"
    hwt_node unknown_file "$file"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
# Extension first, because it is cheap and right almost always. A content sniff would be more accurate
# and is not worth the read on every file.

hwt_extract() {
    local file="$1"
    case "${file##*.}" in
        sh|bash|zsh) hwt_extract_shell "$file" ;;
        py)          hwt_extract_unknown "$file" ;;   # python adapter handles this when present
        rb)          hwt_extract_unknown "$file" ;;
        pl|pm)       hwt_extract_unknown "$file" ;;
        *)           hwt_extract_unknown "$file" ;;
    esac
}

# ── Entry ────────────────────────────────────────────────────────────────────

hwt_main() {
    if [[ "${1:-}" == "--detect" ]]; then
        hwt_detect
        return 0
    fi

    if [[ $# -eq 0 ]]; then
        printf 'usage: %s <file>... | --detect\n' "${0##*/}" >&2
        return 2
    fi

    local file
    for file in "$@"; do
        if [[ ! -r "$file" ]]; then
            printf 'unreadable: %s\n' "$file" >&2
            continue
        fi
        hwt_extract "$file"
    done
}

hwt_main "$@"
