#!/usr/bin/env tclsh
# Ad hoc: enumerate every deviation URL in a DeviantArt gallery folder,
# paginating past the ~25 items an initial DOM snapshot renders.
#
# Usage: browser-serialiser deviantart.com/gallery-contents <username> <folderid>

package require json

proc serialiser_run {skillArgs} {
    set username [lindex $skillArgs 0]
    set folderid [lindex $skillArgs 1]
    if {$username eq "" || $folderid eq ""} {
        emit "{\"error\": \"Usage: gallery-contents <username> <folderid>\"}"
        return
    }

    nav "https://www.deviantart.com/$username/gallery/$folderid" --wait 4
    set st [state]
    if {[dict get $st terminal] ne ""} {
        emit "{\"error\": \"wall: [dict get $st terminal]\"}"
        return
    }

    set js {
    (async () => {
        const csrf = window.__CSRF_TOKEN__ || '';
        const all = [];
        let offset = 0;
        const limit = 24;
        let hasMore = true;
        let pages = 0;
        while (hasMore && pages < 30) {
            const path = "/_puppy/dashared/gallection/contents?username=@USER@&type=gallery&folderid=@FOLDER@&offset=" + offset + "&limit=" + limit + "&all_folder=false&mode=popular&csrf_token=" + encodeURIComponent(csrf);
            const resp = await fetch(path, {credentials: 'include', headers: {'X-Requested-With': 'XMLHttpRequest'}});
            if (!resp.ok) { all.push({error: 'HTTP ' + resp.status, offset}); break; }
            const data = await resp.json();
            const results = data.results || [];
            for (const r of results) {
                all.push({
                    id: r.deviationId,
                    url: r.url,
                    title: r.title,
                    isVideo: !!r.isVideo,
                    isDownloadable: !!r.isDownloadable
                });
            }
            hasMore = !!data.hasMore;
            offset = data.nextOffset != null ? data.nextOffset : (offset + limit);
            pages++;
            if (!results.length) break;
        }
        return JSON.stringify({count: all.length, pages, items: all});
    })()
    }
    set js [string map [list @USER@ $username @FOLDER@ $folderid] $js]
    set raw [eval $js]
    emit $raw
}
