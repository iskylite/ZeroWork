set -eu
p=$1 mode=$2 old_size=$3 new_size=$4 expected_stamp=$5
fail() { printf 'ZWFILEERROR1 %s\n' "$1" >&2; exit 1; }
stamp() {
  stat -c '%d:%i:%s:%Y:%Z:%a:%u:%g:%h' "$1" 2>/dev/null ||
  stat -f '%d:%i:%z:%m:%c:%Lp:%u:%g:%l' "$1" 2>/dev/null
}
metadata() {
  value=$(stamp "$1") || return 1
  saved_ifs=$IFS
  IFS=:
  set -- $value
  IFS=$saved_ifs
  printf '%s:%s:%s' "$6" "$7" "$8"
}
parent=${p%/*} base=${p##*/}
[ -n "$parent" ] || parent=/
cd -P "$parent" || fail InvalidParent
p=./$base
[ ! -L "$p" ] || fail SymlinkUnsupported
umask 077
tmp=$(mktemp -d ./.zerowork-file.XXXXXXXX) || fail TemporaryFileFailed
cleanup() {
  rm -f "$tmp/before" "$tmp/new/$base"
  rmdir "$tmp/new" 2>/dev/null || :
  rmdir "$tmp" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 1' 1 2 15
mkdir "$tmp/new" || fail TemporaryFileFailed
candidate=$tmp/new/$base
dd bs=1 count="$old_size" of="$tmp/before" || fail TemporaryFileFailed
actual_size=$(wc -c < "$tmp/before") || fail TemporaryFileFailed
[ "$actual_size" -eq "$old_size" ] || fail IncompleteInput
if [ "$mode" = replace ]; then
  [ -f "$p" ] && [ ! -L "$p" ] || fail SourceChanged
  [ -w "$p" ] || fail FileNotWritable
  [ "$(stamp "$p")" = "$expected_stamp" ] || fail SourceChanged
  cmp -s "$tmp/before" "$p" || fail SourceChanged
  # cp -p must succeed: ownership/mode preservation is never silently dropped.
  if cp --version >/dev/null 2>&1; then
    cp --preserve=all "$p" "$candidate" || fail MetadataPreservationFailed
  else
    cp -p "$p" "$candidate" || fail MetadataPreservationFailed
  fi
  [ "$(metadata "$p")" = "$(metadata "$candidate")" ] || fail MetadataPreservationFailed
else
  [ ! -e "$p" ] && [ ! -L "$p" ] || fail PathAlreadyExists
  command -v link >/dev/null 2>&1 || fail ExclusiveCommitUnsupported
fi
dd bs=1 count="$new_size" of="$candidate" || fail TemporaryFileFailed
actual_size=$(wc -c < "$candidate") || fail TemporaryFileFailed
[ "$actual_size" -eq "$new_size" ] || fail IncompleteInput
[ "$(dd bs=1 count=1 2>/dev/null | wc -c)" -eq 0 ] || fail InvalidInput
if [ "$mode" = replace ]; then
  [ ! -L "$p" ] && [ -f "$p" ] || fail SourceChanged
  [ "$(stamp "$p")" = "$expected_stamp" ] || fail SourceChanged
  cmp -s "$tmp/before" "$p" || fail SourceChanged
  # Destination is the pinned working directory, never a raced target directory.
  mv -f "$candidate" . || fail CommitFailed
else
  # link(2) fails if the exact destination exists, including a directory.
  link "$candidate" "$p" || fail ExclusiveCommitFailed
fi
printf 'ZWCOMMIT1\n'
