// CalDAV wire format: request bodies, curl argv, and response parsing.
// Pure functions only — Panel.qml owns the actual Process objects and the
// credential handoff (see its keyringLookup/runCurl helpers). Kept
// dependency-free so it loads under plain node too.

// Namespace prefixes on a multistatus response are server-chosen ("d:",
// "D:", "cal:", "x1:", ...). Stripping any "<word:" / "</word:" right after
// an angle bracket normalizes every response to bare tag names, which turns
// the rest of this file into plain string/regex work instead of a real XML
// parser. This only touches tag *names* (immediately after "<" or "</"),
// never attribute values, so "xmlns:d=..." URLs are untouched.
function stripNsPrefixes(xml) {
  return String(xml || "").replace(/<(\/?)[A-Za-z0-9]+:/g, "<$1")
}

function xmlUnescape(s) {
  return String(s === undefined || s === null ? "" : s)
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, function(m, code) { return String.fromCharCode(parseInt(code, 10)) })
    .replace(/&amp;/g, "&")
}

function extractTag(block, tag) {
  var re = new RegExp("<" + tag + "[^>]*>([\\s\\S]*?)</" + tag + ">", "i")
  var m = re.exec(block)
  return m ? xmlUnescape(m[1]) : null
}

function hasSelfOrEmptyTag(block, tag) {
  return new RegExp("<" + tag + "(\\s[^>]*)?/?>", "i").test(block)
}

function extractAllBlocks(xml, tag) {
  var re = new RegExp("<" + tag + "[^>]*>[\\s\\S]*?</" + tag + ">", "gi")
  return xml.match(re) || []
}

function joinUrl(base, path) {
  var b = String(base || "").replace(/\/+$/, "")
  var p = String(path || "")
  if (p.indexOf("http://") === 0 || p.indexOf("https://") === 0) return p
  return b + (p.charAt(0) === "/" ? "" : "/") + p
}

// Adds a scheme if the user typed a bare host, strips trailing slash.
function normalizeServerUrl(input) {
  var v = String(input || "").trim().replace(/\/+$/, "")
  if (v === "") return ""
  if (!/^https?:\/\//i.test(v)) v = "https://" + v
  return v
}

function calendarsHomeUrl(serverUrl, username) {
  return joinUrl(serverUrl, "/remote.php/dav/calendars/" + encodeURIComponent(username) + "/")
}

// curl reads "user = \"user:pass\"" from stdin via -K -, so the credential
// never appears in argv (and so never in `ps`/`/proc/<pid>/cmdline`).
function netrcConfigLine(username, password) {
  var escaped = String(password || "").replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
  var user = String(username || "").replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
  return "user = \"" + user + ":" + escaped + "\"\n"
}

function baseCurlArgs() {
  return ["curl", "-fsS", "--max-time", "12", "-K", "-"]
}

function propfindCalendarsRequest(serverUrl, username, password) {
  var body = '<?xml version="1.0" encoding="utf-8" ?>'
    + '<d:propfind xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">'
    + '<d:prop><d:resourcetype/><d:displayname/></d:prop>'
    + '</d:propfind>'
  var url = calendarsHomeUrl(serverUrl, username)
  var argv = baseCurlArgs().concat([
    "-X", "PROPFIND",
    "--header", "Depth: 1",
    "--header", "Content-Type: application/xml; charset=utf-8",
    "--data-binary", body,
    url
  ])
  return { argv: argv, stdin: netrcConfigLine(username, password), url: url }
}

function parseCalendarList(xmlText, homeUrl) {
  var xml = stripNsPrefixes(String(xmlText || ""))
  var responses = extractAllBlocks(xml, "response")
  var calendars = []
  for (var i = 0; i < responses.length; i++) {
    var block = responses[i]
    if (!hasSelfOrEmptyTag(block, "calendar")) continue
    var href = extractTag(block, "href")
    if (!href) continue
    // The home collection itself sometimes echoes back with resourcetype
    // collection-only in older servers; guard by requiring the href to be
    // longer than the home path.
    if (homeUrl && href.replace(/\/+$/, "") === homeUrl.replace(/^https?:\/\/[^\/]+/, "").replace(/\/+$/, "")) continue
    var displayName = extractTag(block, "displayname")
    var segments = href.replace(/\/+$/, "").split("/")
    var fallback = decodeURIComponent(segments[segments.length - 1] || href)
    calendars.push({ href: href, displayName: displayName && displayName.trim() !== "" ? displayName : fallback })
  }
  return calendars
}

function reportEventsRequest(serverUrl, calendarHref, username, password, startDate, endDateExclusive, ModelLib) {
  var startStamp = ModelLib.toUTCStamp(startDate)
  var endStamp = ModelLib.toUTCStamp(endDateExclusive)
  var body = '<?xml version="1.0" encoding="utf-8" ?>'
    + '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
    + '<d:prop><d:getetag/>'
    + '<c:calendar-data><c:expand start="' + startStamp + '" end="' + endStamp + '"/></c:calendar-data>'
    + '</d:prop>'
    + '<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">'
    + '<c:time-range start="' + startStamp + '" end="' + endStamp + '"/>'
    + '</c:comp-filter></c:comp-filter></c:filter>'
    + '</c:calendar-query>'
  var url = joinUrl(serverUrl, calendarHref)
  var argv = baseCurlArgs().concat([
    "-X", "REPORT",
    "--header", "Depth: 1",
    "--header", "Content-Type: application/xml; charset=utf-8",
    "--data-binary", body,
    url
  ])
  return { argv: argv, stdin: netrcConfigLine(username, password), url: url }
}

function parseEventsFromReport(xmlText) {
  var xml = stripNsPrefixes(String(xmlText || ""))
  var responses = extractAllBlocks(xml, "response")
  var out = []
  for (var i = 0; i < responses.length; i++) {
    var block = responses[i]
    var href = extractTag(block, "href")
    var ics = extractTag(block, "calendar-data")
    if (!href || !ics) continue
    out.push({ href: href, ics: ics })
  }
  return out
}

// For an update, `existingHref` (captured from the REPORT that returned the
// event) MUST be used as-is: Nextcloud's CalDAV backend does not always
// store an object under "<uid>.ics" — it may assign its own resource name
// on creation — so re-deriving the path from the uid can 404 or, worse,
// create a duplicate. Only a brand-new event (isCreate, no existingHref
// yet) is addressed by "<calendarHref>/<uid>.ics".
function putEventRequest(serverUrl, calendarHref, existingHref, username, password, uid, icsBody, isCreate) {
  var url = (!isCreate && existingHref)
    ? joinUrl(serverUrl, existingHref)
    : joinUrl(serverUrl, calendarHref.replace(/\/+$/, "") + "/" + uid + ".ics")
  var argv = baseCurlArgs().concat([
    "-X", "PUT",
    "--header", "Content-Type: text/calendar; charset=utf-8"
  ])
  if (isCreate) argv = argv.concat(["--header", "If-None-Match: *"])
  argv = argv.concat(["--data-binary", icsBody, url])
  return { argv: argv, stdin: netrcConfigLine(username, password), url: url }
}

function deleteEventRequest(serverUrl, hrefOrPath, username, password) {
  var url = joinUrl(serverUrl, hrefOrPath)
  var argv = baseCurlArgs().concat(["-X", "DELETE", url])
  return { argv: argv, stdin: netrcConfigLine(username, password), url: url }
}

if (typeof module !== "undefined") {
  module.exports = {
    stripNsPrefixes: stripNsPrefixes,
    xmlUnescape: xmlUnescape,
    extractTag: extractTag,
    extractAllBlocks: extractAllBlocks,
    joinUrl: joinUrl,
    normalizeServerUrl: normalizeServerUrl,
    calendarsHomeUrl: calendarsHomeUrl,
    netrcConfigLine: netrcConfigLine,
    propfindCalendarsRequest: propfindCalendarsRequest,
    parseCalendarList: parseCalendarList,
    reportEventsRequest: reportEventsRequest,
    parseEventsFromReport: parseEventsFromReport,
    putEventRequest: putEventRequest,
    deleteEventRequest: deleteEventRequest
  }
}
