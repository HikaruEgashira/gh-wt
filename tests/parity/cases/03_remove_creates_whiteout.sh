# Removing a lower-only entry hides it but leaves lower intact.
fixture() {
    echo "data" > "$LOWER/will-be-deleted.txt"
}

verify() {
    rm "$MNT/will-be-deleted.txt"                             || return 1
    [[ ! -e "$MNT/will-be-deleted.txt" ]]                     || { echo "still visible"; return 1; }
    [[ -f "$LOWER/will-be-deleted.txt" ]]                     || { echo "lower should be untouched"; return 1; }
}
