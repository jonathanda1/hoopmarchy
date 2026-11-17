import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Background service (one instance, unlike the per-monitor bar widget) that
// reminds about the chosen home team's games: at 10:00 local on game day and
// an hour before tip-off.
Item {
  id: root

  property var shell: null

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  property string team: ""
  property var schedule: []
  property var sent: ({})
  property bool sentLoaded: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Written by the panel's team picker.
  FileView {
    id: settingsFile
    path: root.stateDir + "/jd.nba.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.team = Model.parseSettings(text()).team
    onLoadFailed: root.team = ""
    onFileChanged: reload()
  }

  // Which reminders have gone out, so a shell restart doesn't repeat them.
  FileView {
    id: sentFile
    path: root.stateDir + "/jd.nba-reminders.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var parsed = {}
      try { parsed = JSON.parse(text()) } catch (e) { parsed = {} }
      root.sent = Model.pruneSent(Util.isPlainObject(parsed) ? parsed : {}, Date.now())
      root.sentLoaded = true
      root.check()
    }
    onLoadFailed: {
      root.sent = {}
      root.sentLoaded = true
    }
  }

  onTeamChanged: {
    schedule = []
    fetchSchedule()
  }

  function fetchSchedule() {
    if (!Model.isTeam(team)) return
    if (scheduleProc.running) scheduleProc.running = false
    scheduleProc.forTeam = team
    scheduleProc.running = true
  }

  Process {
    id: scheduleProc
    property string forTeam: ""
    command: ["curl", "-fsS", "--max-time", "15", "--max-filesize", "4000000",
              "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/" + forTeam.toLowerCase() + "/schedule"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (scheduleProc.forTeam !== root.team) return
        try {
          root.schedule = Model.parseSchedule(String(text || ""), root.team)
          root.check()
        } catch (e) {
          // Keep the previous schedule; the hourly refresh tries again.
        }
      }
    }
  }

  // Schedule (and tip-off times) refresh hourly.
  Timer {
    interval: 3600000
    running: root.team !== ""
    repeat: true
    onTriggered: root.fetchSchedule()
  }

  Timer {
    interval: 30000
    running: root.team !== ""
    repeat: true
    onTriggered: root.check()
  }

  function timeText(ms) {
    return new Date(ms).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }

  function check() {
    if (!team || !sentLoaded || schedule.length === 0) return
    var now = Date.now()
    var due = Model.dueReminders(schedule, now, sent)
    if (due.length === 0) return

    var next = Model.pruneSent(sent, now)
    var us = Model.teamName(team)
    for (var i = 0; i < due.length; i++) {
      var r = due[i]
      var g = r.game
      var matchup = (g.home ? strings.t("vs") : strings.t("at")).arg(g.opponent)
      var details = [matchup, timeText(g.start)]
      if (g.broadcast) details.push(g.broadcast)
      var title = r.kind === "hour"
        ? (r.minutes >= 55 ? strings.t("tipoffHour").arg(us)
                           : strings.tn("tipoffMinutes", r.minutes).arg(us).arg(Commons.I18n.formatNumber(r.minutes)))
        : strings.t("gameToday").arg(us)
      notify(title, details.join(" · "))
      for (var k = 0; k < r.keys.length; k++) next[r.keys[k]] = g.start
    }
    sent = next
    sentFile.setText(JSON.stringify(next) + "\n")
  }

  function notify(title, body) {
    Util.execArgv(["omarchy-notification-send", "--app-name", "NBA Today", "-g", "󰠆", "-u", "normal", title, body])
  }
}
