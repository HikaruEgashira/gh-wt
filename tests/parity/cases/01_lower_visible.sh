# Lower-only files are visible through the mount, with the same contents.
fixture() {
    mkdir -p "$LOWER/dir"
    echo "hello" > "$LOWER/dir/file.txt"
    echo "root" > "$LOWER/root.txt"
}

verify() {
    [[ -f "$MNT/root.txt" ]]                                    || { echo "root.txt missing"; return 1; }
    [[ -f "$MNT/dir/file.txt" ]]                                || { echo "dir/file.txt missing"; return 1; }
    assert_eq "root contents" "root" "$(cat "$MNT/root.txt")"   || return 1
    assert_eq "nested contents" "hello" "$(cat "$MNT/dir/file.txt")" || return 1
}
