// Parses ESPN's public NBA JSON (scoreboard and team schedule) into small,
// bounded structures, and decides which home-team reminders are due.
// All values are treated as untrusted: strings are length-capped, scores must
// be short digit runs, and only a fixed number of games is kept.

var MAX_GAMES = 30
var MAX_SCHEDULE = 120

// ESPN abbreviations, in the order shown by the team picker.
var TEAMS = [
  { abbr: "ATL", name: "Hawks" },        { abbr: "BOS", name: "Celtics" },
  { abbr: "BKN", name: "Nets" },         { abbr: "CHA", name: "Hornets" },
  { abbr: "CHI", name: "Bulls" },        { abbr: "CLE", name: "Cavaliers" },
  { abbr: "DAL", name: "Mavericks" },    { abbr: "DEN", name: "Nuggets" },
  { abbr: "DET", name: "Pistons" },      { abbr: "GS", name: "Warriors" },
  { abbr: "HOU", name: "Rockets" },      { abbr: "IND", name: "Pacers" },
  { abbr: "LAC", name: "Clippers" },     { abbr: "LAL", name: "Lakers" },
  { abbr: "MEM", name: "Grizzlies" },    { abbr: "MIA", name: "Heat" },
  { abbr: "MIL", name: "Bucks" },        { abbr: "MIN", name: "Timberwolves" },
  { abbr: "NO", name: "Pelicans" },      { abbr: "NY", name: "Knicks" },
  { abbr: "OKC", name: "Thunder" },      { abbr: "ORL", name: "Magic" },
  { abbr: "PHI", name: "76ers" },        { abbr: "PHX", name: "Suns" },
  { abbr: "POR", name: "Trail Blazers" },{ abbr: "SAC", name: "Kings" },
  { abbr: "SA", name: "Spurs" },         { abbr: "TOR", name: "Raptors" },
  { abbr: "UTAH", name: "Jazz" },        { abbr: "WSH", name: "Wizards" }
]

// Local hour for the morning-of reminder.
var DAY_REMINDER_HOUR = 10
var HOUR_REMINDER_MINUTES = 60

function str(value, max) {
  var s = value === undefined || value === null ? "" : String(value)
  return s.length > max ? s.slice(0, max) : s
}

function isTeam(abbr) {
  for (var i = 0; i < TEAMS.length; i++) if (TEAMS[i].abbr === abbr) return true
  return false
}

function teamName(abbr) {
  for (var i = 0; i < TEAMS.length; i++) if (TEAMS[i].abbr === abbr) return TEAMS[i].name
  return ""
}

// Settings file: {"team": "BOS"}. Anything else reads as no team.
function parseSettings(raw) {
  try {
    var p = JSON.parse(String(raw || ""))
    var t = p && typeof p.team === "string" ? p.team : ""
    return { team: isTeam(t) ? t : "" }
  } catch (e) {
    return { team: "" }
  }
}

function score(value) {
  var s = str(value, 4)
  return /^\d{1,3}$/.test(s) ? s : ""
}

function team(competitor) {
  var t = competitor && competitor.team ? competitor.team : {}
  var records = Array.isArray(competitor && competitor.records) ? competitor.records : []
  return {
    abbr: str(t.abbreviation, 4),
    name: str(t.shortDisplayName || t.name, 24),
    score: score(competitor && competitor.score),
    record: records.length > 0 ? str(records[0].summary, 8) : "",
    winner: competitor && competitor.winner === true
  }
}

// Only national outlets (ESPN, ABC, NBC, Peacock, Prime Video, NBA TV, ...).
// Regional networks and team apps are dropped: their viewers already know.
// The scoreboard gives {market: "national", names: [...]}, the team schedule
// {market: {type: "National"}, media: {shortName}}; both are handled.
function broadcast(competition) {
  var list = Array.isArray(competition && competition.broadcasts) ? competition.broadcasts : []
  var names = []
  for (var i = 0; i < list.length && names.length < 3; i++) {
    var b = list[i] || {}
    var market = b.market && typeof b.market === "object" ? b.market.type : b.market
    if (String(market || "").toLowerCase() !== "national") continue
    var n = Array.isArray(b.names) ? b.names : (b.media && b.media.shortName ? [b.media.shortName] : [])
    for (var j = 0; j < n.length && names.length < 3; j++) {
      var name = str(n[j], 16)
      if (name && names.indexOf(name) === -1) names.push(name)
    }
  }
  return names.join(", ")
}

function state(status) {
  var s = status && status.type ? status.type.state : ""
  return s === "in" || s === "post" ? s : "pre"
}

var STATE_ORDER = { "in": 0, "pre": 1, "post": 2 }

function parseScoreboard(raw) {
  var data = JSON.parse(raw)
  var events = Array.isArray(data && data.events) ? data.events.slice(0, MAX_GAMES) : []
  var games = []

  for (var i = 0; i < events.length; i++) {
    var ev = events[i] || {}
    var comp = Array.isArray(ev.competitions) ? ev.competitions[0] : null
    if (!comp || !Array.isArray(comp.competitors)) continue

    var home = null, away = null
    for (var k = 0; k < comp.competitors.length; k++) {
      var c = comp.competitors[k]
      if (c && c.homeAway === "home") home = team(c)
      else if (c && c.homeAway === "away") away = team(c)
    }
    if (!home || !away) continue

    var type = (ev.status || {}).type || {}
    var st = state(ev.status)
    var start = Date.parse(ev.date)
    // ESPN reports "0" before tip-off; show the start time instead.
    if (st === "pre") { home.score = ""; away.score = "" }

    games.push({
      id: str(ev.id, 16),
      state: st,
      detail: str(type.shortDetail || type.detail, 32),
      start: isNaN(start) ? 0 : start,
      home: home,
      away: away,
      broadcast: broadcast(comp)
    })
  }
  return games
}

function involves(game, abbr) {
  return abbr !== "" && (game.home.abbr === abbr || game.away.abbr === abbr)
}

// Home team's game first, then live, upcoming, finished; by start time within each.
function sortGames(games, favorite) {
  var out = games.slice()
  out.sort(function(a, b) {
    var fa = involves(a, favorite) ? 0 : 1, fb = involves(b, favorite) ? 0 : 1
    if (fa !== fb) return fa - fb
    var d = STATE_ORDER[a.state] - STATE_ORDER[b.state]
    return d !== 0 ? d : a.start - b.start
  })
  return out
}

function liveCount(games) {
  var n = 0
  for (var i = 0; i < games.length; i++) if (games[i].state === "in") n++
  return n
}

// Which side is ahead, for bolding: "home", "away" or "".
function leader(game) {
  if (game.state === "pre") return ""
  if (game.home.winner) return "home"
  if (game.away.winner) return "away"
  var h = parseInt(game.home.score, 10), a = parseInt(game.away.score, 10)
  if (isNaN(h) || isNaN(a) || h === a) return ""
  return h > a ? "home" : "away"
}

// ---- Game detail (ESPN /summary?event=<id>)

var TEAM_STATS = [
  ["fieldGoalsMade-fieldGoalsAttempted", "FG"],
  ["fieldGoalPct", "FG%"],
  ["threePointFieldGoalsMade-threePointFieldGoalsAttempted", "3PT"],
  ["threePointFieldGoalPct", "3P%"],
  ["freeThrowsMade-freeThrowsAttempted", "FT"],
  ["totalRebounds", "REB"],
  ["assists", "AST"],
  ["turnovers", "TOV"],
  ["steals", "STL"],
  ["blocks", "BLK"]
]

// [ESPN key, heading, wide] — wide columns hold "made-attempted" pairs.
var PLAYER_COLUMNS = [
  ["minutes", "MIN", false],
  ["points", "PTS", false],
  ["rebounds", "REB", false],
  ["assists", "AST", false],
  ["turnovers", "TOV", false],
  ["steals", "STL", false],
  ["blocks", "BLK", false],
  ["fieldGoalsMade-fieldGoalsAttempted", "FG", true],
  ["threePointFieldGoalsMade-threePointFieldGoalsAttempted", "3PT", true]
]

// Total width of the stat columns, in narrow-column units.
function playerColumnUnits() {
  var u = 0
  for (var i = 0; i < PLAYER_COLUMNS.length; i++) u += PLAYER_COLUMNS[i][2] ? 1.5 : 1
  return u
}

function isGameId(id) {
  return /^[0-9]{1,16}$/.test(String(id || ""))
}

// -> { away: {abbr, stats: {FG: "33-73", ...}, players: [{name, starter, values: [...]}]},
//      home: {...}, hasStats }
function parseSummary(raw) {
  var data = JSON.parse(raw)
  var box = data && data.boxscore ? data.boxscore : {}
  var out = {
    away: { abbr: "", stats: {}, players: [] },
    home: { abbr: "", stats: {}, players: [] },
    hasStats: false
  }
  var sideByAbbr = {}

  var teams = Array.isArray(box.teams) ? box.teams.slice(0, 2) : []
  for (var i = 0; i < teams.length; i++) {
    var t = teams[i] || {}
    var side = t.homeAway === "home" ? "home" : "away"
    var abbr = str(t.team && t.team.abbreviation, 4)
    out[side].abbr = abbr
    sideByAbbr[abbr] = side
    var stats = Array.isArray(t.statistics) ? t.statistics.slice(0, 60) : []
    for (var s = 0; s < stats.length; s++) {
      for (var k = 0; k < TEAM_STATS.length; k++) {
        if (stats[s] && stats[s].name === TEAM_STATS[k][0]) {
          out[side].stats[TEAM_STATS[k][1]] = str(stats[s].displayValue, 8)
        }
      }
    }
  }

  var players = Array.isArray(box.players) ? box.players.slice(0, 2) : []
  for (var p = 0; p < players.length; p++) {
    var entry = players[p] || {}
    var pside = sideByAbbr[str(entry.team && entry.team.abbreviation, 4)]
    var group = Array.isArray(entry.statistics) ? entry.statistics[0] : null
    if (!pside || !group || !Array.isArray(group.keys)) continue
    var cols = PLAYER_COLUMNS.map(function(c) { return group.keys.indexOf(c[0]) })
    var athletes = Array.isArray(group.athletes) ? group.athletes.slice(0, 20) : []
    for (var a = 0; a < athletes.length; a++) {
      var ath = athletes[a] || {}
      var vals = Array.isArray(ath.stats) ? ath.stats : []
      if (ath.didNotPlay === true || vals.length === 0) continue
      out[pside].players.push({
        name: str(ath.athlete && (ath.athlete.shortName || ath.athlete.displayName), 22),
        starter: ath.starter === true,
        values: cols.map(function(ci) { return ci >= 0 ? str(vals[ci], 6) : "" })
      })
    }
  }
  // Before tip-off ESPN fills team stats with season averages; only a box
  // score with players in it means this game has stats of its own.
  out.hasStats = out.away.players.length > 0 || out.home.players.length > 0
  return out
}

// Rows for the side-by-side team comparison.
function teamStatRows(summary) {
  if (!summary || !summary.hasStats) return []
  return TEAM_STATS.map(function(s) {
    return { label: s[1], away: summary.away.stats[s[1]] || "–", home: summary.home.stats[s[1]] || "–" }
  })
}

// ---- Home-team schedule and reminders

// ESPN /teams/<abbr>/schedule -> [{id, start, state, home, opponent, broadcast}]
function parseSchedule(raw, abbr) {
  var data = JSON.parse(raw)
  var events = Array.isArray(data && data.events) ? data.events.slice(0, MAX_SCHEDULE) : []
  var games = []
  for (var i = 0; i < events.length; i++) {
    var ev = events[i] || {}
    var comp = Array.isArray(ev.competitions) ? ev.competitions[0] : null
    if (!comp || !Array.isArray(comp.competitors)) continue
    var us = null, them = null
    for (var k = 0; k < comp.competitors.length; k++) {
      var c = comp.competitors[k] || {}
      var a = str(c.team && c.team.abbreviation, 4)
      if (a === abbr) us = c
      else them = c
    }
    if (!us || !them) continue
    var start = Date.parse(ev.date)
    if (isNaN(start)) continue
    games.push({
      id: str(ev.id, 16),
      start: start,
      state: state(comp.status || ev.status),
      home: us.homeAway === "home",
      opponent: str(them.team && (them.team.shortDisplayName || them.team.name), 24),
      broadcast: broadcast(comp)
    })
  }
  return games
}

// The team's next game that hasn't started yet, or null.
function nextGame(schedule, now) {
  var best = null
  for (var i = 0; i < schedule.length; i++) {
    var g = schedule[i]
    if (g.state !== "pre" || g.start <= now) continue
    if (!best || g.start < best.start) best = g
  }
  return best
}

function playsToday(games, abbr) {
  for (var i = 0; i < games.length; i++) if (involves(games[i], abbr)) return true
  return false
}

// Whole calendar days from `now` to `ms` in local time (0 = today, 1 = tomorrow).
function daysUntil(ms, now) {
  var a = new Date(now), b = new Date(ms)
  var da = new Date(a.getFullYear(), a.getMonth(), a.getDate())
  var db = new Date(b.getFullYear(), b.getMonth(), b.getDate())
  return Math.round((db - da) / 86400000)
}

// Reminders due now. `sent` maps keys ("<gameId>:day" / "<gameId>:hour") that
// were already delivered. The morning reminder goes out from 10:00 local on
// game day until an hour before tip-off; inside that last hour only the
// tip-off reminder is sent (it also settles the morning one).
function dueReminders(games, now, sent) {
  var out = []
  var today = new Date(now).toDateString()
  var hour = new Date(now).getHours()
  for (var i = 0; i < games.length; i++) {
    var g = games[i]
    if (g.state !== "pre" || !g.id) continue
    var minutes = (g.start - now) / 60000
    if (minutes <= 0) continue
    var dayKey = g.id + ":day", hourKey = g.id + ":hour"
    if (minutes <= HOUR_REMINDER_MINUTES) {
      if (!sent[hourKey]) out.push({ kind: "hour", keys: [hourKey, dayKey], game: g, minutes: Math.max(1, Math.round(minutes)) })
    } else if (new Date(g.start).toDateString() === today && hour >= DAY_REMINDER_HOUR && !sent[dayKey]) {
      out.push({ kind: "day", keys: [dayKey], game: g, minutes: Math.round(minutes) })
    }
  }
  return out
}

// Drop delivered-reminder records for games more than three days old.
function pruneSent(sent, now) {
  var out = {}
  for (var k in sent) {
    var v = Number(sent[k])
    if (/^[0-9]{1,16}:(day|hour)$/.test(k) && v > now - 3 * 86400000) out[k] = v
  }
  return out
}
