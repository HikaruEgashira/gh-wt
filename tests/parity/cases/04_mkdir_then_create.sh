# mkdir + create file in a fresh subtree.
fixture() { :; }

verify() {
    mkdir "$MNT/newdir"
    echo "x" > "$MNT/newdir/x.txt"
    [[ -d "$MNT/newdir" ]]                                            || return 1
    assert_eq "new file"   "x" "$(cat "$MNT/newdir/x.txt")"           || return 1
    assert_eq "lower clean" "" "$(ls "$LOWER" 2>/dev/null)"           || return 1
}
