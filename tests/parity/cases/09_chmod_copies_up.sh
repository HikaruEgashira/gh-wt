# Changing permissions on a lower file copies it up.
fixture() {
    echo "x" > "$LOWER/file"
    chmod 0644 "$LOWER/file"
}

verify() {
    chmod 0600 "$MNT/file"
    local mode
    mode=$(stat -c '%a' "$MNT/file" 2>/dev/null || stat -f '%Lp' "$MNT/file")
    assert_eq "mode through mount" "600" "$mode"                       || return 1
    local lower_mode
    lower_mode=$(stat -c '%a' "$LOWER/file" 2>/dev/null || stat -f '%Lp' "$LOWER/file")
    assert_eq "lower mode untouched" "644" "$lower_mode"               || return 1
}
