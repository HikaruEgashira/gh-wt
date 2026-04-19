# Renaming a lower-only file copies it up at the destination and hides
# the old name.
fixture() {
    echo "data" > "$LOWER/src.txt"
}

verify() {
    mv "$MNT/src.txt" "$MNT/dst.txt"
    [[ ! -e "$MNT/src.txt" ]]                                || { echo "src still visible"; return 1; }
    assert_eq "dst contents" "data" "$(cat "$MNT/dst.txt")"  || return 1
    [[ -f "$LOWER/src.txt" ]]                                || { echo "lower should be intact"; return 1; }
}
