#!/usr/bin/env bash
# Webinar site (webinar.quantifycapital.co.in) - safe editing tool. Run it from anywhere:  ~/Projects/Active/Webinar/tools/site.sh help
#
# The web root is LIVE once the Cloudflare hostname points at it: editing a file there changes the public site at once (and
# code-server auto-saves half-typed pages). Work in drafts/ and publish through this tool: it checks the pages first, backs up
# the web root, swaps the files in atomically and tests the server. Adapted from Growthify-2/tools/site.sh (4 Nov 2026).
set -u
SITE="Webinar"
PROJECT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
WEBROOT="${WEBROOT:-$HOME/Projects/Active/Websites/webinar}"           # what the webinar-site Caddy serves (public)
DRAFTS="${DRAFTS:-$PROJECT/drafts}"                                     # your working copies (private)
BASE="$DRAFTS/.base"                                                    # md5 of each live file when you pulled / published it
ARCHIVE="${ARCHIVE:-$HOME/Projects/Archive}"                            # backups + staging (private, same disk -> atomic rename)
BACKUPS="${BACKUPS:-$ARCHIVE/site-backups/webinar}"
LOCAL_URL="${LOCAL_URL:-http://127.0.0.1:8026}"; HOST_HDR="webinar.quantifycapital.co.in"
PAGES="index.html ty.html"

say()  { printf '%s\n' "$*"; }
die()  { printf 'STOPPED - %s\n' "$*" >&2; exit 1; }
md5of(){ [ -f "$1" ] && md5sum "$1" | cut -c1-12 || echo "(missing)"; }
all_files(){ # pages + every asset in drafts/
  local f; for f in $PAGES; do echo "$f"; done
  [ -d "$DRAFTS/assets" ] && (cd "$DRAFTS" && find assets -type f ! -name '.*' | sort); }

# ---------------------------------------------------------------- checks (static, on a folder) -------------------------------
FAILS=0; WARNS=0
ok()   { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
warn() { printf '  warn  %s\n' "$*"; WARNS=$((WARNS+1)); }
count(){ grep -o -F -- "$1" "$2" 2>/dev/null | wc -l; }
expect(){ local n; n=$(count "$2" "$1"); if [ "$n" = "$3" ]; then ok "$1: $4 ($n)"; else fail "$1: $4 - found $n, expected $3"; fi; }

run_checks() {
  local d="$1" p ref; FAILS=0; WARNS=0
  say "checking $d"
  for p in $PAGES; do [ -s "$d/$p" ] && ok "$p present" || fail "$p missing or empty"; done
  for p in $PAGES; do
    [ -s "$d/$p" ] || continue
    expect "$d/$p" "<html" 1 "one <html>"; expect "$d/$p" "</html>" 1 "one </html>"; expect "$d/$p" "</body>" 1 "one </body>"
    # owner's decision 4 Nov 2026: NO tracking on the webinar pages
    expect "$d/$p" "fbq(" 0 "no Meta pixel"; expect "$d/$p" "connect.facebook.net" 0 "no Meta script"
    expect "$d/$p" "googletagmanager" 0 "no Tag Manager / Google tag"; expect "$d/$p" "gtag(" 0 "no gtag"
    for ref in $(grep -o -E '(src|href)="(\./)?assets/[^"]+"' "$d/$p" | sed -E 's/^(src|href)="(\.\/)?//; s/"$//' | sort -u); do
      [ -s "$d/$ref" ] || fail "$p: refers to $ref, which is not there"; done
  done
  [ -s "$d/index.html" ] && {
    grep -q 'sheetUrl: "https://script.google.com/macros/s/[A-Za-z0-9_-]\{20,\}/exec"' "$d/index.html" \
      && ok "index.html: Google Sheet web app URL set" || fail "index.html: CONFIG.sheetUrl not set (registrations would be LOST)"
    expect "$d/index.html" 'thankYouUrl: "ty.html"' 1 "after saving -> ty.html"
  }
  [ -s "$d/ty.html" ] && {
    grep -q -E 'whatsappUrl: "https://(chat\.whatsapp\.com|wa\.me|whatsapp\.com)/[^"]+"' "$d/ty.html" \
      && ok "ty.html: WhatsApp group link set" || fail "ty.html: CONFIG.whatsappUrl not set (the WhatsApp button would be hidden)"
  }
  local bad; bad=$(find "$d" \( -name '.*' -o -name '*.md' -o -name '*.bak' -o -name '*.orig' -o -name '*.env' -o -name '*.sqlite*' -o -name '*.log' -o -name '*.sh' -o -name '*.key' -o -name '*.gs' -o -name '*.zip' \) -not -path "$d" -not -path "$DRAFTS/.base" -not -path "$DRAFTS/.base/*" 2>/dev/null | head -5)
  [ -z "$bad" ] && ok "no private/hidden files in the folder" || fail "private-looking files: $bad"
  say "result: $FAILS fail, $WARNS warn"; [ "$FAILS" = 0 ]
}

http_check() {
  say "server check ($LOCAL_URL, Host: $HOST_HDR)"
  local p c rc=0; for p in "" ty.html assets/sourabh.jpg; do
    c=$(curl -s -o /dev/null -m 10 -H "Host: $HOST_HDR" -w '%{http_code}' "$LOCAL_URL/$p"); [ "$c" = 200 ] && ok "/$p -> 200" || { fail "/$p -> $c"; rc=1; }; done
  return $rc
}

# ---------------------------------------------------------------- backup / restore ---------------------------------------------
backup() {   # every backup gets its OWN folder (never overwrite an older one)
  local ts dest n=1; ts=$(date +%Y%m%d_%H%M%S); dest="$BACKUPS/$ts"
  while [ -e "$dest" ]; do n=$((n+1)); dest="$BACKUPS/$ts-$n"; done
  mkdir -p "$dest" && cp -a "$WEBROOT"/. "$dest"/ || die "backup failed - nothing changed"
  LAST_BACKUP="$(basename "$dest")"; say "backup: $dest  ($(du -sh "$dest" | cut -f1))"
}
restore() {
  local ts="${1:-}"; shift || true
  [ -n "$ts" ] && [ -d "$BACKUPS/$ts" ] || { say "available backups:"; ls -1 "$BACKUPS" 2>/dev/null | tail -15; die "usage: site.sh restore <timestamp> [file ...]   (default: everything in that backup)"; }
  local files f; if [ $# -eq 0 ]; then files=$(cd "$BACKUPS/$ts" && find . -type f | sed 's|^\./||' | sort); else files="$*"; fi
  if [ -z "$files" ]; then   # the backup taken before the FIRST publish is empty - nothing to copy back
    die "backup $ts is empty (the site was not published yet then). To take the site offline instead: cd ~/Projects/Active/Tools/webinar-site && docker compose stop"
  fi
  for f in $files; do [ -f "$BACKUPS/$ts/$f" ] || die "$f is not in backup $ts"; done
  backup
  for f in $files; do mkdir -p "$WEBROOT/$(dirname "$f")"; cp -p "$BACKUPS/$ts/$f" "$ARCHIVE/.restore.$$" && mv -f "$ARCHIVE/.restore.$$" "$WEBROOT/$f" && say "restored $f from $ts"; done
  for f in $files; do mkdir -p "$BASE/$(dirname "$f")"; md5of "$WEBROOT/$f" > "$BASE/$f.md5"; done
  say "files added after $ts are left in place (nothing is deleted)"
}

# ---------------------------------------------------------------- drafts -------------------------------------------------------
pull() {
  mkdir -p "$DRAFTS" "$BASE"; local files="${*:-$PAGES}" f
  for f in $files; do
    [ -f "$WEBROOT/$f" ] || die "$f is not in the web root"
    if [ -f "$DRAFTS/$f" ] && [ -f "$BASE/$f.md5" ] && [ "$(md5of "$DRAFTS/$f")" != "$(cat "$BASE/$f.md5")" ]; then say "skipped $f - drafts/$f has unpublished edits (delete it first to start over)"; continue; fi
    mkdir -p "$DRAFTS/$(dirname "$f")" "$BASE/$(dirname "$f")"
    cp -p "$WEBROOT/$f" "$DRAFTS/$f" && md5of "$WEBROOT/$f" > "$BASE/$f.md5" && say "pulled $f  (live md5 $(cat "$BASE/$f.md5"))"
  done
}
publish() {
  [ $# -gt 0 ] || die "usage: site.sh publish all | index.html [ty.html assets/x.png ...]   (files from drafts/)"
  local files f stage; if [ "$1" = all ]; then files=$(all_files); else files="$*"; fi
  for f in $files; do
    case "$f" in index.html|ty.html|assets/*) ;; *) die "$f is not a page (index.html, ty.html) or under assets/";; esac
    case "$f" in *..*|/*) die "bad path $f";; esac
    [ -f "$DRAFTS/$f" ] || die "drafts/$f does not exist"
    if [ -f "$WEBROOT/$f" ]; then   # someone changed the live file since we last pulled / published it
      [ "$(md5of "$WEBROOT/$f")" = "$(cat "$BASE/$f.md5" 2>/dev/null)" ] || die "the LIVE $f changed since you pulled it. Run: site.sh diff $f - then pull again. Nothing was changed."
    fi
  done
  mkdir -p "$ARCHIVE"; stage=$(mktemp -d "$ARCHIVE/.stage.XXXXXX") || die "cannot create staging folder"
  cp -a "$WEBROOT"/. "$stage"/
  for f in $files; do mkdir -p "$stage/$(dirname "$f")"; cp "$DRAFTS/$f" "$stage/$f"; chmod 644 "$stage/$f"; done
  find "$stage" -mindepth 1 -type d -exec chmod 755 {} +
  if ! run_checks "$stage"; then rm -rf "$stage"; die "checks failed - NOTHING was changed. Fix drafts/ and run publish again."; fi
  backup
  for f in $files; do   # assets first so a new page never points at a missing image
    case "$f" in assets/*) mkdir -p "$WEBROOT/$(dirname "$f")" && chmod 755 "$WEBROOT/$(dirname "$f")"; mv -f "$stage/$f" "$WEBROOT/$f"; mkdir -p "$BASE/$(dirname "$f")"; md5of "$WEBROOT/$f" > "$BASE/$f.md5"; say "published $f";; esac
  done
  for f in $files; do
    case "$f" in assets/*) ;; *) mv -f "$stage/$f" "$WEBROOT/$f" && md5of "$WEBROOT/$f" > "$BASE/$f.md5" && say "published $f (md5 $(cat "$BASE/$f.md5"))";; esac
  done
  rm -rf "$stage"; http_check || say "the server check failed - roll back with: $0 restore $LAST_BACKUP"
  say "undo:  $0 restore $LAST_BACKUP"
}
status() {
  say "site: $SITE   web root: $WEBROOT   server: $LOCAL_URL"; local f
  for f in $(all_files); do printf '  %-24s live %-12s draft %-12s published/pulled %s\n' "$f" "$(md5of "$WEBROOT/$f")" "$(md5of "$DRAFTS/$f")" "$(cat "$BASE/$f.md5" 2>/dev/null || echo -)"; done
  say "backups: $(ls -1 "$BACKUPS" 2>/dev/null | wc -l)  (latest: $(ls -1 "$BACKUPS" 2>/dev/null | tail -1))"
}

case "${1:-help}" in
  check)   if [ "${2:-}" = drafts ]; then run_checks "$DRAFTS"; exit $?; fi
           run_checks "${2:-$WEBROOT}"; rc=$?; [ -z "${2:-}" ] && { http_check || rc=1; }; exit $rc ;;
  backup)  backup ;;
  restore) shift; restore "$@" ;;
  pull)    shift; pull "$@" ;;
  publish) shift; publish "$@" ;;
  diff)    f="${2:-}"; [ -n "$f" ] || die "usage: site.sh diff index.html"; if [ -f "$WEBROOT/$f" ]; then diff -u "$WEBROOT/$f" "$DRAFTS/$f" | head -200; else say "$f is new (not live yet)"; fi ;;
  status)  status ;;
  *) cat <<EOF
$SITE - safe site tool           (live web root: $WEBROOT)
  site.sh status                 live vs drafts, per file
  site.sh check [drafts]         static checks on the LIVE files + the server (or on drafts/)
  site.sh pull [file ...]        copy live files into drafts/ (default: the 2 pages) - edit THESE
  site.sh diff <file>            what your draft changes
  site.sh publish all            checks -> backup -> swap -> server test, for both pages + every image in drafts/assets
  site.sh publish <file ...>     the same for chosen files, e.g. index.html or assets/sourabh.jpg
  site.sh backup                 full copy of the web root to $BACKUPS
  site.sh restore <stamp> [file ...]   put files back from a backup (backs up the current state first)
EOF
  ;;
esac
