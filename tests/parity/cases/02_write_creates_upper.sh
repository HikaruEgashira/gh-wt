# Writes through the mount land in the upper layer; lower is untouched.
fixture() {
    echo "lower" > "$LOWER/file.txt"
}

verify() {
    echo "modified" > "$MNT/file.txt"
    assert_eq "mount sees write"  "modified" "$(cat "$MNT/file.txt")"     || return 1
    assert_eq "lower untouched"   "lower"    "$(cat "$LOWER/file.txt")"   || return 1
    [[ -f "$UPPER/file.txt" ]]                                            || { echo "upper not populated"; return 1; }
    assert_eq "upper has new"     "modified" "$(cat "$UPPER/file.txt")"   || return 1
}
