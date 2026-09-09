// Pure date math + iCalendar (RFC 5545) read/write for the Nextcloud
// Calendar plugin. No QML/Quickshell dependency so it can be loaded under
// plain node for quick checks (`node -e "require('./Model.js')"`).

var MS_PER_DAY = 86400000

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

function pad4(value) {
  var n = Number(value)
  if (n < 10) return "000" + n
  if (n < 100) return "00" + n
  if (n < 1000) return "0" + n
  return String(n)
}

function dateKey(year, month, day) {
  return pad4(year) + "-" + pad2(Number(month) + 1) + "-" + pad2(day)
}

function keyForDate(date) {
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0, 0)
}

function addDays(date, n) {
  var d = new Date(date.getTime())
  d.setDate(d.getDate() + n)
  return d
}

function addMonths(date, n) {
  return new Date(date.getFullYear(), date.getMonth() + n, 1)
}

// Monday-start by default (weekStart 0=Sunday..6=Saturday).
function startOfWeek(date, weekStart) {
  var start = (weekStart === undefined || weekStart === null) ? 1 : weekStart
  var day = date.getDay()
  var diff = (day - start + 7) % 7
  return addDays(startOfDay(date), -diff)
}

// Always six rows of seven days, same trick as the clock widget's month
// grid: a fixed height means switching months never resizes the popup.
function monthGrid(year, month, weekStart, todayKey) {
  var start = (weekStart === undefined || weekStart === null) ? 1 : weekStart
  var leading = (new Date(year, month, 1).getDay() - start + 7) % 7
  var cursor = new Date(year, month, 1 - leading)
  var today = String(todayKey || "")
  var weeks = []

  for (var w = 0; w < 6; w++) {
    var days = []
    for (var d = 0; d < 7; d++) {
      var cellYear = cursor.getFullYear()
      var cellMonth = cursor.getMonth()
      var cellDay = cursor.getDate()
      var key = dateKey(cellYear, cellMonth, cellDay)
      days.push({
        key: key,
        year: cellYear,
        month: cellMonth,
        day: cellDay,
        weekday: cursor.getDay(),
        inMonth: cellMonth === month && cellYear === year,
        today: key === today
      })
      cursor.setDate(cursor.getDate() + 1)
    }
    weeks.push({ days: days })
  }
  return weeks
}

function stepMonth(year, month, delta) {
  var target = new Date(year, Number(month) + Number(delta), 1)
  return { year: target.getFullYear(), month: target.getMonth() }
}

function pad(n) { return pad2(n) }

// "YYYYMMDDTHHMMSSZ" — UTC, used for CalDAV time-range filters and for
// DTSTART/DTEND when we write events back. Writing everything in UTC
// sidesteps the need to embed a VTIMEZONE block in generated ICS.
function toUTCStamp(date) {
  return date.getUTCFullYear() + pad(date.getUTCMonth() + 1) + pad(date.getUTCDate())
    + "T" + pad(date.getUTCHours()) + pad(date.getUTCMinutes()) + pad(date.getUTCSeconds()) + "Z"
}

function toICSDate(date, allDay) {
  if (allDay) return date.getFullYear() + pad(date.getMonth() + 1) + pad(date.getDate())
  return toUTCStamp(date)
}

// Accepts "YYYYMMDD" (DATE), "YYYYMMDDTHHMMSSZ" (UTC) or
// "YYYYMMDDTHHMMSS" (floating/local — treated as local time, which matches
// how most calendar apps show floating times to the user). Returns null on
// anything unparseable.
function parseICSDateTime(value, params) {
  if (!value) return null
  var v = String(value).trim()
  var isDateOnly = (params && /VALUE=DATE(?!-TIME)/i.test(params)) || /^\d{8}$/.test(v)

  var m = v.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/)
  if (!m) return null

  var year = parseInt(m[1], 10), month = parseInt(m[2], 10) - 1, day = parseInt(m[3], 10)
  if (isDateOnly || !m[4]) return { date: new Date(year, month, day, 0, 0, 0, 0), allDay: true }

  var hour = parseInt(m[4], 10), min = parseInt(m[5], 10), sec = parseInt(m[6], 10)
  if (m[7] === "Z") return { date: new Date(Date.UTC(year, month, day, hour, min, sec)), allDay: false }
  return { date: new Date(year, month, day, hour, min, sec), allDay: false }
}

// PT1H30M, P1D, PT30M, ... only the units iCalendar actually emits for
// event durations. Weeks (P1W) are rare on VEVENT DURATION but handled too.
function parseICSDuration(value) {
  var m = String(value || "").match(/^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/)
  if (!m) return 0
  var sign = m[1] === "-" ? -1 : 1
  var weeks = parseInt(m[2] || "0", 10), days = parseInt(m[3] || "0", 10)
  var hours = parseInt(m[4] || "0", 10), mins = parseInt(m[5] || "0", 10), secs = parseInt(m[6] || "0", 10)
  return sign * (((weeks * 7 + days) * 24 + hours) * 3600 + mins * 60 + secs) * 1000
}

function unfoldICS(text) {
  return String(text || "").replace(/\r\n/g, "\n").replace(/\n[ \t]/g, "")
}

function escapeICSText(s) {
  return String(s === undefined || s === null ? "" : s)
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\n/g, "\\n")
}

function unescapeICSText(s) {
  return String(s === undefined || s === null ? "" : s)
    .replace(/\\n/gi, "\n")
    .replace(/\\,/g, ",")
    .replace(/\\;/g, ";")
    .replace(/\\\\/g, "\\")
}

// Folds a logical line at 75 octets with CRLF + single-space continuation,
// as RFC 5545 requires. Most servers tolerate unfolded lines, but Nextcloud
// (Sabre/DAV) has been known to reject or mangle very long SUMMARY/
// DESCRIPTION values without it.
function foldICSLine(line) {
  if (line.length <= 75) return line
  var out = line.substring(0, 75)
  var rest = line.substring(75)
  while (rest.length > 0) {
    var chunk = rest.substring(0, 74)
    rest = rest.substring(74)
    out += "\r\n " + chunk
  }
  return out
}

function uuid() {
  var chars = "0123456789abcdef"
  var s = ""
  for (var i = 0; i < 32; i++) {
    if (i === 8 || i === 12 || i === 16 || i === 20) s += "-"
    if (i === 12) { s += "4"; continue }
    if (i === 16) { s += chars[8 + Math.floor(Math.random() * 4)]; continue }
    s += chars[Math.floor(Math.random() * 16)]
  }
  return s
}

function getProp(props, name) {
  return props[name] && props[name].length ? props[name][0] : null
}

// ";CN=Jane Doe;ROLE=REQ-PARTICIPANT" -> {CN: "Jane Doe", ROLE: "REQ-PARTICIPANT"}.
// Quoted values (needed once a value itself contains a "," or ";") have
// their surrounding quotes stripped.
function parseParams(paramsStr) {
  var out = {}
  if (!paramsStr) return out
  var parts = paramsStr.replace(/^;/, "").split(";")
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq === -1) continue
    var key = parts[i].substring(0, eq).toUpperCase()
    var val = parts[i].substring(eq + 1)
    if (val.length >= 2 && val.charAt(0) === "\"" && val.charAt(val.length - 1) === "\"") val = val.substring(1, val.length - 1)
    out[key] = val
  }
  return out
}

// Shared by ATTENDEE and ORGANIZER, which are both "CN + mailto:" properties.
function parsePersonProp(prop) {
  if (!prop) return null
  var params = parseParams(prop.params)
  var email = String(prop.value || "").trim().replace(/^mailto:/i, "")
  if (!email) return null
  return {
    name: params.CN || "",
    email: email,
    partstat: params.PARTSTAT || "NEEDS-ACTION",
    role: params.ROLE || "REQ-PARTICIPANT"
  }
}

// Splits one VCALENDAR blob into its VEVENT blocks and reads the handful of
// properties the panel cares about. A REPORT with CALDAV:expand returns one
// VEVENT per occurrence (already materialized DTSTART/DTEND), so this does
// not itself expand RRULEs — it just reads whatever the server handed back.
function parseICS(icsText) {
  var text = unfoldICS(icsText)
  var events = []
  var blockRe = /BEGIN:VEVENT([\s\S]*?)END:VEVENT/g
  var blockMatch
  while ((blockMatch = blockRe.exec(text)) !== null) {
    var lines = blockMatch[1].split("\n")
    var props = {}
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var sep = line.indexOf(":")
      if (sep === -1) continue
      var head = line.substring(0, sep)
      var value = line.substring(sep + 1)
      var semi = head.indexOf(";")
      var name = (semi === -1 ? head : head.substring(0, semi)).toUpperCase()
      var params = semi === -1 ? "" : head.substring(semi)
      if (!props[name]) props[name] = []
      props[name].push({ params: params, value: value })
    }

    var dtstartProp = getProp(props, "DTSTART")
    var dtendProp = getProp(props, "DTEND")
    var durationProp = getProp(props, "DURATION")
    if (!dtstartProp) continue

    var startParsed = parseICSDateTime(dtstartProp.value, dtstartProp.params)
    if (!startParsed) continue

    var endParsed = null
    if (dtendProp) endParsed = parseICSDateTime(dtendProp.value, dtendProp.params)
    var endDate
    if (endParsed) {
      endDate = endParsed.date
    } else if (durationProp) {
      endDate = new Date(startParsed.date.getTime() + parseICSDuration(durationProp.value))
    } else if (startParsed.allDay) {
      endDate = addDays(startParsed.date, 1)
    } else {
      endDate = startParsed.date
    }

    var summaryProp = getProp(props, "SUMMARY")
    var descProp = getProp(props, "DESCRIPTION")
    var locProp = getProp(props, "LOCATION")
    var uidProp = getProp(props, "UID")
    var organizerProp = getProp(props, "ORGANIZER")

    var attendees = []
    if (props["ATTENDEE"]) {
      for (var ai = 0; ai < props["ATTENDEE"].length; ai++) {
        var attendee = parsePersonProp(props["ATTENDEE"][ai])
        if (attendee) attendees.push(attendee)
      }
    }

    events.push({
      uid: uidProp ? uidProp.value : "",
      summary: summaryProp ? unescapeICSText(summaryProp.value) : "",
      description: descProp ? unescapeICSText(descProp.value) : "",
      location: locProp ? unescapeICSText(locProp.value) : "",
      start: startParsed.date,
      end: endDate,
      allDay: startParsed.allDay,
      recurring: !!(props["RRULE"] || props["RECURRENCE-ID"]),
      organizer: parsePersonProp(organizerProp),
      attendees: attendees
    })
  }
  return events
}

// RFC 5545 quotes a param value only when it needs to be — i.e. once it
// contains a character ("," ";" ":") that would otherwise be ambiguous with
// the param-list grammar itself.
function icsParamValue(value) {
  var s = String(value || "")
  return /[,;:]/.test(s) ? "\"" + s.replace(/"/g, "'") + "\"" : s
}

function buildEventICS(event) {
  var now = new Date()
  var lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Omarchy//NextcloudCalendarPlugin//EN",
    "BEGIN:VEVENT",
    "UID:" + event.uid,
    "DTSTAMP:" + toUTCStamp(now),
    (event.allDay ? "DTSTART;VALUE=DATE:" : "DTSTART:") + toICSDate(event.start, event.allDay),
    (event.allDay ? "DTEND;VALUE=DATE:" : "DTEND:") + toICSDate(event.end, event.allDay),
    "SUMMARY:" + escapeICSText(event.summary)
  ]
  if (event.location) lines.push("LOCATION:" + escapeICSText(event.location))
  if (event.description) lines.push("DESCRIPTION:" + escapeICSText(event.description))
  if (event.organizer && event.organizer.email) {
    lines.push("ORGANIZER" + (event.organizer.name ? ";CN=" + icsParamValue(event.organizer.name) : "") + ":mailto:" + event.organizer.email)
  }
  if (event.attendees) {
    for (var ai = 0; ai < event.attendees.length; ai++) {
      var att = event.attendees[ai]
      if (!att.email) continue
      var cn = att.name ? ";CN=" + icsParamValue(att.name) : ""
      var partstat = att.partstat || "NEEDS-ACTION"
      var role = att.role || "REQ-PARTICIPANT"
      lines.push("ATTENDEE" + cn + ";CUTYPE=INDIVIDUAL;ROLE=" + role + ";PARTSTAT=" + partstat + ";RSVP=TRUE:mailto:" + att.email)
    }
  }
  lines.push("END:VEVENT")
  lines.push("END:VCALENDAR")

  var folded = []
  for (var i = 0; i < lines.length; i++) folded.push(foldICSLine(lines[i]))
  return folded.join("\r\n") + "\r\n"
}

function formatHM(date) {
  return pad2(date.getHours()) + ":" + pad2(date.getMinutes())
}

// Fixed UTC-offset zones, in minutes ahead of UTC. This QML JS engine has no
// Intl/ICU (Intl.DateTimeFormat is literally undefined here — confirmed by
// hand), so there is no way to resolve a real IANA tzid's rules including
// DST. A fixed offset the user picks themselves is the honest fallback: the
// city names are just landmarks to help pick the right line, not a claim
// that the zone is DST-aware.
var TIMEZONES = [
  { id: "-720", offset: -720, label: "UTC-12:00" },
  { id: "-660", offset: -660, label: "UTC-11:00 (Pago Pago)" },
  { id: "-600", offset: -600, label: "UTC-10:00 (Honolulu)" },
  { id: "-540", offset: -540, label: "UTC-09:00 (Anchorage)" },
  { id: "-480", offset: -480, label: "UTC-08:00 (Los Angeles)" },
  { id: "-420", offset: -420, label: "UTC-07:00 (Denver)" },
  { id: "-360", offset: -360, label: "UTC-06:00 (Chicago, Mexico City)" },
  { id: "-300", offset: -300, label: "UTC-05:00 (New York, Bogotá, Lima)" },
  { id: "-240", offset: -240, label: "UTC-04:00 (Santiago, Manaus, Caracas)" },
  { id: "-180", offset: -180, label: "UTC-03:00 (São Paulo, Buenos Aires)" },
  { id: "-120", offset: -120, label: "UTC-02:00" },
  { id: "-60", offset: -60, label: "UTC-01:00 (Azores)" },
  { id: "0", offset: 0, label: "UTC+00:00 (London, Lisbon)" },
  { id: "60", offset: 60, label: "UTC+01:00 (Paris, Berlin, Lagos)" },
  { id: "120", offset: 120, label: "UTC+02:00 (Cairo, Athens, Johannesburg)" },
  { id: "180", offset: 180, label: "UTC+03:00 (Moscow, Nairobi, Riyadh)" },
  { id: "210", offset: 210, label: "UTC+03:30 (Tehran)" },
  { id: "240", offset: 240, label: "UTC+04:00 (Dubai, Baku)" },
  { id: "270", offset: 270, label: "UTC+04:30 (Kabul)" },
  { id: "300", offset: 300, label: "UTC+05:00 (Karachi, Islamabad)" },
  { id: "330", offset: 330, label: "UTC+05:30 (New Delhi, Mumbai)" },
  { id: "345", offset: 345, label: "UTC+05:45 (Kathmandu)" },
  { id: "360", offset: 360, label: "UTC+06:00 (Dhaka)" },
  { id: "420", offset: 420, label: "UTC+07:00 (Bangkok, Jakarta)" },
  { id: "480", offset: 480, label: "UTC+08:00 (Beijing, Singapore, Perth)" },
  { id: "540", offset: 540, label: "UTC+09:00 (Tokyo, Seoul)" },
  { id: "570", offset: 570, label: "UTC+09:30 (Adelaide)" },
  { id: "600", offset: 600, label: "UTC+10:00 (Sydney, Brisbane)" },
  { id: "720", offset: 720, label: "UTC+12:00 (Auckland)" },
  { id: "780", offset: 780, label: "UTC+13:00 (Nuku'alofa)" }
]

function timezoneOptions() {
  return TIMEZONES.slice()
}

function timezoneOffsetForId(id) {
  for (var i = 0; i < TIMEZONES.length; i++) if (TIMEZONES[i].id === id) return TIMEZONES[i].offset
  return 0
}

function timezoneLabelForId(id) {
  for (var i = 0; i < TIMEZONES.length; i++) if (TIMEZONES[i].id === id) return TIMEZONES[i].label
  return id
}

// The device's current UTC offset (in "minutes ahead of UTC" convention,
// the opposite sign of Date.prototype.getTimezoneOffset()), used to pick a
// sensible default zone.
function defaultTimezoneOffsetMinutes() {
  return -(new Date().getTimezoneOffset())
}

function closestTimezoneId(offsetMinutes) {
  var best = TIMEZONES[0]
  var bestDiff = Math.abs(TIMEZONES[0].offset - offsetMinutes)
  for (var i = 1; i < TIMEZONES.length; i++) {
    var diff = Math.abs(TIMEZONES[i].offset - offsetMinutes)
    if (diff < bestDiff) { bestDiff = diff; best = TIMEZONES[i] }
  }
  return best.id
}

// A wall-clock reading (y, m, d, h, mi) as lived in a zone `offsetMinutes`
// ahead of UTC, converted to the actual UTC instant it refers to.
function wallClockToUTC(year, month, day, hour, minute, offsetMinutes) {
  return new Date(Date.UTC(year, month, day, hour, minute, 0) - offsetMinutes * 60000)
}

// The inverse of wallClockToUTC: returns a Date whose UTC-getters
// (getUTCFullYear, getUTCHours, ...) carry the wall-clock digits `date`
// reads as in zone `offsetMinutes`. Deliberately routed through the UTC
// getters rather than the local ones, so this never depends on — or gets
// confused with — the machine's own system timezone.
function utcToWallClock(date, offsetMinutes) {
  return new Date(date.getTime() + offsetMinutes * 60000)
}

// Fractional hour (0..24) a moment falls at within its own calendar day —
// the y-axis unit for the week grid. Clamping keeps a multi-day event's
// slice within a single day column sane.
function hourOfDay(date, dayStart, dayEndExclusive) {
  var clamped = date.getTime() < dayStart.getTime() ? dayStart : (date.getTime() > dayEndExclusive.getTime() ? dayEndExclusive : date)
  return (clamped.getTime() - dayStart.getTime()) / 3600000
}

// Lane assignment for the week grid's per-day column: events that overlap
// in time get distinct side-by-side lanes instead of stacking on top of
// each other. `items` is [{start, end, ...}]; returns the same objects
// with `col` (0-based lane) and `cols` (lane count of the cluster it
// belongs to) added, sorted by start time.
//
// Column packing (first-fit by earliest-freed lane) is the standard greedy
// interval-graph-coloring trick. Clustering afterwards — sweeping in start
// order and folding an item into the current cluster while its start is
// still before the cluster's running max end — groups only the events that
// actually chain together, so an unrelated event later the same day isn't
// squeezed just because two other events overlapped each other.
function layoutDayEvents(items) {
  var sorted = items.slice().sort(function(a, b) {
    var d = a.start.getTime() - b.start.getTime()
    if (d !== 0) return d
    return (b.end.getTime() - b.start.getTime()) - (a.end.getTime() - a.start.getTime())
  })

  var laneEnd = []
  var placed = []
  for (var i = 0; i < sorted.length; i++) {
    var item = sorted[i]
    var lane = -1
    for (var l = 0; l < laneEnd.length; l++) {
      if (laneEnd[l] <= item.start.getTime()) { lane = l; break }
    }
    if (lane === -1) { lane = laneEnd.length; laneEnd.push(0) }
    laneEnd[lane] = item.end.getTime()
    var withLane = { col: lane }
    for (var k in item) withLane[k] = item[k]
    placed.push(withLane)
  }

  var result = []
  var idx = 0
  while (idx < placed.length) {
    var clusterEnd = placed[idx].end.getTime()
    var j = idx + 1
    while (j < placed.length && placed[j].start.getTime() < clusterEnd) {
      if (placed[j].end.getTime() > clusterEnd) clusterEnd = placed[j].end.getTime()
      j++
    }
    var laneCount = 0
    for (var m = idx; m < j; m++) laneCount = Math.max(laneCount, placed[m].col + 1)
    for (var n = idx; n < j; n++) {
      placed[n].cols = laneCount
      result.push(placed[n])
    }
    idx = j
  }
  return result
}

if (typeof module !== "undefined") {
  module.exports = {
    pad2: pad2,
    pad4: pad4,
    dateKey: dateKey,
    keyForDate: keyForDate,
    startOfDay: startOfDay,
    addDays: addDays,
    addMonths: addMonths,
    startOfWeek: startOfWeek,
    monthGrid: monthGrid,
    stepMonth: stepMonth,
    toUTCStamp: toUTCStamp,
    toICSDate: toICSDate,
    parseICSDateTime: parseICSDateTime,
    parseICSDuration: parseICSDuration,
    unfoldICS: unfoldICS,
    escapeICSText: escapeICSText,
    unescapeICSText: unescapeICSText,
    foldICSLine: foldICSLine,
    uuid: uuid,
    parseICS: parseICS,
    hourOfDay: hourOfDay,
    layoutDayEvents: layoutDayEvents,
    buildEventICS: buildEventICS,
    formatHM: formatHM,
    timezoneOptions: timezoneOptions,
    timezoneOffsetForId: timezoneOffsetForId,
    timezoneLabelForId: timezoneLabelForId,
    defaultTimezoneOffsetMinutes: defaultTimezoneOffsetMinutes,
    closestTimezoneId: closestTimezoneId,
    wallClockToUTC: wallClockToUTC,
    utcToWallClock: utcToWallClock
  }
}
