#!/usr/bin/env bash
# Proves scripts/exp-sweep.sh: a closed Issue's dir goes (any age), an open one's stays (any age), an
# unknown one follows the idle rule, and anything not named exp<digits>/agw<digits> is left alone.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
command -v jq >/dev/null 2>&1 || { echo "✗ test needs jq" >&2; exit 1; }
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
bin="$root/bin"; mkdir -p "$bin" "$root/home"

# A stand-in factory: Issue 100 closed, 200 working, anything else unanswered (exit 1).
cat > "$bin/factory" <<'STUB'
#!/usr/bin/env bash
case "$3" in
  issue_100) echo '{"state":"closed"}' ;;
  issue_200) echo '{"state":"working"}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$bin/factory"

old() { python3 -c 'import os,sys,time;t=time.time()-5*86400;[os.utime(os.path.join(d,f),(t,t)) for d,_,fs in os.walk(sys.argv[1]) for f in fs+["."]]' "$1"; }
mk() { # name age(fresh|old)
  mkdir -p "$root/home/$1/sub"; echo x > "$root/home/$1/sub/file"
  [ "$2" = old ] && old "$root/home/$1"
  return 0
}
mk exp100 fresh   # closed, fresh   -> removed
mk agw100 old     # closed, agw     -> removed
mk exp200 old     # open, idle      -> kept
mk exp300 old     # unknown, idle   -> removed
mk exp400 fresh   # unknown, fresh  -> kept
mk exp500 fresh   # named by --closed -> removed
mk expfoo old     # not an issue dir -> kept
mkdir -p "$root/elsewhere"; ln -s "$root/elsewhere" "$root/home/exp600"   # symlink -> kept

run() { EXP_ROOT="$root/home" EXP_SWEEP_FACTORY="$bin/factory" bash "$here/exp-sweep.sh" "$@" >"$root/out" 2>&1 || { echo "✗ exp-sweep exited non-zero" >&2; cat "$root/out" >&2; fail=1; }; }
run --closed 500

expect() { # name present|gone
  if [ "$2" = gone ] && [ -e "$root/home/$1" ]; then echo "✗ $1 should be removed" >&2; fail=1; fi
  if [ "$2" = present ] && [ ! -e "$root/home/$1" ]; then echo "✗ $1 should be kept" >&2; fail=1; fi
}
expect exp100 gone; expect agw100 gone; expect exp300 gone; expect exp500 gone
expect exp200 present; expect exp400 present; expect expfoo present; expect exp600 present
[ -d "$root/elsewhere" ] || { echo "✗ a symlink's target was followed" >&2; fail=1; }
grep -q "removed exp100 .*Issue 100 closed" "$root/out" || { echo "✗ no log line for exp100" >&2; fail=1; }
grep -q "kept exp200: Issue 200 is not closed" "$root/out" || { echo "✗ no log line for exp200" >&2; fail=1; }

[ "$fail" -eq 0 ] && echo "OK: exp-sweep"
exit "$fail"
