# Nextcloud Calendar for Omarchy

A bar plugin for [Omarchy](https://omarchy.org/) that shows your next Nextcloud
Calendar appointment in the bar and lets you browse and edit your calendar
(day / week / month) without leaving Hyprland.

## Features

- Bar pill shows the time of your next upcoming appointment.
- Click to open a popup with **Day**, **Week**, and **Month** views.
  - Month: a grid with a small dot under each day that has events.
  - Week: a proper table — days as columns, hours as rows, overlapping
    events split into side-by-side lanes. The visible hour range is
    configurable in Settings.
  - Day: a full agenda with time, title, location, and description.
- Create, edit, and delete events, including:
  - Guests (add/remove attendees by email, see their Accepted / Declined /
    Tentative / Pending status).
  - A fixed-UTC-offset timezone picker per event.
  - All-day events.
- All of the account's calendars are supported at once — a footer in the
  popup lets you pick which calendar new events are created in.
- Talks to your server over CalDAV (works with stock Nextcloud Calendar,
  no server-side app required).

## Requirements

- A Nextcloud instance with the Calendar app enabled.
- `curl` and `secret-tool` (part of `libsecret`) on the system, plus a
  running secret-service provider (e.g. `gnome-keyring`) — these are
  present on a default Omarchy install.

## Install

```bash
omarchy plugin add https://github.com/Giuliano-sn/omarchy-nextcloud-calendar-plugin.git --enable
```

Or through the menu: `omarchy menu plugin add`.

Click the calendar icon in the bar, open the gear icon, and enter:

- your Nextcloud server URL,
- your username,
- an **app password** generated in Nextcloud under
  **Settings → Security → App passwords** (do not use your account
  password).

The app password is stored only in the system keyring via `secret-tool`,
never written to disk in plaintext. Only the server URL, username, and the
list of discovered calendars are saved, in
`~/.local/state/omarchy/settings/nextcloud-calendar.json`.

## Remove

```bash
omarchy plugin remove giuliano.nextcloud-calendar
```

This removes the plugin's bar entry and files. It does not delete the saved
settings file or the keyring entry; to remove those too:

```bash
rm -f ~/.local/state/omarchy/settings/nextcloud-calendar.json
secret-tool clear service omarchy-nextcloud-calendar
```

## Notes on the timezone picker

The QML runtime this plugin runs under has no `Intl`/ICU support, so there
is no way to resolve real IANA timezone rules (including daylight saving
time). The timezone picker offers a fixed list of UTC offsets instead —
pick whichever one matches your current local time. This is stated in the
UI as well.

## License

MIT — see [LICENSE](LICENSE).
