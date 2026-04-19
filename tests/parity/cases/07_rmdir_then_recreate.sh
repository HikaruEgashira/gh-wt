# Remove a lower directory, then mkdir at the same name. The lower's
# contents must NOT reappear (opaque semantics).
fixture() {
    mkdir -p "$LOWER/d"
    echo "L" > "$LOWER/d/leaf.txt"
}

verify() {
    rm "$MNT/d/leaf.txt"
    rmdir "$MNT/d"
    mkdir "$MNT/d"
    [[ -d "$MNT/d" ]]                                                || return 1
    local listing
    listing=$(ls "$MNT/d" 2>/dev/null | sort | tr '\n' ' ')
    assert_eq "recreated dir is empty" "" "$listing"                 || return 1
}
