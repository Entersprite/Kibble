#!/usr/bin/env bash
# Connect a private maintainer checkout without replacing local files.
set -euo pipefail

code_dir=$(cd "$(dirname "$0")/.." && pwd -P)
common_dir=$(git -C "$code_dir" rev-parse --git-common-dir)
case "$common_dir" in
    /*) ;;
    *) common_dir="$code_dir/$common_dir" ;;
esac
common_dir=$(cd "$common_dir" && pwd -P)
main_dir=$(dirname "$common_dir")
docs_dir=${KIBBLE_DOCS_PATH:-$(dirname "$main_dir")/kibbledocs}
case "$docs_dir" in
    /*) ;;
    *) echo "KIBBLE_DOCS_PATH must be an absolute path." >&2; exit 1 ;;
esac

if [[ ! -e "$docs_dir" ]]; then
    origin=$(git -C "$code_dir" remote get-url origin)
    case "$origin" in
        git@github-personal:*) remote=git@github-personal:Entersprite/KibbleDocs.git ;;
        git@github.com:*) remote=git@github.com:Entersprite/KibbleDocs.git ;;
        ssh://git@github-personal/*) remote=ssh://git@github-personal/Entersprite/KibbleDocs.git ;;
        ssh://git@github.com/*) remote=ssh://git@github.com/Entersprite/KibbleDocs.git ;;
        *) remote=https://github.com/Entersprite/KibbleDocs.git ;;
    esac
    git clone "$remote" "$docs_dir"
fi

docs_dir=$(cd "$docs_dir" && pwd -P)
if [[ $(git -C "$docs_dir" rev-parse --show-toplevel) != "$docs_dir" ]]; then
    echo "Expected a separate KibbleDocs checkout at $docs_dir." >&2
    exit 1
fi
docs_origin=$(git -C "$docs_dir" remote get-url origin)
case "$docs_origin" in
    git@github-personal:Entersprite/KibbleDocs.git|git@github.com:Entersprite/KibbleDocs.git|https://github.com/Entersprite/KibbleDocs.git|https://github.com/Entersprite/KibbleDocs|ssh://git@github-personal/Entersprite/KibbleDocs.git|ssh://git@github.com/Entersprite/KibbleDocs.git) ;;
    *) echo "Unexpected KibbleDocs remote: $docs_origin" >&2; exit 1 ;;
esac
for file in AGENTS.md CLAUDE.md; do
    [[ -f "$docs_dir/$file" ]] || { echo "Missing $docs_dir/$file" >&2; exit 1; }
done

# Preflight every link before creating any: conflicting local work is preserved.
for name in docs Spikes .superpowers reference; do
    [[ -d "$docs_dir/$name" ]] || { echo "Missing $docs_dir/$name" >&2; exit 1; }
    link="$code_dir/$name"
    if [[ -e "$link" || -L "$link" ]]; then
        if [[ ! -L "$link" ]] || [[ $(cd "$link" && pwd -P) != "$docs_dir/$name" ]]; then
            echo "Preserving existing $link; move it aside manually before setup." >&2
            exit 1
        fi
    fi
done
for name in docs Spikes .superpowers reference; do
    link="$code_dir/$name"
    if [[ ! -L "$link" ]]; then
        if [[ $(dirname "$docs_dir") == $(dirname "$code_dir") ]]; then
            ln -s "../$(basename "$docs_dir")/$name" "$link"
        else
            ln -s "$docs_dir/$name" "$link"
        fi
    fi
done
printf 'Private documentation: %s\nRead AGENTS.md and CLAUDE.md there before maintainer work.\n' "$docs_dir"
