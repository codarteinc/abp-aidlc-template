#!/usr/bin/env bash
# lib/dotnet-overlay.sh — .NET project-structure overlay helpers.
#
# Sourced by scaffold.sh's `phase_apply_overlays` and by downstream units 04
# (observability) and 05 (security) that need to insert content into shared
# host files via the ScaffoldBlock marker protocol.
#
# Marker convention (per unit-03 spec §4.1):
#
#   C# (*.cs)               // <ScaffoldBlock name="X">
#                           // </ScaffoldBlock>
#
#   MSBuild (*.csproj)      <!-- <ScaffoldBlock name="X"> -->
#                           <!-- </ScaffoldBlock> -->
#
#   JSON (*.json)           "//scaffold-block-X-start": "",
#                           "//scaffold-block-X-end": "",
#                           (sentinel keys — strict JSON has no comments)
#
# Public API:
#   scaffold_insert_block <file> <block_name> <content_file>
#       Replace the body BETWEEN the named marker pair with the contents
#       of <content_file>. Idempotent on re-run. Fails loudly if the
#       marker pair is missing.
#
#   scaffold_assert_block_present <file> <block_name>
#       Exit 0 iff both the open and close markers for <block_name> are
#       present in <file>. Used by tests and as the idempotency gate in
#       merge_markers_into_existing.
#
#   merge_markers_into_existing <existing_file> <markers_file>
#       Apply a tiny ANCHOR/BLOCK DSL (see §4.3) to inject empty
#       ScaffoldBlock marker pairs into a file produced by `abp new`.
#       Idempotent.
#
#   dotnet_overlay_set_root_namespace <csproj_file> <namespace_value>
#       Insert or rewrite <RootNamespace> on a csproj. Idempotent.
#
#   dotnet_overlay_swap_automapper_for_mapperly <csproj_file>
#       Remove Volo.Abp.AutoMapper + AutoMapper PackageReferences and
#       ensure Volo.Abp.Mapperly + Riok.Mapperly.Abstractions are present.
#       Idempotent.
#
#   dotnet_overlay_add_dependson_attribute <cs_file> <module_class> <using_line>
#       Splice typeof(<module_class>) into the first [DependsOn(...)]
#       attribute and ensure <using_line> is present at the top of <cs_file>.
#       Idempotent.
#
#   dotnet_overlay_add_package_reference <csproj_file> <package_id> <version>
#       Add or update a PackageReference in a csproj. Idempotent.

if [[ -n "${__LH_DOTNET_OVERLAY_SH_SOURCED:-}" ]]; then
    return 0
fi
__LH_DOTNET_OVERLAY_SH_SOURCED=1

# Pull in log helpers if the caller hasn't already.
if [[ -z "${__LH_LOG_SH_SOURCED:-}" ]]; then
    # shellcheck source=lib/log.sh
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _marker_style_for <file> -> echoes "csharp" | "json" | "msbuild"
_marker_style_for() {
    local f="$1"
    case "$f" in
        *.cs)                              echo "csharp"  ;;
        *.csproj|*.props|*.targets)        echo "msbuild" ;;
        *.json)                            echo "json"    ;;
        *)
            log_fail "_marker_style_for: unknown marker style for: $f" \
                "_marker_style_for"
            return 1
            ;;
    esac
}

# _marker_open_pattern <style> <block_name>
_marker_open_pattern() {
    local style="$1" name="$2"
    case "$style" in
        csharp)  printf '// <ScaffoldBlock name="%s">' "$name" ;;
        msbuild) printf '<!-- <ScaffoldBlock name="%s"> -->' "$name" ;;
        json)    printf '"//scaffold-block-%s-start"' "$name" ;;
        *) return 1 ;;
    esac
}

# _marker_close_pattern <style>
# JSON close is name-specific (matches the START name) for correctness;
# in practice the helpers below pair OPEN/CLOSE by sequence so the close
# pattern doesn't include the name.
_marker_close_pattern() {
    local style="$1" name="${2:-}"
    case "$style" in
        csharp)  printf '// </ScaffoldBlock>' ;;
        msbuild) printf '<!-- </ScaffoldBlock> -->' ;;
        json)    printf '"//scaffold-block-%s-end"' "$name" ;;
        *) return 1 ;;
    esac
}

# _insert_empty_marker_pair <file> <anchor_regex> <block_name> <style> [after_brace=1]
#
# Inserts a marker pair immediately after the FIRST line matching the
# anchor regex. Preserves leading whitespace.
#
# When after_brace=1 (the default for csharp / msbuild styles), the
# insertion point is shifted FORWARD to the line AFTER the next line
# that's a brace-only line ("{") — so the marker lands INSIDE the body
# of the method/block that opens after the anchor. This handles Allman
# brace style ("public void M()\n{") which is what ABP CLI produces.
# If no brace-only line is encountered before EOF, falls back to the
# anchor-line insertion behaviour (used for JSON top-level "{" anchors).
_insert_empty_marker_pair() {
    local file="$1" anchor="$2" name="$3" style="$4"
    local after_brace=1
    case "$style" in
        json) after_brace=0 ;;
    esac
    local open close
    open=$(_marker_open_pattern "$style" "$name") || return 1
    close=$(_marker_close_pattern "$style" "$name") || return 1
    # For JSON, marker lines need the sentinel-key trailing comma + colon.
    local open_line close_line
    case "$style" in
        csharp)
            open_line="$open"
            close_line="$close"
            ;;
        msbuild)
            open_line="$open"
            close_line="$close"
            ;;
        json)
            open_line="${open}: \"\","
            close_line="${close}: \"\","
            ;;
    esac

    local tmp="${file}.scaffold-marker.tmp"
    awk -v anchor="$anchor" -v ol="$open_line" -v cl="$close_line" \
        -v after_brace="$after_brace" '
        BEGIN { state = 0; anchor_indent = "    " }
        # state 0 = looking for anchor
        # state 1 = anchor seen, waiting for next "{"-only line (after_brace=1)
        # state 2 = done; pass through
        {
            print
            if (state == 0 && $0 ~ anchor) {
                # Capture indent for marker emission.
                if (match($0, /^[ \t]+/)) {
                    anchor_indent = substr($0, RSTART, RLENGTH)
                }
                if (after_brace == 1) {
                    # Wait for the next brace-only line.
                    state = 1
                } else {
                    # Insert right after anchor (JSON path or compact).
                    printf "%s%s\n", anchor_indent, ol
                    printf "%s%s\n", anchor_indent, cl
                    state = 2
                }
                next
            }
            if (state == 1 && $0 ~ /^[[:space:]]*\{[[:space:]]*$/) {
                # Use the brace-line indent + 4 spaces for body markers.
                brace_indent = ""
                if (match($0, /^[ \t]+/)) {
                    brace_indent = substr($0, RSTART, RLENGTH)
                }
                body_indent = brace_indent "    "
                printf "%s%s\n", body_indent, ol
                printf "%s%s\n", body_indent, cl
                state = 2
                next
            }
        }
        END { if (state != 2) exit 2 }
    ' "$file" > "$tmp"
    local rc=$?
    if (( rc != 0 )); then
        rm -f "$tmp"
        log_fail "_insert_empty_marker_pair: anchor not found (or no brace after) in $file: $anchor" \
            "_insert_empty_marker_pair"
        return 1
    fi
    mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# scaffold_insert_block <file> <block_name> <content_file>
scaffold_insert_block() {
    local file="$1" name="$2" content_file="$3"
    if [[ ! -f "$file" ]]; then
        log_fail "scaffold_insert_block: missing file: $file" "scaffold_insert_block"
        return 1
    fi
    if [[ ! -f "$content_file" ]]; then
        log_fail "scaffold_insert_block: missing content: $content_file" \
            "scaffold_insert_block"
        return 1
    fi

    local style
    style=$(_marker_style_for "$file") || return 1

    local open close
    open=$(_marker_open_pattern "$style" "$name") || return 1
    close=$(_marker_close_pattern "$style" "$name") || return 1

    local tmp="${file}.scaffold-insert.tmp"
    awk -v op="$open" -v cp="$close" -v body_file="$content_file" '
        BEGIN { inside = 0; matched = 0 }
        {
            if (!inside && index($0, op) > 0) {
                print
                inside = 1
                matched = 1
                while ((getline line < body_file) > 0) print line
                close(body_file)
                next
            }
            if (inside && index($0, cp) > 0) {
                inside = 0
                print
                next
            }
            if (!inside) {
                print
            }
        }
        END { if (!matched) exit 2 }
    ' "$file" > "$tmp"
    local rc=$?
    if (( rc != 0 )); then
        rm -f "$tmp"
        log_fail "scaffold_insert_block: marker '${open}' not found in $file" \
            "scaffold_insert_block"
        return 1
    fi
    mv "$tmp" "$file"
}

# scaffold_assert_block_present <file> <block_name>
scaffold_assert_block_present() {
    local file="$1" name="$2"
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    local style
    style=$(_marker_style_for "$file" 2>/dev/null) || return 1
    local open close
    open=$(_marker_open_pattern "$style" "$name") || return 1
    close=$(_marker_close_pattern "$style" "$name") || return 1
    grep -qF -- "$open" "$file" || return 1
    grep -qF -- "$close" "$file" || return 1
    return 0
}

# merge_markers_into_existing <existing_file> <markers_file>
#
# Markers file DSL (per unit-03 spec §4.3):
#   # comment line
#   ANCHOR <regex>
#   BLOCK <block-name>
#   BLOCK <block-name>
#   ANCHOR <regex>
#   BLOCK <block-name>
#
# Each BLOCK is inserted as an empty marker pair immediately after the
# first line matching its preceding ANCHOR regex. If the marker pair is
# already present anywhere in the file, the BLOCK is silently skipped
# (idempotent).
merge_markers_into_existing() {
    local existing="$1" markers="$2"
    if [[ ! -f "$existing" ]]; then
        log_fail "merge_markers_into_existing: missing existing file: $existing" \
            "merge_markers_into_existing"
        return 1
    fi
    if [[ ! -f "$markers" ]]; then
        log_fail "merge_markers_into_existing: missing markers file: $markers" \
            "merge_markers_into_existing"
        return 1
    fi
    local style
    style=$(_marker_style_for "$existing") || return 1

    local current_anchor=""
    local line directive rest block_name
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blanks + comments.
        case "$line" in
            ''|'#'*) continue ;;
        esac
        directive="${line%% *}"
        rest="${line#"$directive"}"
        # Trim leading whitespace from rest.
        rest="${rest#"${rest%%[![:space:]]*}"}"
        case "$directive" in
            ANCHOR)
                current_anchor="$rest"
                # Verify anchor matches at least once in the existing file.
                if ! grep -qE -- "$current_anchor" "$existing"; then
                    log_fail "merge_markers_into_existing: anchor not found in $existing: $current_anchor" \
                        "merge_markers_into_existing"
                    return 1
                fi
                ;;
            BLOCK)
                block_name="$rest"
                if scaffold_assert_block_present "$existing" "$block_name"; then
                    # Already present — idempotent skip.
                    continue
                fi
                if [[ -z "$current_anchor" ]]; then
                    log_fail "merge_markers_into_existing: BLOCK '$block_name' without preceding ANCHOR" \
                        "merge_markers_into_existing"
                    return 1
                fi
                _insert_empty_marker_pair "$existing" "$current_anchor" \
                    "$block_name" "$style" || return 1
                ;;
            *)
                log_fail "merge_markers_into_existing: unrecognized directive: $line" \
                    "merge_markers_into_existing"
                return 1
                ;;
        esac
    done < "$markers"
}

# dotnet_overlay_set_root_namespace <csproj_file> <namespace_value>
dotnet_overlay_set_root_namespace() {
    local csproj="$1" ns="$2"
    if [[ ! -f "$csproj" ]]; then
        log_fail "dotnet_overlay_set_root_namespace: missing $csproj" \
            "dotnet_overlay_set_root_namespace"
        return 1
    fi
    # Fast-path: already correct.
    if grep -qE "<RootNamespace>${ns}</RootNamespace>" "$csproj"; then
        return 0
    fi
    # Rewrite-path: present with different value.
    if grep -q '<RootNamespace>' "$csproj"; then
        local rewrite_tmp="${csproj}.rootns.tmp"
        sed -E "s|<RootNamespace>[^<]*</RootNamespace>|<RootNamespace>${ns}</RootNamespace>|" \
            "$csproj" > "$rewrite_tmp"
        mv "$rewrite_tmp" "$csproj"
        return 0
    fi
    # Insert-path: inject just before </PropertyGroup> of the FIRST
    # <PropertyGroup> that contains a <TargetFramework>.
    local tmp="${csproj}.rootns.tmp"
    awk -v ns="$ns" '
        function capture_indent(line,    s) {
            # POSIX awk: 2-arg match() sets RSTART/RLENGTH.
            if (match(line, /^[ \t]+/)) {
                return substr(line, RSTART, RLENGTH)
            }
            return ""
        }
        BEGIN { in_pg = 0; pg_has_tf = 0; inserted = 0; buf = ""; last_indent = "    " }
        /<PropertyGroup>/ {
            if (in_pg) {
                # Nested PropertyGroup is rare; flush the previous buf.
                printf "%s", buf
            }
            in_pg = 1
            pg_has_tf = 0
            buf = $0 ORS
            next
        }
        in_pg && /<TargetFramework>/ {
            pg_has_tf = 1
            ind = capture_indent($0)
            if (ind != "") last_indent = ind
            buf = buf $0 ORS
            next
        }
        in_pg && /<\/PropertyGroup>/ {
            if (pg_has_tf && !inserted) {
                printf "%s", buf
                print last_indent "<RootNamespace>" ns "</RootNamespace>"
                inserted = 1
            } else {
                printf "%s", buf
            }
            print
            in_pg = 0
            buf = ""
            next
        }
        in_pg {
            ind = capture_indent($0)
            if (ind != "") last_indent = ind
            buf = buf $0 ORS
            next
        }
        { print }
        END {
            # Flush any unterminated buffer (malformed input).
            if (buf != "") printf "%s", buf
        }
    ' "$csproj" > "$tmp"
    if ! grep -q "<RootNamespace>${ns}</RootNamespace>" "$tmp"; then
        rm -f "$tmp"
        log_fail "dotnet_overlay_set_root_namespace: could not find <PropertyGroup> with <TargetFramework> in $csproj" \
            "dotnet_overlay_set_root_namespace"
        return 1
    fi
    mv "$tmp" "$csproj"
}

# dotnet_overlay_swap_automapper_for_mapperly <csproj_file>
#
# Removes Volo.Abp.AutoMapper + AutoMapper PackageReference lines and
# ensures Volo.Abp.Mapperly + Riok.Mapperly.Abstractions are present.
# Version pin for Volo.Abp.Mapperly comes from ${ABP_VERSION} (exported
# by phase_abp_new). Riok.Mapperly.Abstractions stays on a stable 4.* pin.
dotnet_overlay_swap_automapper_for_mapperly() {
    local csproj="$1"
    if [[ ! -f "$csproj" ]]; then
        log_fail "dotnet_overlay_swap_automapper_for_mapperly: missing $csproj" \
            "dotnet_overlay_swap_automapper_for_mapperly"
        return 1
    fi
    local abp_ver="${ABP_VERSION:-10.3.0}"
    local riok_ver="${RIOK_MAPPERLY_VERSION:-4.*}"

    local tmp="${csproj}.mapperly.tmp"
    # Strip any AutoMapper/Volo.Abp.AutoMapper PackageReference lines.
    # The trailing ORS-preserving filter keeps formatting; sed strips
    # any line whose entire trimmed body is the PackageReference.
    sed -E '/<PackageReference[[:space:]]+Include="(Volo\.Abp\.AutoMapper|AutoMapper)"[^>]*\/>/d' \
        "$csproj" > "$tmp"

    # Ensure Volo.Abp.Mapperly is present.
    if ! grep -qE 'Include="Volo\.Abp\.Mapperly"' "$tmp"; then
        _csproj_add_packageref "$tmp" "Volo.Abp.Mapperly" "$abp_ver" || {
            rm -f "$tmp"
            return 1
        }
    fi
    # Ensure Riok.Mapperly.Abstractions is present.
    if ! grep -qE 'Include="Riok\.Mapperly\.Abstractions"' "$tmp"; then
        _csproj_add_packageref "$tmp" "Riok.Mapperly.Abstractions" "$riok_ver" || {
            rm -f "$tmp"
            return 1
        }
    fi
    mv "$tmp" "$csproj"
}

# _csproj_add_packageref <csproj_file_inplace> <package_id> <version>
# Idempotent: skips if already present. Inserts into the first
# <ItemGroup> containing existing <PackageReference> elements; if no
# such item-group exists, creates one before the closing </Project>.
_csproj_add_packageref() {
    local csproj="$1" pkg="$2" ver="$3"
    if grep -qE "Include=\"${pkg}\"" "$csproj"; then
        # Already present — idempotent.
        return 0
    fi
    local tmp="${csproj}.pkgref.tmp"
    # Try to inject into the first ItemGroup with a PackageReference
    # already in it.
    awk -v pkg="$pkg" -v ver="$ver" '
        function capture_indent(line) {
            if (match(line, /^[ \t]+/)) {
                return substr(line, RSTART, RLENGTH)
            }
            return ""
        }
        BEGIN { in_ig = 0; has_pkg = 0; buf = ""; inserted = 0; last_pkg_indent = "    " }
        /<ItemGroup>/ && !inserted {
            if (in_ig) { printf "%s", buf }
            in_ig = 1
            has_pkg = 0
            buf = $0 ORS
            next
        }
        in_ig && /<PackageReference[[:space:]]/ {
            has_pkg = 1
            ind = capture_indent($0)
            if (ind != "") last_pkg_indent = ind
            buf = buf $0 ORS
            next
        }
        in_ig && /<\/ItemGroup>/ {
            if (has_pkg && !inserted) {
                printf "%s", buf
                print last_pkg_indent "<PackageReference Include=\"" pkg "\" Version=\"" ver "\" />"
                inserted = 1
            } else {
                printf "%s", buf
            }
            print
            in_ig = 0
            buf = ""
            next
        }
        in_ig {
            buf = buf $0 ORS
            next
        }
        { print }
        END {
            if (buf != "") printf "%s", buf
        }
    ' "$csproj" > "$tmp"

    if ! grep -qE "Include=\"${pkg}\"" "$tmp"; then
        # No suitable ItemGroup found — create one before </Project>.
        awk -v pkg="$pkg" -v ver="$ver" '
            BEGIN { inserted = 0 }
            /<\/Project>/ && !inserted {
                print ""
                print "  <ItemGroup>"
                print "    <PackageReference Include=\"" pkg "\" Version=\"" ver "\" />"
                print "  </ItemGroup>"
                inserted = 1
            }
            { print }
        ' "$csproj" > "$tmp"
        if ! grep -qE "Include=\"${pkg}\"" "$tmp"; then
            rm -f "$tmp"
            log_fail "_csproj_add_packageref: failed to insert $pkg into $csproj" \
                "_csproj_add_packageref"
            return 1
        fi
    fi
    mv "$tmp" "$csproj"
}

# dotnet_overlay_add_package_reference <csproj_file> <package_id> <version>
dotnet_overlay_add_package_reference() {
    local csproj="$1" pkg="$2" ver="$3"
    if [[ ! -f "$csproj" ]]; then
        log_fail "dotnet_overlay_add_package_reference: missing $csproj" \
            "dotnet_overlay_add_package_reference"
        return 1
    fi
    # If already present with the same version, no-op.
    if grep -qE "Include=\"${pkg}\"[^>]*Version=\"${ver//./\\.}\"" "$csproj"; then
        return 0
    fi
    # If present with a different version, rewrite.
    if grep -qE "Include=\"${pkg}\"" "$csproj"; then
        local tmp="${csproj}.pkgver.tmp"
        sed -E "s|(<PackageReference[[:space:]]+Include=\"${pkg//./\\.}\"[[:space:]]+Version=\")[^\"]*(\".*\/>)|\\1${ver}\\2|" \
            "$csproj" > "$tmp"
        mv "$tmp" "$csproj"
        return 0
    fi
    _csproj_add_packageref "$csproj" "$pkg" "$ver"
}

# dotnet_overlay_add_dependson_attribute <cs_file> <module_class> <using_line>
#
# Splices typeof(<module_class>) into the FIRST [DependsOn(...)]
# attribute on the AbpModule subclass and ensures <using_line> is present.
# Supports the multi-line LinkHub form:
#
#   [DependsOn(
#       typeof(LinkHubDomainModule),
#       ...
#   )]
#
# Also supports the inline single-line form.
dotnet_overlay_add_dependson_attribute() {
    local cs="$1" module_class="$2" using_line="$3"
    if [[ ! -f "$cs" ]]; then
        log_fail "dotnet_overlay_add_dependson_attribute: missing $cs" \
            "dotnet_overlay_add_dependson_attribute"
        return 1
    fi

    # Idempotency: typeof(<module>) already present anywhere in the file.
    if grep -qE "typeof\\(${module_class}\\)" "$cs"; then
        # Still ensure the using line is present.
        _ensure_using_line "$cs" "$using_line" || return 1
        return 0
    fi

    local tmp="${cs}.dependson.tmp"
    awk -v new_type="typeof(${module_class})" '
        BEGIN { found_open = 0; injected = 0 }
        {
            line = $0
            if (!injected && line ~ /\[DependsOn\(/) {
                # Found an opening [DependsOn( — handle two cases:
                # 1. Multi-line form: line ends with "(" — insert
                #    "    typeof(X)," on the very next line.
                # 2. Inline form: arguments on the same line — splice
                #    new_type "," after the "(".
                # We detect form by counting parens on the line. If
                # closing paren is on the SAME line, it is inline form.
                if (line ~ /\[DependsOn\([^)]*\)\]/) {
                    # Inline form. Insert at the FIRST opening paren.
                    sub(/\[DependsOn\(/, "[DependsOn(" new_type ", ", line)
                    print line
                    injected = 1
                    next
                } else {
                    # Multi-line opener; need indentation of the FIRST
                    # arg to follow convention.
                    print line
                    found_open = 1
                    next
                }
            }
            if (found_open && !injected) {
                # The first arg line determines our indent. Insert
                # new_type "," BEFORE the existing first arg.
                indent = ""
                if (match(line, /^[ \t]+/)) {
                    indent = substr(line, RSTART, RLENGTH)
                }
                print indent new_type ","
                injected = 1
                print line
                next
            }
            print line
        }
        END { if (!injected) exit 2 }
    ' "$cs" > "$tmp"
    local rc=$?
    if (( rc != 0 )); then
        rm -f "$tmp"
        log_fail "dotnet_overlay_add_dependson_attribute: no [DependsOn(...)] found in $cs" \
            "dotnet_overlay_add_dependson_attribute"
        return 1
    fi
    mv "$tmp" "$cs"

    _ensure_using_line "$cs" "$using_line" || return 1
}

# _ensure_using_line <cs_file> <using_line>
# Inserts <using_line> after the last existing `using ...;` line if not
# already present.
_ensure_using_line() {
    local cs="$1" using_line="$2"
    if [[ -z "$using_line" ]]; then
        return 0
    fi
    if grep -qxF "$using_line" "$cs"; then
        return 0
    fi
    local tmp="${cs}.using.tmp"
    awk -v new="$using_line" '
        BEGIN { inserted = 0; last_using = 0 }
        /^using[[:space:]]+[A-Za-z]/ {
            last_using = NR
        }
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                print lines[i]
                if (i == last_using && !inserted) {
                    print new
                    inserted = 1
                }
            }
            if (!inserted) {
                # No usings in file — prepend at top.
                print new
            }
        }
    ' "$cs" > "$tmp"
    mv "$tmp" "$cs"
}
