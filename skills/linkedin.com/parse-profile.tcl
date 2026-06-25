#!/usr/bin/env tclsh
# Parse a LinkedIn profile page HTML into a structured YAML record.
#
# Serialiser path (see SKILL.md): browser-serialiser linkedin.com/parse-profile <slug-or-url>
#   navigates to the profile, dumps the rendered DOM, and runs the identical
#   parser over the in-memory HTML.
# Direct path (legacy, file-fed): tclsh parse-profile.tcl <html-file> [profile-url-or-slug]
#
# LinkedIn's DOM uses randomised class names and lazy-mounts deep sections after
# load. The topcard parses from the main page; the deeper sections come from the
# dedicated details pages, which render the full lists. By default the serialiser
# path fetches them all and emits a coverage block stating which sections were
# actually read, so a caller never reads an unfetched field as fact. We extract:
#
#   1. name        — <title> is always "Name | LinkedIn"
#   2. urn         — urn:li:fsd_profile:ACoAA...  (the stable profile handle a
#                    later connection campaign keys on)
#   3. headline / location — best-effort from meta + topcard
#   4. current_company — the ongoing position's company, from the Experience
#                    details page (NOT guessed from the headline); null only when
#                    Experience was read and no role is ongoing
#   5. experience  — structured entries (title, company, start, end, current)
#                    from /details/experience/
#   6. skills      — from /details/skills/ ([] means read-and-empty, not unread)
#   7. about       — best-effort from the main page; About still lazy-mounts
#                    unreliably, so coverage marks it fetched / not_found
#   8. evidence_blocks — a capped list of cleaned visible-text fragments, kept so
#                    the verification step (and a human) can confirm identity
#   9. coverage    — per-section fetched / not_found / not_fetched
#
# The page carries several people's URNs (the signed-in viewer, "people also
# viewed"). The profile owner is the most-frequently-referenced URN, since the
# page is about them; this is how the owner is disambiguated from the rest.
#
# --quick keeps the read to a single navigation (topcard only) for rate-sensitive
# bulk runs, marking the deeper sections not_fetched rather than guessing them.
#
# Output is YAML on stdout. The caller redirects it to <slug>.yaml.

package require json

# ---- Unicode-width helpers (match Python's code-point semantics) -------------

# Code-point length matching Python's len(): Tcl 8.6 stores a non-BMP char as a
# surrogate pair (2 units), so subtract the high-surrogate count.
proc cp_length {s} {
    set n [string length $s]
    set hi [regexp -all {[\uD800-\uDBFF]} $s]
    return [expr {$n - $hi}]
}

# A list of the code points of $s, each as a single Tcl string (a non-BMP code
# point is returned as its surrogate pair, which is one printable character).
proc cp_list {s} {
    if {![regexp {[\uD800-\uDBFF]} $s]} {
        return [split $s ""]
    }
    set out {}
    set len [string length $s]
    for {set i 0} {$i < $len} {incr i} {
        set ch [string index $s $i]
        scan $ch %c code
        if {$code >= 0xD800 && $code <= 0xDBFF && $i+1 < $len} {
            append ch [string index $s [expr {$i+1}]]
            incr i
        }
        lappend out $ch
    }
    return $out
}

# First $n code points of $s.
proc cp_take {s n} {
    if {$n <= 0} { return "" }
    if {![regexp {[\uD800-\uDBFF]} $s]} {
        return [string range $s 0 [expr {$n-1}]]
    }
    return [join [lrange [cp_list $s] 0 [expr {$n-1}]] ""]
}

# ---- HTML helpers ------------------------------------------------------------

# Decode the HTML entities Python's html.unescape resolves for this DOM: named
# entities plus numeric decimal/hex.
proc html_unescape {s} {
    set s [string map {&lt; < &gt; > &quot; \" &#39; ' &apos; ' &nbsp; " "} $s]
    while {[regexp {&#(\d+);} $s -> num]} {
        set ch [format %c $num]
        regsub -all "&#$num;" $s $ch s
    }
    while {[regexp -nocase {&#x([0-9a-f]+);} $s -> hx]} {
        scan $hx %x code
        set ch [format %c $code]
        regsub -all -nocase "&#x$hx;" $s $ch s
    }
    set s [string map {&amp; &} $s]
    return $s
}

# Quote a string for use as a literal inside a Tcl ARE (mirrors re.escape).
proc re_escape {s} {
    return [regsub -all {[][\\^$.|?*+(){}]} $s {\\&}]
}

# Remove the signed-in viewer's own profile data from the page. Used only for
# visible-text extraction. Tcl notes: the ARE word boundary is \y; and .*?</tag>
# is matched tempered-greedy so Tcl's leftmost-longest rule stops at the first
# close, reproducing Python's non-greedy .*?.
proc strip_viewer_content {html} {
    regsub -all {(?i)<nav\y[^>]*>(?:(?!</nav>)(?:.|\n))*</nav>} $html {} html
    regsub -all {(?i)<aside\y[^>]*>(?:(?!</aside>)(?:.|\n))*</aside>} $html {} html
    foreach marker {
        "People also viewed"
        "People you may know"
        "You might also know"
        "Explore collaborative articles"
        "Add profile section"
        "More profiles for you"
        "Seleccionar idioma"
        "Select Language"
        "Más información sobre el contenido recomendado"
        "Learn more about recommended content"
    } {
        set idx [string first $marker $html]
        if {$idx > 5000} {
            set html [string range $html 0 [expr {$idx-1}]]
            break
        }
    }
    return $html
}

# Derive the vanity slug from a profile URL or a bare slug argument.
proc slug_from_arg {arg} {
    if {$arg eq ""} { return "" }
    if {[regexp {/in/([^/?#]+)} $arg -> m]} { return $m }
    return [string trim [string trim $arg] /]
}

# Fallback: recover the slug from a componentkey when no arg is passed.
proc slug_from_dom {html} {
    if {[regexp {(?:ProfilePostConnectDrawer|profile_education_top_anchor_)([a-z0-9-]+)} $html -> m]} {
        return $m
    }
    return ""
}

# The owner's fsd_profile URN, or "". The canonical id is a fixed 39-char token
# (ACoAA + 34); truncating every match to 39 chars collapses the suffixed
# component-key variants onto it, so the owner dominates the count.
proc owner_urn {html} {
    set tokens [regexp -all -inline {ACoAA[A-Za-z0-9_-]+} $html]
    if {![llength $tokens]} { return "" }
    # Counter.most_common(1): the most frequent 39-char prefix, ties broken by
    # first-seen insertion order (Python Counter preserves that).
    set counts [dict create]
    set order {}
    foreach tok $tokens {
        set base [string range $tok 0 38]
        if {![dict exists $counts $base]} {
            dict set counts $base 0
            lappend order $base
        }
        dict incr counts $base
    }
    set best ""
    set bestn -1
    foreach base $order {
        set n [dict get $counts $base]
        if {$n > $bestn} { set bestn $n; set best $base }
    }
    return "urn:li:fsd_profile:$best"
}

# Read a <meta> value, tolerating either attribute order.
proc meta_content {html tag} {
    set t [re_escape $tag]
    set patterns [list \
        "<meta\[^>\]*(?:name|property)=\"$t\"\[^>\]*content=\"(\[^\"\]*)\"" \
        "<meta\[^>\]*content=\"(\[^\"\]*)\"\[^>\]*(?:name|property)=\"$t\""]
    foreach p $patterns {
        if {[regexp $p $html -> m]} {
            if {$m eq ""} { return "" }
            return [html_unescape $m]
        }
    }
    return ""
}

set ::UI_NOISE [list \
    "notificaci" "Enviar mensaje" "Información de contacto" "seguidores" \
    "contactos en común" "LinkedIn Corporation" "Centro de ayuda" \
    "Configuración" "Pasar a" "Ir al contenido" "Skip to" "Más de" \
    "recomendaciones" "preguntas" "privacidad" "contact info" "followers" \
    "la búsqueda" "al margen" "pie de página" "Notifications" "Mensaje" \
    "Acceso" "Únete ahora" "Iniciar sesión" "mutual connection"]

set ::ROLE_KW [list \
    " at " "Director" "Manager" "CEO" "Founder" "Chairman" "Partner" \
    "Consultant" "Engineer" "Analyst" "President" "Owner" "Principal" \
    "Coordinator" "Officer" "Specialist" "Lead" "Head of" "Executive" \
    "Influencer" "Creator" "Coach" "Celebrant" "Photographer" "Planner" \
    "Adviser" "Advisor" "Agent" "Producer" "Editor" "Journalist" \
    "Teacher" "Chef" "Designer" "Speaker" "Stylist" "Therapist"]

set ::NOISE_PAT {^\s*\{|^\s*\.|^\s*var |^\s*function|width:|padding|margin:|font-|display:|background|border|position:|overflow|opacity|color:|transform|transition|animation|z-index|box-shadow|text-decoration|line-height|letter-spacing|white-space|flex|grid|align-|justify-|cursor:|visibility|pointer-events|componentkey|data-display|tabindex|aria-|\.video-js|vjs-|_[0-9a-f]{8}}

set ::PLACE_PAT {(?i)\y(Australia|Queensland|New South Wales|Victoria|Tasmania|Western Australia|South Australia|Northern Territory|Brisbane|Sydney|Melbourne|Perth|Adelaide|Canberra|Hobart|Darwin|Gold Coast|Sunshine Coast|Cairns|Townsville|Toowoomba|United States|United Kingdom|England|Scotland|Wales|Ireland|Singapore|New Zealand|Canada|Saudi|Arabia|Emirates|Dubai|France|Germany|Italy|Spain|Netherlands|India|Japan|China|Hong Kong|Philippines|Indonesia|Malaysia|Reino Unido|Inglaterra|Escocia|Gales|Irlanda|Estados Unidos|Alemania|Francia|España|Italia|Singapur|Nueva Zelanda|Canadá|Japón|Países Bajos|Arabia Saudí|Emiratos|Filipinas|Malasia|Indonesia|Reino|Suiza|Bélgica|Suecia)\y}

# Extract visible text fragments from the obfuscated DOM, filtering noise.
proc extract_visible_texts {html} {
    global UI_NOISE NOISE_PAT
    # Python: re.findall(r">([^<]{10,500})<", html). Tcl ARE caps a bounded
    # repetition at 255, so match >run< and gate the raw run length 10-500.
    set raw [regexp -all -inline {>([^<]+)<} $html]
    set filtered {}
    set seen [dict create]
    foreach {full text} $raw {
        set rl [cp_length $text]
        if {$rl < 10 || $rl > 500} { continue }
        set text [html_unescape [string trim $text]]
        if {$text eq "" || [dict exists $seen $text]} { continue }
        if {[regexp $NOISE_PAT $text]} { continue }
        set isnoise 0
        foreach n $UI_NOISE {
            if {[string first $n $text] >= 0} { set isnoise 1; break }
        }
        if {$isnoise} { continue }
        dict set seen $text 1
        lappend filtered $text
    }
    return $filtered
}

# The headline is the first content block after the name that names a role or
# uses a credential separator. UI chrome and the name/title lines are skipped.
proc infer_headline {texts name} {
    global UI_NOISE ROLE_KW
    foreach t $texts {
        if {$t eq $name || [string first "| LinkedIn" $t] >= 0 || [cp_length $t] < 12} {
            continue
        }
        set isnoise 0
        foreach n $UI_NOISE {
            if {[string first $n $t] >= 0} { set isnoise 1; break }
        }
        if {$isnoise} { continue }
        set hit 0
        foreach kw $ROLE_KW {
            if {[string first $kw $t] >= 0} { set hit 1; break }
        }
        if {$hit || [string first " | " $t] >= 0} { return $t }
    }
    return ""
}

# Pick the first short block that names a known place.
proc infer_location {texts name} {
    global PLACE_PAT
    foreach t $texts {
        if {[cp_length $t] < 80 && $t ne $name && \
            [string first "| LinkedIn" $t] < 0 && [regexp $PLACE_PAT $t]} {
            return $t
        }
    }
    return ""
}

# Split $s at the first occurrence of $sep into a two-element list {before after}.
proc split_once {s sep} {
    set idx [string first $sep $s]
    if {$idx < 0} { return [list $s ""] }
    set before [string range $s 0 [expr {$idx-1}]]
    set after [string range $s [expr {$idx + [string length $sep]}] end]
    return [list $before $after]
}

# ---- PyYAML-faithful scalar emitter ------------------------------------------
#
# safe_dump's block emitter chooses a style per scalar (plain / single-quoted /
# double-quoted) by analyzing it, then writes it. For the short single-line
# scalars in this record (width=1000 so no folding triggers), the port below
# reproduces yaml.safe_dump(... allow_unicode=True) byte-for-byte.

# Analyze a scalar and return one of: plain single double.
# Mirrors yaml.emitter.Emitter.analyze_scalar + choose_scalar_style for the
# block-context, allow_unicode=True case.
proc yaml_style {scalar} {
    if {$scalar eq ""} { return single }

    set chars [cp_list $scalar]
    set n [llength $chars]

    set block_indicators 0
    set flow_indicators 0
    set line_breaks 0
    set special_characters 0
    set leading_space 0
    set leading_break 0
    set trailing_space 0
    set trailing_break 0
    set break_space 0
    set space_break 0

    # Leading-indicator analysis (first char).
    set first [lindex $chars 0]
    if {$first in {# , \[ \] \{ \} & * ! | > ' \" % @ `}} {
        set flow_indicators 1
        set block_indicators 1
    }
    if {$first in {? :}} {
        set flow_indicators 1
        if {$n == 1 || [yaml_is_space_or_break [lindex $chars 1]]} {
            set block_indicators 1
        }
    }
    if {$first eq "-" && ($n == 1 || [yaml_is_space_or_break [lindex $chars 1]])} {
        set flow_indicators 1
        set block_indicators 1
    }
    # A leading "---" or "..." (document markers) forces quoting.
    if {[cp_take $scalar 3] in {--- ...}} {
        set flow_indicators 1
        set block_indicators 1
    }

    set preceded_by_whitespace 1
    set followed_by_whitespace [expr {$n == 1 || [yaml_is_space_or_break [lindex $chars 1]]}]
    set previous_space 0
    set previous_break 0

    for {set i 0} {$i < $n} {incr i} {
        set ch [lindex $chars $i]

        if {$i > 0} {
            # General indicators.
            if {$ch in {, ? \[ \] \{ \}}} { set flow_indicators 1 }
            if {$ch eq ":"} {
                set flow_indicators 1
                if {$followed_by_whitespace} { set block_indicators 1 }
            }
            if {$ch eq "#" && $preceded_by_whitespace} {
                set flow_indicators 1
                set block_indicators 1
            }
        } else {
            # Already handled above for leading char's flow/block, but ':' and
            # '#' general rules also apply at position 0 in PyYAML's loop.
            if {$ch eq ":"} {
                if {$followed_by_whitespace} { set block_indicators 1 }
            }
        }

        # Line breaks: PyYAML's analyzer break set is LF, NEL, LS, PS (not CR).
        if {[yaml_is_break $ch]} {
            set line_breaks 1
        }
        # Special characters force quoting. With allow_unicode=True a char is
        # special unless it is LF, printable ASCII, or in the allowed Unicode set
        # (NEL, the BMP printable ranges, the astral plane), excluding the BOM.
        # So CR and TAB are special; emoji and CJK are not.
        if {[yaml_is_special_char $ch]} {
            set special_characters 1
        }

        # Spaces / breaks adjacency.
        if {$ch eq " "} {
            if {$i == 0} { set leading_space 1 }
            if {$i == $n-1} { set trailing_space 1 }
            if {$previous_break} { set break_space 1 }
            set previous_space 1
            set previous_break 0
        } elseif {[yaml_is_break $ch]} {
            if {$i == 0} { set leading_break 1 }
            if {$i == $n-1} { set trailing_break 1 }
            if {$previous_space} { set space_break 1 }
            set previous_space 0
            set previous_break 1
        } else {
            set previous_space 0
            set previous_break 0
        }

        # Look-ahead bookkeeping for the next iteration.
        set preceded_by_whitespace [yaml_is_space_break_z $ch]
        if {$i+2 <= $n-1} {
            set followed_by_whitespace [yaml_is_space_or_break [lindex $chars [expr {$i+2}]]]
        } else {
            set followed_by_whitespace 1
        }
    }

    # Decide styles (block context).
    set allow_flow_plain 1
    set allow_block_plain 1
    set allow_single_quoted 1
    set allow_double_quoted 1
    set allow_block 1

    if {$leading_space || $leading_break || $trailing_space || $trailing_break} {
        set allow_flow_plain 0
        set allow_block_plain 0
    }
    if {$trailing_space} {
        set allow_block 0
    }
    if {$break_space} {
        set allow_flow_plain 0
        set allow_block_plain 0
        set allow_single_quoted 0
    }
    if {$space_break || $special_characters} {
        set allow_flow_plain 0
        set allow_block_plain 0
        set allow_single_quoted 0
        set allow_block 0
    }
    if {$line_breaks} {
        set allow_flow_plain 0
        set allow_block_plain 0
    }
    if {$flow_indicators} { set allow_flow_plain 0 }
    if {$block_indicators} { set allow_block_plain 0 }

    # choose_scalar_style (no anchor/tag; block context => use block_plain).
    if {$allow_block_plain && ![yaml_plain_is_ambiguous $scalar]} {
        return plain
    }
    if {$allow_single_quoted} { return single }
    return double
}

# A plain scalar that would resolve to a non-string (null/bool/int/float/etc.)
# or collide with YAML reserved tokens must be quoted. PyYAML's resolver does
# this; we approximate the implicit resolvers the default SafeDumper installs.
proc yaml_plain_is_ambiguous {scalar} {
    # Empty already handled by caller. PyYAML quotes the empty-tag and these.
    set s $scalar
    # bool
    if {[regexp {^(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)$} $s]} {
        return 1
    }
    # null
    if {[regexp {^(?:~|null|Null|NULL|)$} $s]} { return 1 }
    # int — PyYAML SafeLoader resolver (decimal/binary/octal/hex/sexagesimal,
    # underscores allowed within the digit run).
    if {[regexp {^[-+]?0b[0-1_]+$} $s]} { return 1 }
    if {[regexp {^[-+]?0[0-7_]+$} $s]} { return 1 }
    if {[regexp {^[-+]?0x[0-9a-fA-F_]+$} $s]} { return 1 }
    if {[regexp {^[-+]?(?:0|[1-9][0-9_]*)$} $s]} { return 1 }
    if {[regexp {^[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+$} $s]} { return 1 }
    # float — PyYAML resolver: the exponent's sign is mandatory, so 1e10 stays
    # a plain string while 1.0 / .5 / 1.5e+10 / .inf / .nan resolve to float.
    if {[regexp {^[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?$} $s]} { return 1 }
    if {[regexp {^\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?$} $s]} { return 1 }
    if {[regexp {^[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*$} $s]} { return 1 }
    if {[regexp {^[-+]?\.(?:inf|Inf|INF)$} $s]} { return 1 }
    if {[regexp {^\.(?:nan|NaN|NAN)$} $s]} { return 1 }
    # timestamp (a leading digit run with - or : likely; PyYAML's timestamp
    # resolver). The evidence text never matches these, but cover the common
    # date form to stay faithful.
    if {[regexp {^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$} $s]} { return 1 }
    # value/merge indicators
    if {[regexp {^(?:=|<<)$} $s]} { return 1 }
    return 0
}

# PyYAML's analyzer line-break set: LF, NEL, LS, PS (CR is not a break).
proc yaml_is_break {ch} {
    return [expr {$ch in [list "\n" "\x85" " " " "]}]
}

# A "special character" per analyze_scalar (allow_unicode=True): anything
# that is not LF, not printable ASCII, and not in the allowed Unicode set
# (NEL, BMP printable ranges, astral plane), the BOM excluded. CR and TAB
# qualify and thus force double-quoting.
proc yaml_is_special_char {ch} {
    set code [cp_ord $ch]
    if {$code == 0x0A} { return 0 }
    if {$code >= 0x20 && $code <= 0x7E} { return 0 }
    if {$code == 0xFEFF} { return 1 }
    if {$code == 0x85} { return 0 }
    if {$code >= 0xA0 && $code <= 0xD7FF} { return 0 }
    if {$code >= 0xE000 && $code <= 0xFFFD} { return 0 }
    if {$code >= 0x10000 && $code <= 0x10FFFE} { return 0 }
    return 1
}
proc yaml_is_space_or_break {ch} {
    return [expr {$ch eq " " || [yaml_is_break $ch]}]
}
proc yaml_is_space_break_z {ch} {
    # space, break, or end (we pass real chars only; end handled by callers).
    return [yaml_is_space_or_break $ch]
}

# The Unicode code point of a one-character string. cp_list yields a non-BMP
# code point as its surrogate pair (two units); reassemble the scalar value so
# astral characters are recognised rather than read as a lone high surrogate.
proc cp_ord {ch} {
    if {[string length $ch] == 2} {
        scan [string index $ch 0] %c hi
        scan [string index $ch 1] %c lo
        if {$hi >= 0xD800 && $hi <= 0xDBFF && $lo >= 0xDC00 && $lo <= 0xDFFF} {
            return [expr {0x10000 + (($hi - 0xD800) << 10) + ($lo - 0xDC00)}]
        }
    }
    scan $ch %c code
    return $code
}

# Printable per PyYAML's allow_unicode=True set: \t \n \r \x85, the BMP
# printable ranges, and the astral plane, excluding the control/separators.
proc yaml_is_printable_unicode {ch} {
    set code [cp_ord $ch]
    if {$code == 0x09 || $code == 0x0A || $code == 0x0D || $code == 0x85} { return 1 }
    if {$code >= 0x20 && $code <= 0x7E} { return 1 }
    if {$code >= 0xA0 && $code <= 0xD7FF} { return 1 }
    if {$code >= 0xE000 && $code <= 0xFFFD && $code != 0xFEFF} { return 1 }
    if {$code >= 0x10000 && $code <= 0x10FFFF} { return 1 }
    return 0
}

# Write a plain scalar (no transformation needed for our single-line case).
proc yaml_write_plain {scalar} { return $scalar }

# Write a single-quoted scalar. Single quotes double; line breaks fold the
# PyYAML way — a run of N breaks emits N+1 newlines then the block indent, so a
# lone \n becomes "\n\n<indent>". With width=1000 no column folding triggers, so
# spaces pass through untouched. $indent is the continuation indent (2 spaces
# for a top-level block sequence item).
proc yaml_write_single {scalar {indent "  "}} {
    # PyYAML's single-quote break set is LF, NEL, LS, PS (CR is not a break).
    if {![regexp {[\n\x85  ]} $scalar]} {
        return "'[string map {' ''} $scalar]'"
    }
    set out "'"
    set chars [cp_list $scalar]
    set n [llength $chars]
    set i 0
    while {$i < $n} {
        set ch [lindex $chars $i]
        if {[yaml_char_is_break $ch]} {
            # Consume the whole break run.
            set run {}
            while {$i < $n && [yaml_char_is_break [lindex $chars $i]]} {
                lappend run [lindex $chars $i]
                incr i
            }
            # PyYAML: a leading LF emits one extra LF; then each break char is
            # emitted literally (LF as LF, NEL/LS/PS as themselves); then the
            # continuation indent.
            if {[lindex $run 0] eq "\n"} { append out "\n" }
            foreach br $run { append out $br }
            append out $indent
        } else {
            if {$ch eq "'"} { append out "''" } else { append out $ch }
            incr i
        }
    }
    append out "'"
    return $out
}

# A single-quote fold break: LF, NEL, LS, PS (not CR, not space).
proc yaml_char_is_break {ch} {
    return [expr {$ch in [list "\n" "\x85" " " " "]}]
}

# Forced-escape set in a double-quoted scalar (write_double_quoted): these are
# always escaped even though some are otherwise BMP-printable.
proc yaml_dq_forced {code} {
    return [expr {$code == 0x22 || $code == 0x5C || $code == 0x85 || \
                  $code == 0x2028 || $code == 0x2029 || $code == 0xFEFF}]
}

# Whether a char is kept raw (unescaped) in a double-quoted scalar: printable
# ASCII or, with allow_unicode, a BMP-printable code point. Astral and control
# code points are not kept raw (PyYAML escapes them by size).
proc yaml_dq_keep_raw {code} {
    if {[yaml_dq_forced $code]} { return 0 }
    if {$code >= 0x20 && $code <= 0x7E} { return 1 }
    if {$code >= 0xA0 && $code <= 0xD7FF} { return 1 }
    if {$code >= 0xE000 && $code <= 0xFFFD} { return 1 }
    return 0
}

# PyYAML's named escape replacements (\0 \a \b ... \N \_ \L \P).
set ::DQ_ESCAPE [dict create \
    0 {\0} 7 {\a} 8 {\b} 9 {\t} 10 {\n} 11 {\v} 12 {\f} 13 {\r} 27 {\e} \
    34 {\"} 92 {\\} 133 {\N} 160 {\_} 8232 {\L} 8233 {\P}]

# Write a double-quoted scalar. A char is emitted raw when kept-raw; otherwise
# it is escaped — via the named table when present, else by code-point size.
proc yaml_write_double {scalar} {
    global DQ_ESCAPE
    set out "\""
    foreach ch [cp_list $scalar] {
        set code [cp_ord $ch]
        if {[yaml_dq_keep_raw $code]} {
            append out $ch
        } elseif {[dict exists $DQ_ESCAPE $code]} {
            append out [dict get $DQ_ESCAPE $code]
        } elseif {$code <= 0xFF} {
            append out [format {\x%02X} $code]
        } elseif {$code <= 0xFFFF} {
            append out [format {\u%04X} $code]
        } else {
            append out [format {\U%08X} $code]
        }
    }
    append out "\""
    return $out
}

# Render a scalar value in the chosen style.
proc yaml_scalar {scalar} {
    switch -- [yaml_style $scalar] {
        plain  { return [yaml_write_plain $scalar] }
        single { return [yaml_write_single $scalar] }
        double { return [yaml_write_double $scalar] }
    }
}

# Render a top-level key: value line. value "" (our None sentinel handled by
# caller passing the literal "null").
proc yaml_kv {key rendered} {
    return "$key: $rendered"
}

# ---- Record assembly ---------------------------------------------------------

# Render the YAML record from an HTML string and the url/slug argument, returning
# the YAML text (byte-identical to the predecessor's stdout). A login/expired page
# returns the single sentinel "@@LOGIN@@" so each caller maps it to its own exit/
# terminal handling.
proc render_profile {html url_arg} {
    set title ""
    if {[regexp {(?s)<title[^>]*>(.*?)</title>} $html -> t]} {
        set title [string trim $t]
    }
    set tl [string tolower $title]
    foreach bad {"sign in" "log in" "iniciar" "registrarse"} {
        if {[string first $bad $tl] >= 0} {
            return "@@LOGIN@@"
        }
    }

    if {[string first "| LinkedIn" $title] >= 0} {
        set name [string trim [string map {" | LinkedIn" ""} $title]]
    } else {
        set name $title
    }

    set fsd_urn [owner_urn $html]

    set slug [slug_from_arg $url_arg]
    if {$slug eq ""} { set slug [slug_from_dom $html] }
    if {$url_arg ne "" && [string match "http*" $url_arg]} {
        set profile_url $url_arg
    } elseif {$slug ne ""} {
        set profile_url "https://www.linkedin.com/in/$slug/"
    } else {
        set profile_url ""
    }

    set texts [extract_visible_texts [strip_viewer_content $html]]
    set og_desc [meta_content $html "og:description"]
    if {$og_desc eq ""} { set og_desc [meta_content $html "description"] }
    set headline [infer_headline $texts $name]

    # meta_description: og_desc[:500] if present else None.
    if {$og_desc ne ""} {
        set meta_description [cp_take $og_desc 500]
    } else {
        set meta_description ""
    }
    set location [infer_location $texts $name]

    # evidence_blocks: texts[:15].
    set evidence [lrange $texts 0 14]

    # Emit the header fields. current_company is intentionally NOT emitted here:
    # it is only honest once the Experience source is read (the headline rarely
    # carries " at "), so the caller computes and appends it (or marks it
    # not_fetched) alongside the coverage block. See serialiser_run.
    set lines {}
    lappend lines [yaml_kv slug [emit_or_null $slug]]
    lappend lines [yaml_kv profile_url [emit_or_null $profile_url]]
    lappend lines [yaml_kv urn [emit_or_null $fsd_urn]]
    lappend lines [yaml_kv name [emit_or_null $name]]
    lappend lines [yaml_kv headline [emit_or_null $headline]]
    lappend lines [yaml_kv meta_description [emit_or_null $meta_description]]
    lappend lines [yaml_kv location [emit_or_null $location]]
    if {![llength $evidence]} {
        lappend lines "evidence_blocks: \[\]"
    } else {
        lappend lines "evidence_blocks:"
        foreach e $evidence {
            lappend lines "- [yaml_scalar $e]"
        }
    }
    return [join $lines "\n"]
}

# Direct path: read the file and print the record, exiting 1 on a login page.
proc parse_profile {html_path url_arg} {
    set f [open $html_path r]
    fconfigure $f -encoding utf-8
    set html [read $f]
    close $f

    set record [render_profile $html $url_arg]
    if {$record eq "@@LOGIN@@"} {
        puts stderr "ERROR: LinkedIn session expired. Log in via a Chrome-compatible browser first."
        exit 1
    }
    # A file is just the main page: Experience/Skills are not in it, so be honest
    # rather than emit current_company as a confident value.
    append record "\ncurrent_company: not_fetched"
    append record "\n[render_coverage [dict create topcard fetched \
        experience not_fetched skills not_fetched about not_fetched]]"
    puts $record
}

# ---------------------------------------------------------------------------
# Serialiser entry: navigate to the profile, dump the rendered DOM, and run the
# identical render over the in-memory HTML (no file read; Plane 1 removes file
# access). Emits the same YAML record.
#
#     browser-serialiser linkedin.com/parse-profile <slug-or-url>
# ---------------------------------------------------------------------------
# The Experience section is lazy-mounted below the fold and so never reaches the
# header record's evidence_blocks (texts[:15] off the top of the page). The
# dedicated details page carries the full position list; this extracts its visible
# text (employers, titles, dates) reusing the header parser's noise filtering,
# deduped and capped.
proc extract_experience_texts {html} {
    set texts [extract_visible_texts [strip_viewer_content $html]]
    set out {}
    foreach t $texts {
        # Stop at the page footer / language switcher that follows the positions.
        if {[string match "Questions?*" $t] || $t eq "Visit our Help Center." \
            || [string match "Select language*" $t] || [string match "Manage your account*" $t]} {
            break
        }
        lappend out $t
        if {[llength $out] >= 60} { break }
    }
    return $out
}

# ---- Structured extraction from the details pages ----------------------------
# A LinkedIn date-range fragment, e.g. "Dec 2017 - May 2023 · 5 yrs 6 mos" or
# "Jun 2023 - Present · 3 yrs 1 mo" or a year-only "2004 - 2013". The duration
# tail (after " · ") is optional.
proc is_date_range {t} {
    return [regexp {^(?:[A-Z][a-z]{2} )?[0-9]{4} - (?:Present|(?:[A-Z][a-z]{2} )?[0-9]{4})} $t]
}

# Split a date-range fragment into {start end current}. current is 1 when the
# role is ongoing ("Present").
proc parse_date_range {t} {
    set core [string trim [lindex [split $t "·"] 0]]
    set parts [split_once $core " - "]
    set start [string trim [lindex $parts 0]]
    set end [string trim [lindex $parts 1]]
    return [list $start $end [expr {$end eq "Present" ? 1 : 0}]]
}

# A fragment that can be a role title or company name: short, not a date range,
# not a location, not the section header, not a long description blurb.
proc name_like {t} {
    global PLACE_PAT
    if {[cp_length $t] > 100} { return 0 }
    if {[is_date_range $t]} { return 0 }
    if {$t eq "Experience"} { return 0 }
    if {[regexp $PLACE_PAT $t]} { return 0 }
    return 1
}

# Parse the experience fragment list into entries. Each date-range fragment
# anchors a position: the fragment just before it is the company line (split on
# " · " into company + employment type), and the one before that is the title
# when it is name-like. Positional, since the details page renders title,
# company, and dates as separate adjacent text runs.
proc parse_experience_entries {fragments} {
    set start_i 0
    for {set i 0} {$i < [llength $fragments]} {incr i} {
        if {[lindex $fragments $i] eq "Experience"} { set start_i [expr {$i+1}]; break }
    }
    set entries {}
    for {set i $start_i} {$i < [llength $fragments]} {incr i} {
        set t [lindex $fragments $i]
        if {![is_date_range $t]} { continue }
        lassign [parse_date_range $t] start end current
        set company ""; set etype ""; set title ""
        if {$i-1 >= $start_i} {
            set cp [split [lindex $fragments [expr {$i-1}]] "·"]
            set company [string trim [lindex $cp 0]]
            if {[llength $cp] > 1} { set etype [string trim [lindex $cp 1]] }
        }
        if {$i-2 >= $start_i} {
            set prev2 [lindex $fragments [expr {$i-2}]]
            if {[name_like $prev2]} { set title $prev2 }
        }
        lappend entries [dict create title $title company $company \
            employment_type $etype start $start end $end current $current]
    }
    return $entries
}

# The company of the current (ongoing) position, or "" if none is ongoing. Only
# meaningful once the experience source was actually read.
proc current_company_from_entries {entries} {
    foreach e $entries {
        if {[dict get $e current]} { return [dict get $e company] }
    }
    return ""
}

# Render experience entries as a YAML list of mappings.
proc render_experience_entries {entries} {
    if {![llength $entries]} { return "experience: \[\]" }
    set lines {experience:}
    foreach e $entries {
        set first 1
        foreach k {title company employment_type start end current} {
            set v [dict get $e $k]
            if {$k eq "current"} {
                set rv [expr {$v ? "true" : "false"}]
            } else {
                if {$v eq ""} { continue }
                set rv [yaml_scalar $v]
            }
            if {$first} { lappend lines "- $k: $rv"; set first 0 } \
            else        { lappend lines "  $k: $rv" }
        }
    }
    return [join $lines "\n"]
}

# Extract the skills list from the skills details page. Returns a list of skill
# names; an empty list means the page was read and carried no skills (its
# "add your skills" empty state), which is a real finding, not a failure. $name
# is the profile owner's name, filtered out as header chrome.
#
# Correctness over completeness: this page interleaves header/empty-state chrome
# with content, so anything chrome-like is dropped rather than emitted as a skill
# (emitting chrome as a skill is the false-data failure this whole change fixes).
proc extract_skills {html name} {
    set texts [extract_visible_texts [strip_viewer_content $html]]
    # Empty state: the profile lists no skills.
    foreach t $texts {
        if {[regexp -nocase {when you add new skills|showcase your skills|add your skills} $t]} {
            return {}
        }
    }
    set start_i 0
    for {set i 0} {$i < [llength $texts]} {incr i} {
        if {[lindex $texts $i] eq "Skills"} { set start_i [expr {$i+1}]; break }
    }
    set out {}
    set seen [dict create]
    for {set i $start_i} {$i < [llength $texts]} {incr i} {
        set t [lindex $texts $i]
        if {[string match "Questions?*" $t] || $t eq "Visit our Help Center." \
            || [string match "Select language*" $t] || [string match "Manage your account*" $t]} {
            break
        }
        if {$t eq $name || [string first "| LinkedIn" $t] >= 0} { continue }
        if {[cp_length $t] > 60} { continue }
        if {[regexp -nocase {endorsement|passed linkedin|assessment|notification|enhance profile|add section|add skills|edit|^show } $t]} { continue }
        if {[is_date_range $t]} { continue }
        if {[dict exists $seen $t]} { continue }
        dict set seen $t 1
        lappend out $t
        if {[llength $out] >= 50} { break }
    }
    return $out
}

proc render_skills_block {skills} {
    if {![llength $skills]} { return "skills: \[\]" }
    set lines {skills:}
    foreach s $skills { lappend lines "- [yaml_scalar $s]" }
    return [join $lines "\n"]
}

# Best-effort full About text from the main page: the substantial block right
# after an "About" header fragment. Returns "" when not located. Runs on the
# unstripped HTML: on the owner's own profile, strip_viewer_content cuts at the
# "Add profile section" chrome, which sits above About and would remove it.
proc extract_about {html} {
    set texts [extract_visible_texts $html]
    for {set i 0} {$i < [llength $texts]} {incr i} {
        if {[lindex $texts $i] eq "About"} {
            for {set j [expr {$i+1}]} {$j < [llength $texts] && $j <= $i+3} {incr j} {
                set t [lindex $texts $j]
                if {[cp_length $t] >= 40} { return $t }
            }
        }
    }
    return ""
}

# Render the coverage block: which sections were actually fetched. Values are
# "fetched", "not_found" (fetched the page but the section was absent), or
# "not_fetched" (the page was never navigated, e.g. --quick).
proc render_coverage {cov} {
    set lines {coverage:}
    foreach k {topcard experience skills about} {
        lappend lines "  $k: [dict get $cov $k]"
    }
    return [join $lines "\n"]
}

# Scroll to the foot of the current page a few times so lazy-mounted sections
# render, then return the dumped DOM.
proc scroll_and_dump {} {
    for {set i 0} {$i < 4} {incr i} {
        eval {window.scrollTo(0, document.body.scrollHeight)}
        dwell 1
    }
    return [dump]
}

proc serialiser_run {skillArgs} {
    set quick 0
    set arg ""
    foreach a $skillArgs {
        if {$a eq "--quick"} { set quick 1; continue }
        # --experience is accepted as a no-op alias: the default now fetches it.
        if {$a eq "--experience" || $a eq "--full"} { continue }
        if {$arg eq ""} { set arg $a }
    }
    if {$arg eq ""} {
        emit "ERROR: usage: linkedin.com/parse-profile <slug-or-url> \[--quick\]"
        return
    }
    set slug [slug_from_arg $arg]
    if {$slug eq ""} {
        emit "ERROR: could not derive a profile slug from '$arg'"
        return
    }

    # 1. Topcard (always).
    nav "https://www.linkedin.com/in/$slug/" --wait 6
    if {[dict get [state] terminal] ne ""} {
        emit "ERROR: LinkedIn session expired. Log in via a Chrome-compatible browser first."
        return
    }
    set main_html [scroll_and_dump]
    set record [render_profile $main_html $arg]
    if {$record eq "@@LOGIN@@"} {
        emit "ERROR: LinkedIn session expired. Log in via a Chrome-compatible browser first."
        return
    }
    set cov [dict create topcard fetched experience not_fetched \
        skills not_fetched about not_fetched]
    # Owner name (for filtering it out of the skills chrome), from the title.
    set pname ""
    if {[regexp {(?s)<title[^>]*>(.*?)</title>} $main_html -> _t]} {
        set pname [string trim [string map {" | LinkedIn" ""} [string trim $_t]]]
    }

    # --quick: header only. current_company is honest -- the headline rarely
    # carries it, and Experience was not read, so it is not_fetched, never null.
    if {$quick} {
        append record "\ncurrent_company: not_fetched"
        append record "\n[render_coverage $cov]"
        emit $record
        return
    }

    # 2. Experience details (default).
    set entries {}
    nav "https://www.linkedin.com/in/$slug/details/experience/" --wait 5
    if {[dict get [state] terminal] eq ""} {
        set entries [parse_experience_entries [extract_experience_texts [scroll_and_dump]]]
        dict set cov experience fetched
    }

    # 3. Skills details (default).
    set skills {}
    nav "https://www.linkedin.com/in/$slug/details/skills/" --wait 5
    if {[dict get [state] terminal] eq ""} {
        set skills [extract_skills [scroll_and_dump] $pname]
        dict set cov skills fetched
    }

    # 4. About: best-effort from the (already scrolled) main page.
    set about [extract_about $main_html]
    if {$about ne ""} { dict set cov about fetched } else { dict set cov about not_found }

    # current_company is now grounded: the ongoing position's company when
    # Experience was read, else null (a real "no current role" once read).
    if {[dict get $cov experience] eq "fetched"} {
        set cc [current_company_from_entries $entries]
        append record "\ncurrent_company: [emit_or_null $cc]"
    } else {
        append record "\ncurrent_company: not_fetched"
    }
    append record "\n[render_experience_entries $entries]"
    append record "\n[render_skills_block $skills]"
    append record "\nabout: [emit_or_null $about]"
    append record "\n[render_coverage $cov]"
    emit $record
}

# A scalar value, or the literal null when empty (the None sentinel). The empty
# string is a real possible value only for name; PyYAML renders None as null and
# an empty string as ''. In this record every "" originates from a Python None
# (the inference functions return None, slug/url None, etc.), except name which
# is `name or None` so "" also becomes null. So "" -> null throughout.
proc emit_or_null {v} {
    if {$v eq ""} { return null }
    return [yaml_scalar $v]
}

# Direct-tclsh entry: an HTML path and optional url/slug. Skipped when sourced as
# a serialiser skill (no argv0 match).
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] < 1} {
        puts stderr "Usage: parse-profile.tcl <profile.html> \[profile-url-or-slug\]"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_profile [lindex $argv 0] [expr {[llength $argv] > 1 ? [lindex $argv 1] : ""}]
}
