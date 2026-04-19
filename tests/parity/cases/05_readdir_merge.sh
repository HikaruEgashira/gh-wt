# readdir merges lower and upper, with upper precedence.
fixture() {
    mkdir -p "$LOWER"
    echo "L1" > "$LOWER/lower-only.txt"
    echo "L2" > "$LOWER/shared.txt"
}

verify() {
    echo "U1" > "$MNT/upper-only.txt"        # creates in upper
    echo "U2" > "$MNT/shared.txt"            # copies up + overwrites
    local listing
    listing=$(cd "$MNT" && ls | sort | tr '\n' ' ')
    assert_eq "merged listing" "lower-only.txt shared.txt upper-only.txt " "$listing" || return 1
    assert_eq "upper wins" "U2" "$(cat "$MNT/shared.txt")" || return 1
    assert_eq "lower preserved" "L2" "$(cat "$LOWER/shared.txt")" || return 1
}
