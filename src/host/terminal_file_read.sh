set -eu
p=$1 limit=$2 missing=$3
fail() { printf 'ZWFILEERROR1 %s\n' "$1" >&2; exit 1; }
stamp() {
  stat -c '%d:%i:%s:%Y:%Z:%a:%u:%g:%h' "$1" 2>/dev/null ||
  stat -f '%d:%i:%z:%m:%c:%Lp:%u:%g:%l' "$1" 2>/dev/null
}
parent=${p%/*} base=${p##*/}
cd -P "${parent:-/}" || fail InvalidParent
p=./$base
[ ! -L "$p" ] || fail SymlinkUnsupported
if [ ! -e "$p" ]; then
  [ "$missing" = 1 ] || fail FileNotFound
  printf 'ZWFILE1 absent\n'; exit 0
fi
[ -f "$p" ] || fail NotRegularFile
before=$(stamp "$p") || fail UnsupportedFileMetadata
size=$(wc -c < "$p") || fail FileReadFailed
[ "$size" -le "$limit" ] || fail FileTooLarge
printf 'ZWFILE1 %s\n' "$before"
dd if="$p" bs=4096 count=$((limit / 4096 + 1)) || fail FileReadFailed
[ ! -L "$p" ] || fail SourceChanged
after=$(stamp "$p") || fail SourceChanged
[ "$before" = "$after" ] || fail SourceChanged
printf '\nZWEND1 %s\n' "$after"
