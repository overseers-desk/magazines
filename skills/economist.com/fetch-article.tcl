# fetch-article.tcl - fetch one article and emit its text as markdown.
#
# The article page embeds the full body in __NEXT_DATA__ (content.body); a
# logged-in subscriber session renders it unwalled. Argument is the URL path as
# it appears in the topic feed (/section/YYYY/MM/DD/slug) or a full URL.
#
#   browser-serialiser economist.com/fetch-article /leaders/2026/06/25/the-ai-backlash-is-only-getting-started

source [file join [file dirname [info script]] economist.tcl]

proc serialiser_run {skillArgs} {
    set path [lindex $skillArgs 0]
    if {$path eq ""} { emit "error: no article path given"; return }
    if {![string match "http*" $path]} {
        set path "https://www.economist.com$path"
    }
    nav $path --wait 4
    if {[dict get [state] terminal] ne ""} {
        emit "error: [dict get [state] terminal] fetching $path"
        return
    }
    set pp [economist::nextdata [dump]]
    emit [economist::article_markdown $pp]
}
