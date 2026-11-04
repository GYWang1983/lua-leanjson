# Validate one complete Memcheck process log. Counts may use comma grouping.
function count(value) {
    return value ~ /^[0-9]+$/ || value ~ /^[0-9][0-9]?[0-9]?(,[0-9][0-9][0-9])+$/
}
/ERROR SUMMARY:/ {
    seen = 1
    if (NF != 12 || $1 !~ /^==[0-9]+==$/ || $2 != "ERROR" || $3 != "SUMMARY:" ||
        $5 != "errors" || $6 != "from" || $8 != "contexts" ||
        $9 != "(suppressed:" || $11 != "from" || $12 !~ /\)$/) {
        failed = 1
        next
    }
    suppressed_contexts = $12
    sub(/\)$/, "", suppressed_contexts)
    if (!count($4) || !count($7) || !count($10) || !count(suppressed_contexts)) {
        failed = 1
        next
    }
    errors = $4
    contexts = $7
    gsub(/,/, "", errors)
    gsub(/,/, "", contexts)
    if (errors + 0 != 0 || contexts + 0 != 0) failed = 1
}
END { exit(!seen || failed) }
