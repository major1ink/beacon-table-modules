#!/usr/bin/env bash
# Выпуск модулей: для каждого модуля, у которого тега <id>/v<версия> ещё нет,
# проверяет его, собирает .btmod и создаёт выпуск на GitHub; затем обновляет
# index.json в ветке gh-pages. Модули с неподнятой версией пропускаются.
#
# Переменные:
#   BTMOD     путь к утилите btmod (обязательно)
#   REPO      владелец/репозиторий, например major1ink/beacon-table-modules (обязательно)
#   DRY_RUN   непусто — ничего не создавать и не отправлять, только показать
#   GH        команда gh (по умолчанию gh)
set -euo pipefail

: "${BTMOD:?нужен путь к btmod}"
: "${REPO:?нужен владелец/репозиторий}"
GH="${GH:-gh}"
DRY_RUN="${DRY_RUN:-}"
SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
DOWNLOADS="https://github.com/${REPO}/releases/download"

run() {
  if [ -n "$DRY_RUN" ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

rm -rf dist prev
mkdir -p dist prev
released=()

for dir in modules/*/; do
  dir="${dir%/}"
  IFS=$'\t' read -r id version title < <("$BTMOD" info "$dir")
  tag="${id}/v${version}"
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    echo "пропуск ${tag}: выпуск уже есть"
    continue
  fi

  args=(--tag "$tag")
  prev_tag="$(git tag -l "${id}/v*" --sort=-v:refname | head -n 1)"
  if [ -n "$prev_tag" ]; then
    rm -f prev/*.summary.json
    "$GH" release download "$prev_tag" --repo "$REPO" --pattern '*.summary.json' --dir prev >/dev/null 2>&1 || true
    prev_summary="$(ls prev/*.summary.json 2>/dev/null | head -n 1 || true)"
    if [ -n "$prev_summary" ]; then
      args+=(--prev-summary "$prev_summary")
    else
      echo "предупреждение: сводка ${prev_tag} не скачалась, вечность slug не проверена"
    fi
  fi

  echo "== ${tag}"
  "$BTMOD" validate "${args[@]}" "$dir"
  "$BTMOD" pack -o dist "$dir"

  base="${id}-${version}"
  run "$GH" release create "$tag" \
    "dist/${base}.btmod" "dist/${base}.sha256" "dist/${base}.summary.json" \
    --repo "$REPO" --target "$SHA" --title "${title} ${version}" \
    --notes-file "dist/${base}.notes.md" --latest=false
  released+=("$tag")
done

if [ "${#released[@]}" -eq 0 ]; then
  echo "новых версий нет"
  exit 0
fi

# index.json: прежний каталог с gh-pages плюс только что выпущенные модули.
site="$(mktemp -d)"
git fetch origin gh-pages:refs/remotes/origin/gh-pages >/dev/null 2>&1 || true
merge=()
if git show origin/gh-pages:index.json >"${site}/old.json" 2>/dev/null; then
  merge=(--merge "${site}/old.json")
fi
"$BTMOD" index -o "${site}/index.json" --base-url "$DOWNLOADS" "${merge[@]}" dist

if [ -n "$DRY_RUN" ]; then
  echo "[dry-run] index.json (${#released[@]} новых):"
  cat "${site}/index.json"
  exit 0
fi

work="$(mktemp -d)"
if git rev-parse -q --verify origin/gh-pages >/dev/null; then
  git worktree add "$work" origin/gh-pages --detach >/dev/null
else
  git worktree add --detach "$work" >/dev/null
  git -C "$work" checkout --orphan gh-pages >/dev/null 2>&1
  git -C "$work" rm -rf . >/dev/null 2>&1 || true
fi
cp "${site}/index.json" "${work}/index.json"
touch "${work}/.nojekyll"
git -C "$work" add index.json .nojekyll
git -C "$work" -c user.name="github-actions" -c user.email="actions@users.noreply.github.com" \
  commit -m "index: ${released[*]}"
git -C "$work" push origin HEAD:refs/heads/gh-pages
