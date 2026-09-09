import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "CalDav.js" as CalDav

Panel {
  id: root
  moduleName: "giuliano.nextcloud-calendar"
  ipcTarget: "giuliano.nextcloud-calendar"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Amber dot used for the month view's "there's something on this day"
  // mark. Not a theme token on purpose — the request was specifically for
  // a yellow dot regardless of accent color.
  readonly property color dotColor: "#e8c547"

  // ---- Connection. Only serverUrl/username/calendars/activeCalendarHref are
  // persisted to disk (settingsFile below); the app password lives only in
  // the system keyring (secret-tool) and, for the life of this session, in
  // _password so we are not shelling out to the keyring before every
  // request.
  property string serverUrl: ""
  property string username: ""
  property var calendars: [] // [{href, displayName}], every discovered calendar
  property string activeCalendarHref: "" // where new events get created — set from the footer
  property string organizerEmail: ""
  property string _password: ""
  readonly property bool connected: serverUrl !== "" && username !== "" && calendars.length > 0
  readonly property bool showFooter: !root.showSettings && root.connected && root.calendars.length > 0
  property bool settingsReady: false

  property int weekStartHour: 0
  property int weekEndHour: 24

  property bool showSettings: false
  property string formServerUrl: ""
  property string formUsername: ""
  property string formPassword: ""
  property string formOrganizerEmail: ""
  property string formStatus: ""
  property string formError: ""
  property bool formBusy: false

  // Fixed-offset timezone list for the Dropdown below (Model.timezoneOptions
  // has no reactive QML dependencies, so this only ever evaluates once).
  readonly property var timezoneDropdownOptions: Model.timezoneOptions().map(function(z) { return { value: z.id, label: z.label } })

  property string viewMode: "month" // day | week | month
  property date viewDate: new Date()
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)
  readonly property var monthGridWeeks: Model.monthGrid(root.viewDate.getFullYear(), root.viewDate.getMonth(), 1, root.todayKey)
  readonly property string rangeLabelText: root.computeRangeLabel()

  property var events: []
  property var monthDots: ({})
  property bool eventsLoading: false
  property string eventsError: ""

  property string nextEventLabel: "—"
  property var nextEvent: null

  property bool editorOpen: false
  property string editorMode: "create" // create | edit
  property string editorUid: ""
  property string editorHref: ""
  property string editorTitle: ""
  property string editorLocation: ""
  property string editorDescription: ""
  property string editorDateText: ""
  property string editorStartText: ""
  property string editorEndText: ""
  property bool editorAllDay: false
  property bool editorRecurring: false
  property string editorTimezoneId: "0"
  property string editorCalendarHref: ""
  property string editorCalendarName: ""
  property var editorAttendees: []
  property string editorOrganizerName: ""
  property string editorOrganizerEmail: ""
  property string attendeeNameInput: ""
  property string attendeeEmailInput: ""
  property string attendeeError: ""
  property string editorError: ""
  property bool editorSaving: false
  property bool confirmDeleteOpen: false

  readonly property string barLabel: root.nextEventLabel
  readonly property string tooltipLabel: root.nextEvent
    ? (root.nextEvent.summary + (root.nextEvent.location ? " — " + root.nextEvent.location : ""))
    : (root.connected ? "No upcoming events" : "Nextcloud Calendar — click to set up")

  function open() {
    root.controller.show()
    if (!root.connected) root.showSettings = true
    else root.refreshCurrentView()
    // Isolated in its own deferred closure: hover-reveal suppression is
    // cosmetic, and must never be able to abort the logic above if the
    // host bar's API shape doesn't match what we expect.
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editorOpen) root.closeEditor()
    root.controller.hide()
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (!root.bar) return
    try {
      if (typeof root.bar.setCenterHoverRevealSuppressed === "function") root.bar.setCenterHoverRevealSuppressed(value)
      else root.bar.centerHoverRevealSuppressed = value
    } catch (e) {}
  }

  function computeRangeLabel() {
    if (root.viewMode === "month") {
      var s = Qt.formatDate(root.viewDate, "MMMM yyyy")
      return s.charAt(0).toUpperCase() + s.slice(1)
    } else if (root.viewMode === "week") {
      var ws = Model.startOfWeek(root.viewDate, 1)
      var we = Model.addDays(ws, 6)
      return Qt.formatDate(ws, "d MMM") + " – " + Qt.formatDate(we, "d MMM")
    }
    var d = Qt.formatDate(root.viewDate, "dddd, d 'de' MMMM")
    return d.charAt(0).toUpperCase() + d.slice(1)
  }

  function eventsForDay(year, month, day) {
    var dayStart = new Date(year, month, day, 0, 0, 0, 0)
    var dayEnd = Model.addDays(dayStart, 1)
    var out = []
    for (var i = 0; i < root.events.length; i++) {
      var e = root.events[i]
      if (e.start.getTime() < dayEnd.getTime() && e.end.getTime() > dayStart.getTime()) out.push(e)
    }
    out.sort(function(a, b) { return a.start.getTime() - b.start.getTime() })
    return out
  }

  function weekDayDate(index) {
    return Model.addDays(Model.startOfWeek(root.viewDate, 1), index)
  }

  function weekAllDayEvents() {
    var out = []
    for (var i = 0; i < 7; i++) {
      var d = root.weekDayDate(i)
      var evts = root.eventsForDay(d.getFullYear(), d.getMonth(), d.getDate())
      for (var j = 0; j < evts.length; j++) if (evts[j].allDay) out.push({ dayIndex: i, event: evts[j] })
    }
    return out
  }

  // Timed (non-all-day) events for one week-grid column, clamped to that
  // day's 00:00–24:00 span and packed into side-by-side lanes so
  // overlapping events don't cover each other.
  // Clamped to the configured week-view hour range (Settings), not the
  // full day: an event entirely outside it is dropped from the grid, one
  // that straddles the edge is clipped to the visible slice.
  function weekTimedLayout(index) {
    var d = root.weekDayDate(index)
    var rangeStart = new Date(d.getFullYear(), d.getMonth(), d.getDate(), root.weekStartHour, 0, 0, 0)
    var rangeEnd = new Date(d.getFullYear(), d.getMonth(), d.getDate(), root.weekEndHour, 0, 0, 0)
    var evts = root.eventsForDay(d.getFullYear(), d.getMonth(), d.getDate())
    var items = []
    for (var i = 0; i < evts.length; i++) {
      if (evts[i].allDay) continue
      if (evts[i].end.getTime() <= rangeStart.getTime() || evts[i].start.getTime() >= rangeEnd.getTime()) continue
      var s = evts[i].start.getTime() < rangeStart.getTime() ? rangeStart : evts[i].start
      var e = evts[i].end.getTime() > rangeEnd.getTime() ? rangeEnd : evts[i].end
      items.push({ start: s, end: e, event: evts[i] })
    }
    return Model.layoutDayEvents(items)
  }

  function buildDotMap(evts) {
    var map = ({})
    for (var i = 0; i < evts.length; i++) {
      var e = evts[i]
      var cursor = Model.startOfDay(e.start)
      var lastMoment = e.allDay ? Model.addDays(e.end, -1) : new Date(e.end.getTime() - 1)
      var lastDay = Model.startOfDay(lastMoment)
      var guard = 0
      while (cursor.getTime() <= lastDay.getTime() && guard < 62) {
        var key = Model.keyForDate(cursor)
        map[key] = (map[key] || 0) + 1
        cursor = Model.addDays(cursor, 1)
        guard++
      }
    }
    return map
  }

  function formatNextLabel(evt) {
    var sameDay = Model.keyForDate(evt.start) === root.todayKey
    if (evt.allDay) return sameDay ? "Today" : Qt.formatDate(evt.start, "dd/MM")
    return sameDay ? Qt.formatDateTime(evt.start, "HH:mm") : Qt.formatDateTime(evt.start, "ddd HH:mm")
  }

  function friendlyCurlError(stderrText) {
    var text = String(stderrText || "").trim()
    if (/\(22\)/.test(text) || /error: 401/i.test(text)) return "Invalid username or password"
    if (/error: 403/i.test(text)) return "Access denied by the server"
    if (/error: 404/i.test(text)) return "Calendar not found on the server"
    if (/\(6\)|\(7\)|could not resolve|couldn't connect|connection refused/i.test(text))
      return "Could not connect to the server"
    if (/\(28\)/.test(text)) return "Timed out talking to the server"
    return text !== "" ? text : "Communication with the server failed"
  }

  function partstatLabel(status) {
    switch (String(status || "").toUpperCase()) {
      case "ACCEPTED": return "Accepted"
      case "DECLINED": return "Declined"
      case "TENTATIVE": return "Tentative"
      default: return "Pending"
    }
  }

  function partstatColor(status) {
    switch (String(status || "").toUpperCase()) {
      case "ACCEPTED": return Color.accent
      case "DECLINED": return root.bar ? root.bar.urgent : Color.urgent
      case "TENTATIVE": return root.dotColor
      default: return Qt.darker(root.contentForeground, 1.6)
    }
  }

  // ---- Persisted settings (never the password).
  FileView {
    id: settingsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/nextcloud-calendar.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applySettingsJson(text())
    onLoadFailed: root.settingsReady = true
    onFileChanged: reload()
  }

  function applySettingsJson(raw) {
    try {
      var data = JSON.parse(raw)
      root.serverUrl = data.serverUrl || ""
      root.username = data.username || ""
      root.calendars = Array.isArray(data.calendars) ? data.calendars : []
      root.activeCalendarHref = data.activeCalendarHref || (root.calendars.length ? root.calendars[0].href : "")
      root.organizerEmail = data.organizerEmail || ""
      root.weekStartHour = root.clampHour(data.weekStartHour, 0)
      root.weekEndHour = root.clampHour(data.weekEndHour, 24, 1, 24)
      if (root.weekEndHour <= root.weekStartHour) root.weekEndHour = 24
    } catch (e) {}
    root.settingsReady = true
    if (root.connected) root.lookupPassword(function() { root.refreshNextEvent() })
  }

  function clampHour(value, fallback, min, max) {
    var n = parseInt(value, 10)
    if (isNaN(n)) return fallback
    return Math.max(min === undefined ? 0 : min, Math.min(max === undefined ? 23 : max, n))
  }

  function persistSettingsFile() {
    var data = {
      serverUrl: root.serverUrl,
      username: root.username,
      calendars: root.calendars,
      activeCalendarHref: root.activeCalendarHref,
      organizerEmail: root.organizerEmail,
      weekStartHour: root.weekStartHour,
      weekEndHour: root.weekEndHour
    }
    settingsFile.setText(JSON.stringify(data, null, 2))
  }

  function setActiveCalendar(href) {
    if (root.activeCalendarHref === href) return
    root.activeCalendarHref = href
    root.persistSettingsFile()
  }

  function calendarDisplayName(href) {
    for (var i = 0; i < root.calendars.length; i++) if (root.calendars[i].href === href) return root.calendars[i].displayName
    return href
  }

  function setWeekHours(start, end) {
    var s = root.clampHour(start, root.weekStartHour, 0, 23)
    var e = root.clampHour(end, root.weekEndHour, 1, 24)
    if (e <= s) e = Math.min(24, s + 1)
    if (s === root.weekStartHour && e === root.weekEndHour) return
    root.weekStartHour = s
    root.weekEndHour = e
    root.persistSettingsFile()
  }

  // ---- System keyring (gnome-keyring via secret-tool). The password is
  // always written/read over the child's stdin, never as an argv element,
  // so it never shows up in `ps`/`/proc/<pid>/cmdline`.
  function keyringAttrs(server, user) {
    return ["service", "omarchy-nextcloud-calendar", "server", server, "account", user]
  }

  function keyringStore(server, user, password, onDone) {
    if (keyringStoreProc.running) keyringStoreProc.running = false
    keyringStoreProc.onDone = onDone
    keyringStoreProc._payload = password + "\n"
    keyringStoreProc.stdinEnabled = true
    keyringStoreProc.command = ["secret-tool", "store", "--label=Omarchy Nextcloud Calendar (" + user + ")"].concat(keyringAttrs(server, user))
    keyringStoreProc.running = true
  }

  function lookupPassword(onDone) {
    if (root.serverUrl === "" || root.username === "") { if (onDone) onDone(false); return }
    if (keyringLookupProc.running) keyringLookupProc.running = false
    keyringLookupProc.onDone = function(ok, text) {
      if (ok) root._password = String(text).replace(/\n$/, "")
      if (onDone) onDone(ok)
    }
    keyringLookupProc.command = ["secret-tool", "lookup"].concat(keyringAttrs(root.serverUrl, root.username))
    keyringLookupProc.running = true
  }

  function ensurePassword(onReady) {
    if (root._password !== "") { onReady(true); return }
    root.lookupPassword(onReady)
  }

  function keyringClear(server, user, onDone) {
    if (keyringClearProc.running) keyringClearProc.running = false
    keyringClearProc.onDone = onDone
    keyringClearProc.command = ["secret-tool", "clear"].concat(keyringAttrs(server, user))
    keyringClearProc.running = true
  }

  // ---- curl runner. `proc` is one of the dedicated Process items below;
  // credentials go over stdin via curl's `-K -` (see CalDav.netrcConfigLine).
  function runCurl(proc, request, onDone) {
    proc.onDone = onDone
    proc._payload = request.stdin
    proc.stdinEnabled = true
    proc.command = request.argv
    proc.running = true
  }

  function fetchRangeForCalendar(proc, calendarHref, startDate, endExclusive, onDone) {
    root.ensurePassword(function(ok) {
      if (!ok || root._password === "") { onDone([], "Could not retrieve the password from the keyring. Reconnect in Settings."); return }
      var req = CalDav.reportEventsRequest(root.serverUrl, calendarHref, root.username, root._password, startDate, endExclusive, Model)
      if (proc.running) proc.running = false
      root.runCurl(proc, req, function(ok2, out, err) {
        if (!ok2) { onDone([], root.friendlyCurlError(err)); return }
        var raw = CalDav.parseEventsFromReport(out)
        var evts = []
        for (var i = 0; i < raw.length; i++) {
          var parsed = Model.parseICS(raw[i].ics)
          for (var j = 0; j < parsed.length; j++) {
            var e = parsed[j]
            e.href = raw[i].href
            evts.push(e)
          }
        }
        onDone(evts, "")
      })
    })
  }

  // Fetches every connected calendar in turn (sequential — they share the
  // one `proc`) and merges the results, tagging each event with the
  // calendar it came from so edits/deletes know which collection to talk
  // to. The first calendar to error still lets the rest through; its
  // message is what the caller sees.
  function fetchRangeAllCalendars(proc, startDate, endExclusive, onDone) {
    if (!root.connected) { onDone([], "not-connected"); return }
    var calendars = root.calendars.slice()
    var allEvents = []
    var firstError = ""
    function next(i) {
      if (i >= calendars.length) {
        allEvents.sort(function(a, b) { return a.start.getTime() - b.start.getTime() })
        onDone(allEvents, firstError)
        return
      }
      root.fetchRangeForCalendar(proc, calendars[i].href, startDate, endExclusive, function(evts, err) {
        if (err && firstError === "") firstError = err
        for (var j = 0; j < evts.length; j++) {
          evts[j].calendarHref = calendars[i].href
          evts[j].calendarName = calendars[i].displayName
          allEvents.push(evts[j])
        }
        next(i + 1)
      })
    }
    next(0)
  }

  function refreshCurrentView() {
    if (!root.connected) return
    root.eventsLoading = true
    root.eventsError = ""
    if (root.viewMode === "month") {
      var grid = root.monthGridWeeks
      var first = grid[0].days[0]
      var last = grid[5].days[6]
      var start = new Date(first.year, first.month, first.day)
      var endExclusive = Model.addDays(new Date(last.year, last.month, last.day), 1)
      root.fetchRangeAllCalendars(viewReportProc, start, endExclusive, function(evts, err) {
        root.eventsLoading = false
        root.eventsError = err
        root.events = evts
        root.monthDots = root.buildDotMap(evts)
      })
    } else if (root.viewMode === "week") {
      var wStart = Model.startOfWeek(root.viewDate, 1)
      var wEnd = Model.addDays(wStart, 7)
      root.fetchRangeAllCalendars(viewReportProc, wStart, wEnd, function(evts, err) {
        root.eventsLoading = false
        root.eventsError = err
        root.events = evts
      })
    } else {
      var dStart = Model.startOfDay(root.viewDate)
      var dEnd = Model.addDays(dStart, 1)
      root.fetchRangeAllCalendars(viewReportProc, dStart, dEnd, function(evts, err) {
        root.eventsLoading = false
        root.eventsError = err
        root.events = evts
      })
    }
  }

  function refreshNextEvent() {
    if (!root.connected) { root.nextEvent = null; root.nextEventLabel = "—"; return }
    var now = new Date()
    root.fetchRangeAllCalendars(nextReportProc, now, Model.addDays(now, 30), function(evts, err) {
      if (err) return
      var best = null
      for (var i = 0; i < evts.length; i++) {
        if (evts[i].end.getTime() > now.getTime()) { best = evts[i]; break }
      }
      root.nextEvent = best
      root.nextEventLabel = best ? root.formatNextLabel(best) : "—"
    })
  }

  function setViewMode(mode) {
    if (root.viewMode === mode) return
    root.viewMode = mode
    root.refreshCurrentView()
  }

  function stepView(delta) {
    if (root.viewMode === "month") root.viewDate = new Date(root.viewDate.getFullYear(), root.viewDate.getMonth() + delta, 1)
    else if (root.viewMode === "week") root.viewDate = Model.addDays(root.viewDate, 7 * delta)
    else root.viewDate = Model.addDays(root.viewDate, delta)
    root.refreshCurrentView()
  }

  function goToday() {
    root.viewDate = new Date()
    root.refreshCurrentView()
  }

  function openDay(year, month, day) {
    root.viewDate = new Date(year, month, day)
    root.viewMode = "day"
    root.refreshCurrentView()
  }

  // ---- Settings / connect flow.
  function openSettings() {
    root.formServerUrl = root.serverUrl
    root.formUsername = root.username
    root.formPassword = ""
    root.formOrganizerEmail = root.organizerEmail
    root.formStatus = ""
    root.formError = ""
    root.showSettings = true
  }

  function saveOrganizerEmail() {
    var trimmed = root.formOrganizerEmail.trim()
    if (trimmed === root.organizerEmail) return
    root.organizerEmail = trimmed
    root.persistSettingsFile()
  }

  function startConnect() {
    var normalized = CalDav.normalizeServerUrl(root.formServerUrl)
    var user = root.formUsername.trim()
    if (normalized === "" || user === "" || root.formPassword === "") {
      root.formError = "Fill in the server URL, username, and app password"
      return
    }
    root.formError = ""
    root.formBusy = true
    root.formStatus = "Saving credentials…"
    root.keyringStore(normalized, user, root.formPassword, function(ok) {
      if (!ok) {
        root.formBusy = false
        root.formStatus = ""
        root.formError = "Could not save the password to the system keyring"
        return
      }
      root.formStatus = "Connecting…"
      var req = CalDav.propfindCalendarsRequest(normalized, user, root.formPassword)
      if (propfindProc.running) propfindProc.running = false
      root.runCurl(propfindProc, req, function(okReq, out, err) {
        root.formBusy = false
        if (!okReq) {
          root.formStatus = ""
          root.formError = root.friendlyCurlError(err)
          return
        }
        var cals = CalDav.parseCalendarList(out, CalDav.calendarsHomeUrl(normalized, user))
        if (cals.length === 0) {
          root.formStatus = ""
          root.formError = "No calendars found for this user"
          return
        }
        root._password = root.formPassword
        root.serverUrl = normalized
        root.username = user
        root.calendars = cals
        root.activeCalendarHref = cals[0].href
        root.persistSettingsFile()
        root.formStatus = ""
        root.showSettings = false
        root.viewMode = "month"
        root.viewDate = new Date()
        root.refreshCurrentView()
        root.refreshNextEvent()
      })
    })
  }

  function disconnectAccount() {
    var server = root.serverUrl, user = root.username
    if (server !== "" && user !== "") root.keyringClear(server, user, function() {})
    root.serverUrl = ""
    root.username = ""
    root.calendars = []
    root.activeCalendarHref = ""
    root._password = ""
    root.events = []
    root.monthDots = ({})
    root.nextEvent = null
    root.nextEventLabel = "—"
    root.persistSettingsFile()
    root.openSettings()
  }

  // ---- Event editor.
  function openEditorForCreate(year, month, day) {
    root.editorMode = "create"
    root.editorUid = Model.uuid()
    root.editorHref = ""
    root.editorCalendarHref = root.activeCalendarHref
    root.editorCalendarName = root.calendarDisplayName(root.activeCalendarHref)
    root.editorTitle = ""
    root.editorLocation = ""
    root.editorDescription = ""
    var base = (year !== undefined) ? new Date(year, month, day) : root.viewDate
    root.editorDateText = Model.keyForDate(base)
    root.editorStartText = "09:00"
    root.editorEndText = "10:00"
    root.editorAllDay = false
    root.editorRecurring = false
    root.editorTimezoneId = Model.closestTimezoneId(Model.defaultTimezoneOffsetMinutes())
    root.editorAttendees = []
    root.editorOrganizerName = ""
    root.editorOrganizerEmail = root.organizerEmail
    root.attendeeNameInput = ""
    root.attendeeEmailInput = ""
    root.attendeeError = ""
    root.editorError = ""
    root.editorOpen = true
  }

  function openEditorForEvent(evt) {
    root.editorMode = "edit"
    root.editorUid = evt.uid
    root.editorHref = evt.href
    root.editorCalendarHref = evt.calendarHref || root.activeCalendarHref
    root.editorCalendarName = evt.calendarName || root.calendarDisplayName(root.editorCalendarHref)
    root.editorTitle = evt.summary
    root.editorLocation = evt.location
    root.editorDescription = evt.description
    root.editorAllDay = evt.allDay
    root.editorRecurring = evt.recurring
    root.editorTimezoneId = Model.closestTimezoneId(Model.defaultTimezoneOffsetMinutes())
    if (evt.allDay) {
      root.editorDateText = Model.keyForDate(evt.start)
      root.editorStartText = "09:00"
      root.editorEndText = "10:00"
    } else {
      var offset = Model.timezoneOffsetForId(root.editorTimezoneId)
      var ws = Model.utcToWallClock(evt.start, offset)
      var we = Model.utcToWallClock(evt.end, offset)
      root.editorDateText = Model.dateKey(ws.getUTCFullYear(), ws.getUTCMonth(), ws.getUTCDate())
      root.editorStartText = Model.pad2(ws.getUTCHours()) + ":" + Model.pad2(ws.getUTCMinutes())
      root.editorEndText = Model.pad2(we.getUTCHours()) + ":" + Model.pad2(we.getUTCMinutes())
    }
    root.editorAttendees = evt.attendees ? evt.attendees.slice() : []
    root.editorOrganizerName = evt.organizer ? evt.organizer.name : ""
    root.editorOrganizerEmail = evt.organizer ? evt.organizer.email : root.organizerEmail
    root.attendeeNameInput = ""
    root.attendeeEmailInput = ""
    root.attendeeError = ""
    root.editorError = ""
    root.editorOpen = true
  }

  function closeEditor() {
    root.editorOpen = false
    root.confirmDeleteOpen = false
    root.editorError = ""
  }

  // Re-expresses the wall-clock fields in a newly picked zone while keeping
  // the underlying instant fixed — the same "same moment, different clock"
  // behavior other calendar apps use when you switch an event's timezone.
  function retimezone(newId) {
    if (newId === root.editorTimezoneId || root.editorAllDay) { root.editorTimezoneId = newId; return }
    var parsed = root.parseEditorForm()
    if (parsed.ok) {
      var newOffset = Model.timezoneOffsetForId(newId)
      var ws = Model.utcToWallClock(parsed.start, newOffset)
      var we = Model.utcToWallClock(parsed.end, newOffset)
      root.editorDateText = Model.dateKey(ws.getUTCFullYear(), ws.getUTCMonth(), ws.getUTCDate())
      root.editorStartText = Model.pad2(ws.getUTCHours()) + ":" + Model.pad2(ws.getUTCMinutes())
      root.editorEndText = Model.pad2(we.getUTCHours()) + ":" + Model.pad2(we.getUTCMinutes())
    }
    root.editorTimezoneId = newId
  }

  function addAttendee() {
    var email = root.attendeeEmailInput.trim()
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      root.attendeeError = "Enter a valid email address"
      return
    }
    for (var i = 0; i < root.editorAttendees.length; i++) {
      if (root.editorAttendees[i].email.toLowerCase() === email.toLowerCase()) {
        root.attendeeError = "That person is already on the guest list"
        return
      }
    }
    var next = root.editorAttendees.slice()
    next.push({ name: root.attendeeNameInput.trim(), email: email, partstat: "NEEDS-ACTION", role: "REQ-PARTICIPANT" })
    root.editorAttendees = next
    root.attendeeNameInput = ""
    root.attendeeEmailInput = ""
    root.attendeeError = ""
  }

  function removeAttendee(email) {
    var next = []
    for (var i = 0; i < root.editorAttendees.length; i++) if (root.editorAttendees[i].email !== email) next.push(root.editorAttendees[i])
    root.editorAttendees = next
  }

  function parseEditorForm() {
    var dm = /^(\d{4})-(\d{2})-(\d{2})$/.exec(root.editorDateText.trim())
    if (!dm) return { ok: false, error: "Invalid date (use YYYY-MM-DD)" }
    var year = parseInt(dm[1], 10), month = parseInt(dm[2], 10) - 1, day = parseInt(dm[3], 10)
    if (root.editorAllDay) {
      var s = new Date(year, month, day)
      return { ok: true, start: s, end: Model.addDays(s, 1) }
    }
    var sm = /^(\d{1,2}):(\d{2})$/.exec(root.editorStartText.trim())
    var em = /^(\d{1,2}):(\d{2})$/.exec(root.editorEndText.trim())
    if (!sm || !em) return { ok: false, error: "Invalid time (use HH:MM)" }
    var offset = Model.timezoneOffsetForId(root.editorTimezoneId)
    var start = Model.wallClockToUTC(year, month, day, parseInt(sm[1], 10), parseInt(sm[2], 10), offset)
    var end = Model.wallClockToUTC(year, month, day, parseInt(em[1], 10), parseInt(em[2], 10), offset)
    if (end.getTime() <= start.getTime()) return { ok: false, error: "The end time must be after the start time" }
    return { ok: true, start: start, end: end }
  }

  function saveEditor() {
    if (root.editorTitle.trim() === "") { root.editorError = "Enter a title"; return }
    var parsed = root.parseEditorForm()
    if (!parsed.ok) { root.editorError = parsed.error; return }
    root.editorError = ""
    root.editorSaving = true
    root.ensurePassword(function(ok) {
      if (!ok || root._password === "") {
        root.editorSaving = false
        root.editorError = "Could not retrieve the password from the keyring."
        return
      }
      var ics = Model.buildEventICS({
        uid: root.editorUid,
        summary: root.editorTitle.trim(),
        description: root.editorDescription,
        location: root.editorLocation,
        start: parsed.start,
        end: parsed.end,
        allDay: root.editorAllDay,
        organizer: root.editorOrganizerEmail ? { name: root.editorOrganizerName, email: root.editorOrganizerEmail } : null,
        attendees: root.editorAttendees
      })
      var isCreate = root.editorMode === "create"
      var req = CalDav.putEventRequest(root.serverUrl, root.editorCalendarHref, root.editorHref, root.username, root._password, root.editorUid, ics, isCreate)
      if (putProc.running) putProc.running = false
      root.runCurl(putProc, req, function(okPut, out, err) {
        root.editorSaving = false
        if (!okPut) { root.editorError = root.friendlyCurlError(err); return }
        root.editorOpen = false
        root.refreshCurrentView()
        root.refreshNextEvent()
      })
    })
  }

  function requestDelete() { root.confirmDeleteOpen = true }

  function confirmDelete() {
    root.confirmDeleteOpen = false
    if (root.editorMode !== "edit" || root.editorHref === "") return
    root.editorSaving = true
    root.ensurePassword(function(ok) {
      if (!ok || root._password === "") {
        root.editorSaving = false
        root.editorError = "Could not retrieve the password from the keyring."
        return
      }
      var req = CalDav.deleteEventRequest(root.serverUrl, root.editorHref, root.username, root._password)
      if (deleteProc.running) deleteProc.running = false
      root.runCurl(deleteProc, req, function(okDel, out, err) {
        root.editorSaving = false
        if (!okDel) { root.editorError = root.friendlyCurlError(err); return }
        root.editorOpen = false
        root.refreshCurrentView()
        root.refreshNextEvent()
      })
    })
  }

  // ---- Background processes. Every one of these carries the credential
  // (when it needs one) over stdin, never in `command`.
  Process {
    id: keyringStoreProc
    property var onDone: null
    property string _payload: ""
    stdinEnabled: true
    onRunningChanged: if (running) { keyringStoreProc.write(keyringStoreProc._payload); keyringStoreProc.stdinEnabled = false }
    onExited: function(code) {
      var cb = keyringStoreProc.onDone
      keyringStoreProc.onDone = null
      if (cb) cb(code === 0)
    }
  }

  Process {
    id: keyringLookupProc
    property var onDone: null
    stdout: StdioCollector { id: keyringLookupStdout; waitForEnd: true }
    onExited: function(code) {
      var cb = keyringLookupProc.onDone
      keyringLookupProc.onDone = null
      if (cb) cb(code === 0, keyringLookupStdout.text)
    }
  }

  Process {
    id: keyringClearProc
    property var onDone: null
    onExited: function(code) {
      var cb = keyringClearProc.onDone
      keyringClearProc.onDone = null
      if (cb) cb(code === 0)
    }
  }

  Process {
    id: propfindProc
    property var onDone: null
    property string _payload: ""
    stdinEnabled: true
    stdout: StdioCollector { id: propfindStdout; waitForEnd: true }
    stderr: StdioCollector { id: propfindStderr; waitForEnd: true }
    onRunningChanged: if (running) { propfindProc.write(propfindProc._payload); propfindProc.stdinEnabled = false }
    onExited: function(code) {
      var cb = propfindProc.onDone
      propfindProc.onDone = null
      if (cb) cb(code === 0, propfindStdout.text, propfindStderr.text)
    }
  }

  Process {
    id: viewReportProc
    property var onDone: null
    property string _payload: ""
    stdinEnabled: true
    stdout: StdioCollector { id: viewReportStdout; waitForEnd: true }
    stderr: StdioCollector { id: viewReportStderr; waitForEnd: true }
    onRunningChanged: if (running) { viewReportProc.write(viewReportProc._payload); viewReportProc.stdinEnabled = false }
    onExited: function(code) {
      var cb = viewReportProc.onDone
      viewReportProc.onDone = null
      if (cb) cb(code === 0, viewReportStdout.text, viewReportStderr.text)
    }
  }

  Process {
    id: nextReportProc
    property var onDone: null
    property string _payload: ""
    stdinEnabled: true
    stdout: StdioCollector { id: nextReportStdout; waitForEnd: true }
    stderr: StdioCollector { id: nextReportStderr; waitForEnd: true }
    onRunningChanged: if (running) { nextReportProc.write(nextReportProc._payload); nextReportProc.stdinEnabled = false }
    onExited: function(code) {
      var cb = nextReportProc.onDone
      nextReportProc.onDone = null
      if (cb) cb(code === 0, nextReportStdout.text, nextReportStderr.text)
    }
  }

  Process {
    id: putProc
    property var onDone: null
    property string _payload: ""
    stdinEnabled: true
    stdout: StdioCollector { id: putStdout; waitForEnd: true }
    stderr: StdioCollector { id: putStderr; waitForEnd: true }
    onRunningChanged: if (running) { putProc.write(putProc._payload); putProc.stdinEnabled = false }
    onExited: function(code) {
      var cb = putProc.onDone
      putProc.onDone = null
      if (cb) cb(code === 0, putStdout.text, putStderr.text)
    }
  }

  Process {
    id: deleteProc
    property var onDone: null
    property string _payload: ""
    stdinEnabled: true
    stdout: StdioCollector { id: deleteStdout; waitForEnd: true }
    stderr: StdioCollector { id: deleteStderr; waitForEnd: true }
    onRunningChanged: if (running) { deleteProc.write(deleteProc._payload); deleteProc.stdinEnabled = false }
    onExited: function(code) {
      var cb = deleteProc.onDone
      deleteProc.onDone = null
      if (cb) cb(code === 0, deleteStdout.text, deleteStderr.text)
    }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.today = clock.date
  }

  Timer {
    interval: 5 * 60 * 1000
    running: true
    repeat: true
    onTriggered: {
      root.refreshNextEvent()
      if (root.opened && !root.showSettings) root.refreshCurrentView()
    }
  }

  // Startup read of settings.json can race the shell's first paint; this
  // self-corrects once, the same defensive re-poke weather.qml does for its
  // own location file.
  Timer {
    interval: 2000
    running: true
    repeat: false
    onTriggered: if (root.connected && root.nextEvent === null) root.refreshNextEvent()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(600))
    contentHeight: panel.fittedContentHeight(Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editorOpen || root.confirmDeleteOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (!root.showSettings && dx !== 0) root.stepView(dx) }
      onActivateRequested: root.goToday()

      Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.showFooter ? calendarFooter.height + Style.space(8) : 0
        spacing: Style.space(10)

        // ---- Header: view tabs (or a settings title) + gear.
        Item {
          width: parent.width
          height: Style.space(28)

          Row {
            visible: !root.showSettings
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              text: "Day"
              selected: root.viewMode === "day"
              bordered: true
              foreground: root.contentForeground
              onClicked: root.setViewMode("day")
            }
            Button {
              text: "Week"
              selected: root.viewMode === "week"
              bordered: true
              foreground: root.contentForeground
              onClicked: root.setViewMode("week")
            }
            Button {
              text: "Month"
              selected: root.viewMode === "month"
              bordered: true
              foreground: root.contentForeground
              onClicked: root.setViewMode("month")
            }
          }

          Text {
            visible: root.showSettings
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Settings — Nextcloud Calendar"
            textFormat: Text.PlainText
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          PanelActionButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰒓"
            tooltipText: root.showSettings ? "Close settings" : "Settings"
            foreground: root.contentForeground
            onClicked: {
              if (root.showSettings) {
                root.showSettings = false
                if (root.connected) root.refreshCurrentView()
              } else {
                root.openSettings()
              }
            }
          }
        }

        // ---- Nav row: prev/today/next + range label, day-only "new event".
        Item {
          visible: !root.showSettings && root.connected
          width: parent.width
          height: Style.space(26)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            PanelActionButton {
              iconText: "󰅁"
              tooltipText: "Previous"
              foreground: root.contentForeground
              onClicked: root.stepView(-1)
            }
            Button {
              text: "Today"
              foreground: root.contentForeground
              onClicked: root.goToday()
            }
            PanelActionButton {
              iconText: "󰅂"
              tooltipText: "Next"
              foreground: root.contentForeground
              onClicked: root.stepView(1)
            }
          }

          Text {
            anchors.centerIn: parent
            text: root.rangeLabelText
            textFormat: Text.PlainText
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          PanelActionButton {
            visible: root.viewMode === "day"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "✎"
            tooltipText: "New event"
            foreground: root.contentForeground
            onClicked: root.openEditorForCreate(root.viewDate.getFullYear(), root.viewDate.getMonth(), root.viewDate.getDate())
          }
        }

        Text {
          visible: !root.showSettings && root.connected && root.eventsError !== ""
          width: parent.width
          text: root.eventsError
          textFormat: Text.PlainText
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        // ---- Not connected placeholder.
        Column {
          visible: !root.showSettings && !root.connected && root.settingsReady
          width: parent.width
          spacing: Style.space(10)
          topPadding: Style.space(24)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "No Nextcloud account configured"
            textFormat: Text.PlainText
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Set up"
            bordered: true
            foreground: root.contentForeground
            onClicked: root.openSettings()
          }
        }

        // ---- Month view.
        Column {
          visible: !root.showSettings && root.connected && root.viewMode === "month"
          width: parent.width
          spacing: Style.space(4)

          Row {
            width: parent.width
            Repeater {
              model: 7
              Text {
                required property int index
                width: parent.width / 7
                horizontalAlignment: Text.AlignHCenter
                text: Qt.locale().dayName((index + 1) % 7, Locale.ShortFormat)
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.monthGridWeeks

              Row {
                required property var modelData
                width: parent.width

                Repeater {
                  model: modelData.days

                  Rectangle {
                    id: dayCell
                    required property var modelData
                    width: content.width / 7
                    height: Style.space(52)
                    color: modelData.today ? Util.alpha(Color.accent, 0.14) : (dayMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent")
                    radius: Style.cornerRadius

                    Column {
                      anchors.centerIn: parent
                      spacing: Style.space(4)

                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: dayCell.modelData.day
                        textFormat: Text.PlainText
                        color: !dayCell.modelData.inMonth ? Qt.darker(root.contentForeground, 2.0) : (dayCell.modelData.today ? Color.accent : root.contentForeground)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: dayCell.modelData.today
                        horizontalAlignment: Text.AlignHCenter
                      }

                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Style.space(3)
                        readonly property int dotCount: Math.min(5, root.monthDots[dayCell.modelData.key] || 0)

                        Repeater {
                          model: parent.dotCount
                          Rectangle {
                            width: Style.space(5)
                            height: Style.space(5)
                            radius: width / 2
                            color: root.dotColor
                          }
                        }
                      }
                    }

                    MouseArea {
                      id: dayMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openDay(dayCell.modelData.year, dayCell.modelData.month, dayCell.modelData.day)
                    }
                  }
                }
              }
            }
          }
        }

        // ---- Week view: a table — columns are the days, rows are the
        // hours. Events are positioned/sized by time within their day
        // column; overlapping events split into side-by-side lanes
        // (Model.layoutDayEvents).
        Item {
          id: weekView
          visible: !root.showSettings && root.connected && root.viewMode === "week"
          width: parent.width
          height: parent.height - y

          readonly property real gutterWidth: Style.space(34)
          readonly property real hourHeight: Style.space(48)
          readonly property real dayColWidth: (weekView.width - weekView.gutterWidth) / 7
          readonly property var allDayItems: root.weekAllDayEvents()
          readonly property bool hasAllDay: allDayItems.length > 0
          readonly property color gridLineColor: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
          readonly property int visibleHours: Math.max(1, root.weekEndHour - root.weekStartHour)
          readonly property bool showsFullDay: root.weekStartHour === 0 && root.weekEndHour === 24

          function laneColor(evt) {
            return evt.recurring ? Util.alpha(Color.muted, 0.35) : Util.alpha(Color.accent, 0.30)
          }
          function laneBorderColor(evt) {
            return evt.recurring ? Util.alpha(Color.muted, 0.7) : Util.alpha(Color.accent, 0.6)
          }

          // ---- Day-of-week header, one cell per column.
          Row {
            id: weekHeaderRow
            anchors.top: parent.top
            anchors.left: parent.left
            width: parent.width
            height: Style.space(32)

            Item { width: weekView.gutterWidth; height: parent.height }

            Repeater {
              model: 7

              Item {
                id: dayHeaderCell
                required property int index
                readonly property date date: root.weekDayDate(index)
                readonly property bool isToday: Model.keyForDate(date) === root.todayKey
                width: weekView.dayColWidth
                height: parent.height

                Rectangle {
                  visible: dayHeaderCell.isToday
                  anchors.fill: parent
                  anchors.margins: Style.space(2)
                  radius: Style.cornerRadius
                  color: Util.alpha(Color.accent, 0.14)
                }

                Column {
                  anchors.centerIn: parent
                  spacing: 0

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.locale().dayName(dayHeaderCell.date.getDay(), Locale.ShortFormat)
                    textFormat: Text.PlainText
                    color: dayHeaderCell.isToday ? Color.accent : Qt.darker(root.contentForeground, 1.3)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: dayHeaderCell.date.getDate()
                    textFormat: Text.PlainText
                    color: dayHeaderCell.isToday ? Color.accent : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: dayHeaderCell.isToday
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openDay(dayHeaderCell.date.getFullYear(), dayHeaderCell.date.getMonth(), dayHeaderCell.date.getDate())
                }
              }
            }
          }

          PanelSeparator {
            anchors.top: weekHeaderRow.bottom
            foreground: root.contentForeground
          }

          // ---- All-day strip, only present when the week actually has
          // any all-day events (birthdays, holidays, ...).
          Row {
            id: weekAllDayRow
            anchors.top: weekHeaderRow.bottom
            anchors.topMargin: 1
            anchors.left: parent.left
            width: parent.width
            height: weekView.hasAllDay ? Style.space(24) : 0
            visible: weekView.hasAllDay
            clip: true

            Item { width: weekView.gutterWidth; height: parent.height }

            Repeater {
              model: 7

              Item {
                id: allDayCell
                required property int index
                width: weekView.dayColWidth
                height: parent.height

                Column {
                  anchors.fill: parent
                  anchors.margins: 1
                  spacing: 1

                  Repeater {
                    model: weekView.allDayItems.filter(function(it) { return it.dayIndex === allDayCell.index })

                    Rectangle {
                      required property var modelData
                      width: parent.width
                      height: Style.space(15)
                      radius: 2
                      color: weekView.laneColor(modelData.event)
                      border.width: 1
                      border.color: weekView.laneBorderColor(modelData.event)

                      Text {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(3)
                        anchors.rightMargin: Style.space(3)
                        verticalAlignment: Text.AlignVCenter
                        textFormat: Text.PlainText
                        text: modelData.event.summary
                        elide: Text.ElideRight
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption * 0.85
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openEditorForEvent(modelData.event)
                      }
                    }
                  }
                }
              }
            }
          }

          // ---- Scrollable hour grid.
          Flickable {
            id: weekGridFlick
            anchors.top: weekAllDayRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            contentWidth: width
            contentHeight: weekView.visibleHours * weekView.hourHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            // A narrowed range is already the meaningful window, so it opens
            // at the top; the full 24h grid still opens scrolled to a
            // reasonable business-hours start.
            Component.onCompleted: contentY = weekView.showsFullDay ? Math.max(0, 7 * weekView.hourHeight - Style.space(10)) : 0

            Row {
              width: weekGridFlick.width
              height: weekView.visibleHours * weekView.hourHeight

              Column {
                id: gutterCol
                width: weekView.gutterWidth
                height: parent.height

                Repeater {
                  model: weekView.visibleHours

                  Item {
                    required property int index
                    readonly property int hour: root.weekStartHour + index
                    width: gutterCol.width
                    height: weekView.hourHeight

                    Text {
                      anchors.top: parent.top
                      anchors.topMargin: -Style.space(6)
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(4)
                      textFormat: Text.PlainText
                      text: (parent.hour < 10 ? "0" : "") + parent.hour + ":00"
                      color: Qt.darker(root.contentForeground, 1.6)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption * 0.85
                    }
                  }
                }
              }

              Repeater {
                model: 7

                Item {
                  id: dayCol
                  required property int index
                  readonly property date date: root.weekDayDate(index)
                  readonly property date dayStart: new Date(dayCol.date.getFullYear(), dayCol.date.getMonth(), dayCol.date.getDate(), root.weekStartHour, 0, 0, 0)
                  readonly property date dayEnd: new Date(dayCol.date.getFullYear(), dayCol.date.getMonth(), dayCol.date.getDate(), root.weekEndHour, 0, 0, 0)
                  readonly property var laidOut: root.weekTimedLayout(index)
                  width: weekView.dayColWidth
                  height: parent.height

                  Repeater {
                    model: weekView.visibleHours
                    Rectangle {
                      required property int index
                      width: dayCol.width
                      height: 1
                      y: index * weekView.hourHeight
                      color: weekView.gridLineColor
                    }
                  }

                  Rectangle {
                    anchors.right: parent.right
                    width: 1
                    height: parent.height
                    color: weekView.gridLineColor
                  }

                  Rectangle {
                    visible: Model.keyForDate(dayCol.date) === root.todayKey
                      && root.today.getTime() >= dayCol.dayStart.getTime() && root.today.getTime() < dayCol.dayEnd.getTime()
                    y: Model.hourOfDay(root.today, dayCol.dayStart, dayCol.dayEnd) * weekView.hourHeight
                    width: parent.width
                    height: Style.space(2)
                    color: root.bar ? root.bar.urgent : Color.urgent
                  }

                  Repeater {
                    model: dayCol.laidOut

                    Rectangle {
                      id: evBlock
                      required property var modelData
                      readonly property real topPx: Model.hourOfDay(modelData.start, dayCol.dayStart, dayCol.dayEnd) * weekView.hourHeight
                      readonly property real endPx: Model.hourOfDay(modelData.end, dayCol.dayStart, dayCol.dayEnd) * weekView.hourHeight
                      x: modelData.col * (dayCol.width / modelData.cols)
                      y: evBlock.topPx
                      width: Math.max(Style.space(4), dayCol.width / modelData.cols - 1)
                      height: Math.max(Style.space(16), evBlock.endPx - evBlock.topPx)
                      radius: 3
                      clip: true
                      color: weekView.laneColor(evBlock.modelData.event)
                      border.width: 1
                      border.color: weekView.laneBorderColor(evBlock.modelData.event)

                      Text {
                        anchors.fill: parent
                        anchors.margins: 2
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                        elide: Text.ElideRight
                        maximumLineCount: 3
                        text: Model.formatHM(evBlock.modelData.start) + " " + evBlock.modelData.event.summary
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption * 0.9
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openEditorForEvent(evBlock.modelData.event)
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ---- Day view: full agenda with per-event edit pencil.
        Flickable {
          visible: !root.showSettings && root.connected && root.viewMode === "day"
          width: parent.width
          height: parent.height - y
          contentWidth: width
          contentHeight: dayColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: dayColumn
            width: parent.width
            spacing: Style.space(6)

            readonly property var dayEvents: root.eventsForDay(root.viewDate.getFullYear(), root.viewDate.getMonth(), root.viewDate.getDate())

            Text {
              visible: dayColumn.dayEvents.length === 0
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(20)
              text: "No events this day"
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.6)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: dayColumn.dayEvents

              Item {
                id: eventRow
                required property var modelData
                width: dayColumn.width
                height: Math.max(Style.space(40), eventTexts.implicitHeight + Style.space(10))

                Rectangle {
                  anchors.fill: parent
                  color: rowMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"
                  radius: Style.cornerRadius
                }

                Column {
                  id: eventTexts
                  anchors.left: parent.left
                  anchors.right: editBtn.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: eventRow.modelData.allDay ? "All day" : (Model.formatHM(eventRow.modelData.start) + " – " + Model.formatHM(eventRow.modelData.end))
                    textFormat: Text.PlainText
                    color: Qt.darker(root.contentForeground, 1.2)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    width: parent.width
                    text: eventRow.modelData.summary + (eventRow.modelData.location ? "  ·  " + eventRow.modelData.location : "")
                    textFormat: Text.PlainText
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    wrapMode: Text.WordWrap
                  }
                  Text {
                    visible: eventRow.modelData.description !== ""
                    width: parent.width
                    text: eventRow.modelData.description
                    textFormat: Text.PlainText
                    color: Qt.darker(root.contentForeground, 1.3)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }
                }

                PanelActionButton {
                  id: editBtn
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.rightMargin: Style.space(4)
                  iconText: "✎"
                  tooltipText: "Edit"
                  foreground: root.contentForeground
                  onClicked: root.openEditorForEvent(eventRow.modelData)
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  anchors.rightMargin: editBtn.width
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openEditorForEvent(eventRow.modelData)
                }
              }
            }
          }
        }

        // ---- Settings form.
        Flickable {
          visible: root.showSettings
          width: parent.width
          height: parent.height - y
          contentWidth: width
          contentHeight: settingsColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: settingsColumn
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: "Use an app password generated in Settings → Security on your Nextcloud instance. It is stored only in the system keyring."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.connected
              width: parent.width
              text: "Connected as " + root.username + " at " + root.serverUrl
                + "\nCalendars: " + root.calendars.map(function(c) { return c.displayName }).join(", ")
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              PanelSectionHeader { text: "Server URL"; foreground: root.contentForeground }
              TextField {
                width: parent.width
                placeholderText: "https://cloud.example.com"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                text: root.formServerUrl
                onTextChanged: root.formServerUrl = text
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              PanelSectionHeader { text: "Username"; foreground: root.contentForeground }
              TextField {
                width: parent.width
                placeholderText: "username"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                text: root.formUsername
                onTextChanged: root.formUsername = text
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              PanelSectionHeader { text: "App password"; foreground: root.contentForeground }
              TextField {
                width: parent.width
                password: true
                placeholderText: "app password"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                text: root.formPassword
                onTextChanged: root.formPassword = text
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              PanelSectionHeader { text: "Your email (optional, used as meeting organizer)"; foreground: root.contentForeground }
              TextField {
                width: parent.width
                placeholderText: "you@example.com"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                text: root.formOrganizerEmail
                onTextChanged: { root.formOrganizerEmail = text; organizerSaveTimer.restart() }
                onEditingFinished: root.saveOrganizerEmail()
              }
            }

            Timer {
              id: organizerSaveTimer
              interval: 800
              onTriggered: root.saveOrganizerEmail()
            }

            Text {
              visible: root.formError !== ""
              width: parent.width
              text: root.formError
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.bar ? root.bar.urgent : Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.formStatus !== ""
              width: parent.width
              text: root.formStatus
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: root.formBusy ? "Connecting…" : "Connect"
                bordered: true
                foreground: root.contentForeground
                enabled: !root.formBusy
                onClicked: root.startConnect()
              }

              Button {
                visible: root.connected
                text: "Disconnect"
                bordered: true
                foreground: root.bar ? root.bar.urgent : Color.urgent
                onClicked: root.disconnectAccount()
              }
            }

            Column {
              visible: root.connected
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader { text: "Week view hours"; foreground: root.contentForeground }
              Text {
                width: parent.width
                text: "Which hours the Week grid shows. Pick 00–24 for the full day."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Qt.darker(root.contentForeground, 1.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Row {
                spacing: Style.space(16)

                NumberField {
                  label: "Start hour"
                  value: root.weekStartHour
                  from: 0
                  to: 23
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onModified: function(v) { root.setWeekHours(v, root.weekEndHour) }
                }
                NumberField {
                  label: "End hour"
                  value: root.weekEndHour
                  from: 1
                  to: 24
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onModified: function(v) { root.setWeekHours(root.weekStartHour, v) }
                }
              }
            }
          }
        }
      }

      // ---- Calendar footer: pick which calendar new events are created
      // in. Every connected calendar's events are always merged into the
      // day/week/month views — this only decides the target for creation.
      Flickable {
        id: calendarFooter
        visible: root.showFooter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.showFooter ? Style.space(28) : 0
        contentWidth: footerRow.implicitWidth
        contentHeight: height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.HorizontalFlick

        Row {
          id: footerRow
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Repeater {
            model: root.calendars

            Button {
              required property var modelData
              text: modelData.displayName
              selected: root.activeCalendarHref === modelData.href
              bordered: true
              foreground: root.contentForeground
              tooltipText: "Create new events in " + modelData.displayName
              onClicked: root.setActiveCalendar(modelData.href)
            }
          }
        }
      }
    }

    // ---- Event editor overlay.
    Rectangle {
      anchors.fill: parent
      visible: root.editorOpen
      color: Util.alpha(Color.background, 0.78)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Flickable {
        anchors.fill: parent
        anchors.margins: Style.space(16)
        contentWidth: width
        contentHeight: editorColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: editorColumn
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: root.editorMode === "create" ? "New event" : "Edit event"
            textFormat: Text.PlainText
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            visible: root.editorCalendarName !== ""
            text: "Calendar: " + root.editorCalendarName
            textFormat: Text.PlainText
            color: Qt.darker(root.contentForeground, 1.3)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.editorRecurring
            width: parent.width
            text: "This is a recurring event — editing or deleting affects the whole series."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            PanelSectionHeader { text: "Title"; foreground: root.contentForeground }
            TextField {
              width: parent.width
              placeholderText: "Title"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              text: root.editorTitle
              onTextChanged: root.editorTitle = text
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Column {
              spacing: Style.space(2)

              PanelSectionHeader { text: "Date"; foreground: root.contentForeground }
              TextField {
                width: Style.space(140)
                placeholderText: "YYYY-MM-DD"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                text: root.editorDateText
                onTextChanged: root.editorDateText = text
              }
            }

            Row {
              spacing: Style.space(6)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(5)

              ToggleSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: root.editorAllDay
                onToggled: root.editorAllDay = !root.editorAllDay
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "All day"
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          Row {
            visible: !root.editorAllDay
            width: parent.width
            spacing: Style.space(10)

            Column {
              spacing: Style.space(2)
              PanelSectionHeader { text: "Start"; foreground: root.contentForeground }
              TextField {
                width: Style.space(90)
                placeholderText: "HH:MM"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                text: root.editorStartText
                onTextChanged: root.editorStartText = text
              }
            }
            Text {
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(7)
              text: "to"
              textFormat: Text.PlainText
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Column {
              spacing: Style.space(2)
              PanelSectionHeader { text: "End"; foreground: root.contentForeground }
              TextField {
                width: Style.space(90)
                placeholderText: "HH:MM"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                text: root.editorEndText
                onTextChanged: root.editorEndText = text
              }
            }
          }

          Column {
            visible: !root.editorAllDay
            width: parent.width
            spacing: Style.space(2)

            PanelSectionHeader { text: "Timezone"; foreground: root.contentForeground }
            Dropdown {
              width: Style.space(300)
              showLabel: false
              value: root.editorTimezoneId
              options: root.timezoneDropdownOptions
              foreground: root.contentForeground
              background: Color.popups.background
              onChanged: function(v) { root.retimezone(v) }
            }
            Text {
              width: parent.width
              text: "Fixed UTC offset — does not auto-adjust for daylight saving time."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(root.contentForeground, 1.6)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption * 0.9
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            PanelSectionHeader { text: "Location"; foreground: root.contentForeground }
            TextField {
              width: parent.width
              placeholderText: "Location (optional)"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              text: root.editorLocation
              onTextChanged: root.editorLocation = text
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            PanelSectionHeader { text: "Description"; foreground: root.contentForeground }
            BorderSurface {
              width: parent.width
              height: Style.space(80)
              radius: Style.cornerRadius
              borderSpec: Border.controlSpec("normal", root.contentForeground, Color.accent)

              TextArea {
                id: descArea
                anchors.fill: parent
                anchors.margins: Style.space(6)
                wrapMode: TextArea.Wrap
                placeholderText: "Description (optional)"
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                color: root.contentForeground
                selectionColor: Style.selectionFillFor(root.contentForeground, Color.accent)
                selectedTextColor: root.contentForeground
                background: Item {}
                text: root.editorDescription
                onTextChanged: root.editorDescription = text
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader { text: "Guests"; foreground: root.contentForeground }

            Row {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: attendeeNameField
                width: Style.space(150)
                placeholderText: "Name (optional)"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                text: root.attendeeNameInput
                onTextChanged: root.attendeeNameInput = text
                Keys.onReturnPressed: attendeeEmailField.forceActiveFocus()
              }
              TextField {
                id: attendeeEmailField
                width: Math.max(Style.space(80), parent.width - attendeeNameField.width - addAttendeeBtn.width - Style.space(12))
                placeholderText: "Email"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                text: root.attendeeEmailInput
                onTextChanged: root.attendeeEmailInput = text
                Keys.onReturnPressed: root.addAttendee()
              }
              PanelActionButton {
                id: addAttendeeBtn
                anchors.verticalCenter: parent.verticalCenter
                iconText: "+"
                tooltipText: "Add guest"
                foreground: root.contentForeground
                onClicked: root.addAttendee()
              }
            }

            Text {
              visible: root.attendeeError !== ""
              width: parent.width
              text: root.attendeeError
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.bar ? root.bar.urgent : Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.editorOrganizerEmail !== "" && root.editorAttendees.length > 0
              width: parent.width
              text: "Organizer: " + (root.editorOrganizerName !== "" ? root.editorOrganizerName + " <" + root.editorOrganizerEmail + ">" : root.editorOrganizerEmail)
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Column {
              width: parent.width
              spacing: Style.space(3)

              Repeater {
                model: root.editorAttendees

                Item {
                  id: attendeeRow
                  required property var modelData
                  width: parent.width
                  height: Style.space(24)

                  Row {
                    anchors.left: parent.left
                    anchors.right: removeAttendeeBtn.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.rightMargin: Style.space(4)
                    spacing: Style.space(6)

                    Text {
                      width: parent.width - statusBadge.width - Style.space(6)
                      text: attendeeRow.modelData.name ? (attendeeRow.modelData.name + " <" + attendeeRow.modelData.email + ">") : attendeeRow.modelData.email
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Rectangle {
                      id: statusBadge
                      anchors.verticalCenter: parent.verticalCenter
                      width: statusText.implicitWidth + Style.space(10)
                      height: Style.space(16)
                      radius: height / 2
                      color: Util.alpha(root.partstatColor(attendeeRow.modelData.partstat), 0.18)
                      border.width: 1
                      border.color: Util.alpha(root.partstatColor(attendeeRow.modelData.partstat), 0.6)

                      Text {
                        id: statusText
                        anchors.centerIn: parent
                        text: root.partstatLabel(attendeeRow.modelData.partstat)
                        textFormat: Text.PlainText
                        color: root.partstatColor(attendeeRow.modelData.partstat)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption * 0.85
                      }
                    }
                  }

                  PanelActionButton {
                    id: removeAttendeeBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "✕"
                    tooltipText: "Remove"
                    foreground: root.contentForeground
                    onClicked: root.removeAttendee(attendeeRow.modelData.email)
                  }
                }
              }
            }
          }

          Text {
            visible: root.editorError !== ""
            width: parent.width
            text: root.editorError
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.space(8)

            Button {
              text: "Cancel"
              bordered: true
              foreground: root.contentForeground
              onClicked: root.closeEditor()
            }
            Button {
              visible: root.editorMode === "edit"
              text: "Delete"
              bordered: true
              foreground: root.bar ? root.bar.urgent : Color.urgent
              onClicked: root.requestDelete()
            }
            Button {
              text: root.editorSaving ? "Saving…" : "Save"
              selected: true
              bordered: true
              foreground: root.contentForeground
              enabled: !root.editorSaving
              onClicked: root.saveEditor()
            }
          }
        }
      }
    }

    ConfirmDialog {
      anchors.fill: parent
      opened: root.confirmDeleteOpen
      message: root.editorRecurring ? "Delete the entire recurring series for this event?" : "Delete this event?"
      cancelText: "Cancel"
      confirmText: "Delete"
      foreground: root.contentForeground
      onCanceled: root.confirmDeleteOpen = false
      onConfirmed: root.confirmDelete()
    }
  }
}
