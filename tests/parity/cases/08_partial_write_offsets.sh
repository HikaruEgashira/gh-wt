# Writing at an offset triggers copy-up of the full lower file before the
# partial overwrite (otherwise the prefix would be lost).
fixture() {
    printf 'AAAAAAAAAA' > "$LOWER/x"
}

verify() {
    # Overwrite bytes [3..6] with "BBB", expect "AAABBBAAAA".
    printf 'BBB' | dd of="$MNT/x" bs=1 seek=3 conv=notrunc 2>/dev/null
    assert_eq "partial overwrite preserved prefix/suffix" "AAABBBAAAA" "$(cat "$MNT/x")" || return 1
}
