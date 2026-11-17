import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "jd.nba"
  // Open from a keybind with: omarchy-shell shell toggle jd.nba
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var rawGames: []
  readonly property var games: Model.sortGames(rawGames, team)
  property bool loading: false

  // Home team: pinned to the top here and used by Service.qml for reminders.
  property string team: ""
  property bool picking: false

  property FileView settingsFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/jd.nba.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.team = Model.parseSettings(text()).team
    onLoadFailed: root.team = ""
    onFileChanged: reload()
  }

  function chooseTeam(abbr) {
    var t = Model.isTeam(abbr) ? abbr : ""
    root.team = t
    root.picking = false
    settingsFile.setText(JSON.stringify({ team: t }) + "\n")
  }

  // ---- Game detail: click a game to see team and player stats.
  property string detailId: ""
  property string detailSide: "away"
  property var detail: null
  property bool detailLoading: false
  property bool detailFailed: false
  readonly property var detailGame: {
    if (detailId === "") return null
    for (var i = 0; i < rawGames.length; i++) if (rawGames[i].id === detailId) return rawGames[i]
    return null
  }

  function openDetail(game) {
    if (!Model.isGameId(game.id)) return
    root.picking = false
    root.detail = null
    root.detailFailed = false
    // Start on the home team's box score when it's in this game.
    root.detailSide = root.team !== "" && game.home.abbr === root.team ? "home" : "away"
    root.detailId = game.id
    fetchDetail()
  }

  function closeDetail() {
    root.detailId = ""
    root.detail = null
  }

  function fetchDetail() {
    if (!Model.isGameId(detailId) || detailProc.running) return
    detailProc.forId = detailId
    root.detailLoading = true
    detailProc.running = true
  }

  Process {
    id: detailProc
    property string forId: ""
    command: ["curl", "-fsS", "--max-time", "15", "--max-filesize", "4000000",
              "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=" + forId]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.detailLoading = false
        if (detailProc.forId !== root.detailId) return
        try {
          root.detail = Model.parseSummary(String(text || ""))
          root.detailFailed = false
        } catch (e) {
          root.detailFailed = true
        }
      }
    }
    onExited: function(code) {
      if (code !== 0) {
        root.detailLoading = false
        root.detailFailed = true
      }
    }
  }

  // Keep a live game's box score current while it's on screen.
  Timer {
    interval: 30000
    running: root.opened && root.detailGame !== null && root.detailGame.state === "in"
    repeat: true
    onTriggered: root.fetchDetail()
  }

  // Home team's schedule, for the "next game" card on days it doesn't play.
  property var teamSchedule: []
  property double scheduleFetchedAt: 0
  readonly property var nextGame: root.team !== "" && !Model.playsToday(root.rawGames, root.team)
    ? Model.nextGame(root.teamSchedule, root.updatedAt || Date.now()) : null

  onTeamChanged: {
    teamSchedule = []
    scheduleFetchedAt = 0
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
          root.teamSchedule = Model.parseSchedule(String(text || ""), root.team)
          root.scheduleFetchedAt = Date.now()
        } catch (e) {
          // Keep the previous schedule.
        }
      }
    }
  }

  function dayText(ms) {
    var days = Model.daysUntil(ms, Date.now())
    if (days === 0) return strings.t("today")
    if (days === 1) return strings.t("tomorrow")
    var d = new Date(ms)
    if (days < 7) return root.locale.dayName(d.getDay(), Locale.LongFormat)
    return d.toLocaleDateString(root.locale, Locale.ShortFormat)
  }
  property bool failed: false
  property double updatedAt: 0
  readonly property int liveCount: Model.liveCount(games)

  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string family: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property var locale: Qt.locale(Commons.I18n.formatLocale)

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function open() {
    root.controller.show()
    root.refresh()
  }

  function close() {
    root.picking = false
    root.closeDetail()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() {
    if (root.team !== "" && Date.now() - root.scheduleFetchedAt > 3600000) fetchSchedule()
    if (fetchProc.running) return
    root.loading = true
    fetchProc.running = true
  }

  function timeText(ms) {
    return ms > 0 ? new Date(ms).toLocaleTimeString(root.locale, Locale.ShortFormat) : ""
  }

  function statusText(game) {
    if (game.state === "pre") return timeText(game.start)
    return game.detail
  }

  Process {
    id: fetchProc
    command: ["curl", "-fsS", "--max-time", "10", "--max-filesize", "4000000",
              "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        var raw = String(text || "").trim()
        if (!raw) {
          root.failed = true
          return
        }
        try {
          root.rawGames = Model.parseScoreboard(raw)
          root.failed = false
          root.updatedAt = Date.now()
        } catch (e) {
          // Keep the last good scoreboard on screen.
          root.failed = true
        }
      }
    }
    onExited: function(code) {
      if (code !== 0) {
        root.loading = false
        root.failed = true
      }
    }
  }

  // Poll every 30s while a game is live (or the panel is open), else every 5 min.
  Timer {
    interval: root.liveCount > 0 || root.opened ? 30000 : 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onReturnRequested: root.refresh()
      onCloseRequested: {
        if (root.picking) root.picking = false
        else if (root.detailId !== "") root.closeDetail()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(10)

          // ---- Header
          Item {
            width: parent.width
            height: Math.max(titleText.implicitHeight, summaryText.implicitHeight)

            Text {
              id: titleText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "󰠆  " + strings.t("title")
              color: root.fg
              font.family: root.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            // Home-team chip: opens the picker.
            Rectangle {
              id: teamChip
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: chipText.implicitWidth + Style.space(16)
              height: chipText.implicitHeight + Style.space(8)
              radius: height / 2
              color: chipHover.hovered || root.picking
                ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
                : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
              border.width: root.team !== "" ? 1 : 0
              border.color: Commons.Color.accent

              Text {
                id: chipText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.team !== "" ? "★ " + root.team : "☆ " + strings.t("pickTeam")
                color: root.team !== "" ? Commons.Color.accent : root.fg
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
                font.bold: root.team !== ""
              }
              HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: { root.closeDetail(); root.picking = !root.picking } }
            }

            Text {
              id: summaryText
              textFormat: Text.PlainText
              anchors.right: teamChip.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: {
                var parts = []
                if (root.games.length > 0)
                  parts.push(strings.tn("games", root.games.length).arg(Commons.I18n.formatNumber(root.games.length)))
                if (root.liveCount > 0)
                  parts.push(strings.tn("live", root.liveCount).arg(Commons.I18n.formatNumber(root.liveCount)))
                return parts.join(" · ")
              }
              color: root.liveCount > 0 ? Commons.Color.urgent : root.dim
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          PanelSeparator { width: parent.width }

          // ---- Home-team picker
          Column {
            visible: root.picking
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: strings.t("pickTeamHint")
              color: root.dim
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
            }

            Grid {
              id: teamGrid
              columns: 6
              spacing: Style.space(6)
              readonly property real cell: (parent.width - spacing * (columns - 1)) / columns

              Repeater {
                model: Model.TEAMS.concat([{ abbr: "", name: "" }])

                delegate: Rectangle {
                  required property var modelData
                  readonly property bool selected: modelData.abbr === root.team
                  width: teamGrid.cell
                  height: cellText.implicitHeight + Style.space(10)
                  radius: Style.space(6)
                  color: selected ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.2)
                       : cellHover.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
                       : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
                  border.width: selected ? 1 : 0
                  border.color: Commons.Color.accent

                  Text {
                    id: cellText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: modelData.abbr !== "" ? modelData.abbr : strings.t("noTeam")
                    color: selected ? Commons.Color.accent : root.fg
                    font.family: root.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: selected
                  }
                  HoverHandler { id: cellHover; cursorShape: Qt.PointingHandCursor }
                  TapHandler { onTapped: root.chooseTeam(modelData.abbr) }
                  PanelToolTip { visible: cellHover.hovered && modelData.name !== ""; text: modelData.name }
                }
              }
            }

            PanelSeparator { width: parent.width }
          }

          // ---- Home team's next game, when it isn't playing today
          Item {
            id: nextCard
            visible: root.nextGame !== null && root.detailId === ""
            width: parent.width
            height: visible ? nextColumn.implicitHeight + Style.space(16) : 0

            Rectangle {
              anchors.fill: parent
              radius: Style.space(6)
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
              border.width: 1
              border.color: Commons.Color.accent
            }

            Column {
              id: nextColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(3)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: strings.t("nextGame").arg(Model.teamName(root.team))
                color: Commons.Color.accent
                font.family: root.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Item {
                width: parent.width
                height: matchupText.implicitHeight

                Text {
                  id: matchupText
                  textFormat: Text.PlainText
                  text: {
                    var g = root.nextGame
                    if (!g) return ""
                    return root.team + "  " + (g.home ? strings.t("vs") : strings.t("at")).arg(g.opponent)
                  }
                  color: root.fg
                  font.family: root.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  anchors.right: parent.right
                  anchors.baseline: matchupText.baseline
                  textFormat: Text.PlainText
                  text: root.nextGame ? root.dayText(root.nextGame.start) + " · " + root.timeText(root.nextGame.start) : ""
                  color: root.fg
                  font.family: root.family
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Text {
                width: parent.width
                visible: text !== ""
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: root.nextGame ? root.nextGame.broadcast : ""
                color: root.dim
                font.family: root.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Empty / loading / error states
          Text {
            visible: root.games.length === 0 && root.detailId === ""
            width: parent.width
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(12)
            bottomPadding: Style.space(12)
            text: root.failed ? strings.t("error")
                 : root.updatedAt === 0 ? strings.t("loading")
                 : strings.t("noGames")
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.body
          }

          // ---- Games
          Repeater {
            model: root.games

            delegate: Item {
              id: gameRow
              required property var modelData
              readonly property string lead: Model.leader(modelData)
              readonly property bool live: modelData.state === "in"
              readonly property bool favorite: Model.involves(modelData, root.team)

              visible: root.detailId === ""
              width: column.width
              height: teams.implicitHeight + Style.space(8)

              HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.openDetail(gameRow.modelData) }

              Rectangle {
                anchors.fill: parent
                radius: Style.space(6)
                color: rowHover.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
                     : gameRow.live || gameRow.favorite ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent"
                border.width: gameRow.favorite ? 1 : 0
                border.color: Commons.Color.accent
              }

              Column {
                id: teams
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * 0.62
                spacing: Style.space(2)

                Repeater {
                  model: [
                    { side: "away", t: gameRow.modelData.away },
                    { side: "home", t: gameRow.modelData.home }
                  ]

                  delegate: Item {
                    required property var modelData
                    readonly property bool ahead: gameRow.lead === modelData.side
                    readonly property bool trailing: gameRow.lead !== "" && !ahead
                    width: teams.width
                    height: nameText.implicitHeight

                    Text {
                      id: abbrText
                      textFormat: Text.PlainText
                      width: Style.space(40)
                      text: modelData.t.abbr
                      color: trailing ? root.dim : root.fg
                      font.family: root.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                    Text {
                      id: nameText
                      textFormat: Text.PlainText
                      anchors.left: abbrText.right
                      text: modelData.t.name
                      color: trailing ? root.dim : root.fg
                      font.family: root.family
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      textFormat: Text.PlainText
                      anchors.left: nameText.right
                      anchors.leftMargin: Style.space(6)
                      anchors.baseline: nameText.baseline
                      text: modelData.t.record
                      color: root.dim
                      font.family: root.family
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      textFormat: Text.PlainText
                      anchors.right: parent.right
                      text: modelData.t.score
                      color: trailing ? root.dim : root.fg
                      font.family: root.family
                      font.pixelSize: Style.font.body
                      font.bold: ahead
                    }
                  }
                }
              }

              Column {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * 0.32
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                  text: (gameRow.live ? "● " : "") + root.statusText(gameRow.modelData)
                  color: gameRow.live ? Commons.Color.urgent : root.fg
                  font.family: root.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: gameRow.live
                }
                Text {
                  width: parent.width
                  visible: text !== ""
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                  text: gameRow.modelData.broadcast
                  color: root.dim
                  font.family: root.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---- Game detail
          Column {
            id: detailView
            visible: root.detailId !== ""
            width: parent.width
            spacing: Style.space(10)

            readonly property var g: root.detailGame
            readonly property var side: root.detail ? root.detail[root.detailSide] : null
            readonly property real numWidth: Style.space(28)

            // Back + status
            Item {
              width: parent.width
              height: backText.implicitHeight

              Text {
                id: backText
                textFormat: Text.PlainText
                text: "‹ " + strings.t("back")
                color: backHover.hovered ? root.fg : root.dim
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
                HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.closeDetail() }
              }
              Text {
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: detailView.g ? (detailView.g.state === "in" ? "● " : "") + root.statusText(detailView.g) : ""
                color: detailView.g && detailView.g.state === "in" ? Commons.Color.urgent : root.fg
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
                font.bold: detailView.g !== null && detailView.g.state === "in"
              }
            }

            // Scoreline
            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: {
                var g = detailView.g
                if (!g) return ""
                if (g.state === "pre") return g.away.name + "  @  " + g.home.name
                return g.away.abbr + "  " + g.away.score + "  –  " + g.home.score + "  " + g.home.abbr
              }
              color: root.fg
              font.family: root.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            // Loading / pregame / error
            Text {
              visible: !root.detail || !root.detail.hasStats
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              topPadding: Style.space(8)
              bottomPadding: Style.space(8)
              text: root.detailFailed ? strings.t("error")
                  : !root.detail ? strings.t("loading")
                  : strings.t("noStatsYet")
              color: root.dim
              font.family: root.family
              font.pixelSize: Style.font.body
            }

            // Team stats: away | label | home
            Column {
              visible: root.detail !== null && root.detail.hasStats
              width: parent.width
              spacing: Style.space(3)

              PanelSectionHeader { foreground: root.fg; fontFamily: root.family; text: strings.t("teamStats") }

              Repeater {
                model: Model.teamStatRows(root.detail)
                delegate: Item {
                  required property var modelData
                  width: detailView.width
                  height: statLabel.implicitHeight
                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    textFormat: Text.PlainText
                    text: modelData.away
                    color: root.fg
                    font.family: root.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    id: statLabel
                    anchors.horizontalCenter: parent.horizontalCenter
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: root.dim
                    font.family: root.family
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(8)
                    textFormat: Text.PlainText
                    text: modelData.home
                    color: root.fg
                    font.family: root.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }

            PanelSeparator {
              visible: root.detail !== null && root.detail.hasStats
              width: parent.width
            }

            // Player stats, one team at a time
            Column {
              visible: root.detail !== null && root.detail.hasStats
              width: parent.width
              spacing: Style.space(3)

              Item {
                width: parent.width
                height: sideTabs.implicitHeight

                PanelSectionHeader { foreground: root.fg; fontFamily: root.family;
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("playerStats")
                }

                Row {
                  id: sideTabs
                  anchors.right: parent.right
                  spacing: Style.space(6)

                  Repeater {
                    model: ["away", "home"]
                    delegate: Rectangle {
                      required property string modelData
                      readonly property bool selected: root.detailSide === modelData
                      width: tabText.implicitWidth + Style.space(16)
                      height: tabText.implicitHeight + Style.space(6)
                      radius: height / 2
                      color: selected ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.2)
                           : tabHover.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
                           : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
                      border.width: selected ? 1 : 0
                      border.color: Commons.Color.accent
                      Text {
                        id: tabText
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: root.detail ? root.detail[modelData].abbr : ""
                        color: selected ? Commons.Color.accent : root.fg
                        font.family: root.family
                        font.pixelSize: Style.font.bodySmall
                        font.bold: selected
                      }
                      HoverHandler { id: tabHover; cursorShape: Qt.PointingHandCursor }
                      TapHandler { onTapped: root.detailSide = modelData }
                    }
                  }
                }
              }

              // Column headings + one row per player
              Repeater {
                model: detailView.side
                  ? [{ name: "", starter: true, values: Model.PLAYER_COLUMNS.map(function(c) { return c[1] }), heading: true }]
                      .concat(detailView.side.players)
                  : []

                delegate: Row {
                  required property var modelData
                  readonly property bool heading: modelData.heading === true
                  width: detailView.width
                  leftPadding: Style.space(8)
                  rightPadding: Style.space(8)

                  Text {
                    width: detailView.width - Style.space(16) - detailView.numWidth * Model.playerColumnUnits()
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: modelData.name
                    color: modelData.starter ? root.fg : root.dim
                    font.family: root.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  Repeater {
                    model: modelData.values
                    delegate: Text {
                      required property string modelData
                      required property int index
                      width: Model.PLAYER_COLUMNS[index][2] ? detailView.numWidth * 1.5 : detailView.numWidth
                      horizontalAlignment: Text.AlignRight
                      textFormat: Text.PlainText
                      text: modelData
                      color: heading ? root.dim : root.fg
                      font.family: root.family
                      font.pixelSize: heading ? Style.font.caption : Style.font.bodySmall
                      font.bold: !heading && index === 1
                    }
                  }
                }
              }
            }
          }

          // ---- Footer
          Text {
            visible: root.updatedAt > 0 && root.detailId === ""
            width: parent.width
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignRight
            text: strings.t("updated").arg(root.timeText(root.updatedAt)) + (root.failed ? " · " + strings.t("error") : "")
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
