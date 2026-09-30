// Everything the ports panel decides that is not drawing.
//
// Kept out of Ports.qml for the reason Omarchy keeps its own Model.js files
// there: a filter and a label are the parts that are wrong quietly, and a plain
// function can be run against a captured `listening-ports list` document without
// a compositor. tests/dev-ports.test.sh does exactly that.

function parse(raw) {
  try {
    var document = JSON.parse(String(raw || ""))
    if (!document || !Array.isArray(document.records)) return { records: [], error: "unreadable" }
    return { records: document.records, error: "" }
  } catch (error) {
    return { records: [], error: String(error) }
  }
}

// DEV PORTS, AND NOTHING ELSE.
//
// A dev port is one held by a process you own, running out of a git checkout,
// on a port somebody chose. Each clause removed a kind of row that was true and
// was not what anybody opened this panel to find:
//
//   - not yours      sshd, cups, the resolver. Nothing here can stop them.
//   - no checkout    Steam, Discord, Chrome. Every application on the desk this
//                    was built on had its working directory in $HOME or an
//                    install directory; every dev server had it in a checkout.
//   - not chosen     ephemeral ports, which the kernel handed out when
//                    something asked for port 0. Twenty-four of them on that
//                    desk, most of them one Node process's workers.
//
// Earlier versions kept applications and ephemeral ports one click away, under
// a count. They were never opened.
function isDevelopmentPort(record) {
  return record.isStoppable && !record.isEphemeral
    && record.repositoryName !== undefined && record.repositoryName !== ""
}

function projectKey(record) {
  return record.repositoryName + "\u0000" + record.worktreeName + "\u0000" + record.branchName
}

// ONE PORT PER ROW.
//
// A process holding two ports used to be one row, `8797 · 9233   workerd`. That
// made the port column unscannable -- it is the thing you run your eye down,
// looking for the number you remember -- and it made the stop button mean two
// ports at once. A row is now a port, and the process is its label.
function makeRow(record) {
  return {
    processId: record.processId,
    processName: record.processName,
    commandLine: record.commandLine,
    projectPath: record.projectPath || "",
    port: record.port,
    protocol: record.protocol,
    isNetworkReachable: record.isNetworkReachable,
    isStoppable: record.isStoppable,
    rowIndex: 0
  }
}

function byPort(first, second) {
  if (first.port !== second.port) return first.port - second.port
  if (first.protocol !== second.protocol) return first.protocol < second.protocol ? -1 : 1
  return first.processId - second.processId
}

// Checkouts alphabetically, ports ascending within them, and every row numbered
// once in drawing order -- the keyboard cursor walks that number, and a refresh
// that finds the same ports puts them back in the same places. An order that can
// tie reshuffles rows under the pointer, and the row that moves is the one you
// were about to click.
function sections(records) {
  var groups = {}
  var order = []
  for (var index = 0; index < records.length; index++) {
    var record = records[index]
    if (!isDevelopmentPort(record)) continue
    var key = projectKey(record)
    if (!groups[key]) { groups[key] = { record: record, rows: [] }; order.push(key) }
    groups[key].rows.push(makeRow(record))
  }

  var result = []
  for (var position = 0; position < order.length; position++) {
    var group = groups[order[position]]
    group.rows.sort(byPort)
    result.push({
      key: order[position],
      heading: sectionHeading(group.record),
      caption: sectionCaption(group.record),
      rows: group.rows
    })
  }
  result.sort(function(first, second) {
    return first.heading < second.heading ? -1 : (first.heading > second.heading ? 1 : 0)
  })

  var flat = []
  for (var sectionIndex = 0; sectionIndex < result.length; sectionIndex++) {
    for (var rowIndex = 0; rowIndex < result[sectionIndex].rows.length; rowIndex++) {
      result[sectionIndex].rows[rowIndex].rowIndex = flat.length
      flat.push(result[sectionIndex].rows[rowIndex])
    }
  }
  return { sections: result, rows: flat }
}

// `bonsai · concierge-report-full-funnel`, or just `bonsai-harness` for a plain
// checkout.
function sectionHeading(record) {
  return record.worktreeName ? record.repositoryName + " · " + record.worktreeName : record.repositoryName
}

// The branch, ONLY when the heading has not already said it.
//
// Worktrees here are named for their branch -- `bonsai/concierge-report-
// full-funnel` lives at `worktrees/bonsai/concierge-report-full-funnel` -- so
// printing both put the same words on two consecutive lines, which read as a
// glitch rather than as information. The branch earns its line when it is
// something the heading cannot tell you: `main` under `bonsai-harness`, or a
// worktree that has been switched to a different branch since it was made.
function sectionCaption(record) {
  if (!record.branchName) return ""
  var worktree = record.worktreeName
  var derivable = worktree !== "" && (record.branchName === worktree
    || record.branchName.slice(-(worktree.length + 1)) === "/" + worktree)
  return derivable ? "" : BRANCH_GLYPH + " " + record.branchName
}

// Nerd Font `nf-dev-git_branch`, written as an escape. It is private-use, and
// pasted as a literal it has already vanished once between editor and file.
var BRANCH_GLYPH = ""

// WHETHER ANYTHING IS OPEN, NOT HOW MUCH.
//
// The bar draws a dot, the way a chat app marks unread messages, rather than a
// count. The question the bar answers at a glance is "did I leave a server
// running" -- yes or no -- and a number made it answer a different question
// that nobody was asking from across the room. The count is still in the
// tooltip, where it costs nothing.
function barSummary(records) {
  var developmentPortCount = 0
  for (var index = 0; index < records.length; index++)
    if (isDevelopmentPort(records[index])) developmentPortCount++
  return { developmentPortCount: developmentPortCount, hasDevelopmentPort: developmentPortCount > 0 }
}

function barTooltip(summary) {
  if (!summary.hasDevelopmentPort) return "No dev servers running"
  return summary.developmentPortCount + (summary.developmentPortCount === 1 ? " dev port open" : " dev ports open")
}

// THE KERNEL CUTS A PROCESS NAME AT 15 BYTES; SOME PROCESSES SAY THE REST.
//
// Next.js retitles its server, so /proc/<pid>/cmdline holds the whole
// `next-server (v15.5.24)` while `comm` holds `next-server (v1`. When the name
// is exactly the length the kernel truncates to and the title starts with it,
// the title is the name. Anything that starts with a path is an argv, not a
// title, and keeps the short name.
//
// Display only. The stop path still sends `processName` -- the kernel's own
// word -- because that is what the guard against a recycled pid compares with.
var COMMAND_NAME_LENGTH = 15

function rowName(row) {
  var name = row.processName || "not visible to you"
  var title = row.commandLine || ""
  if (name.length === COMMAND_NAME_LENGTH && title.indexOf(name) === 0) {
    var full = title.split(" /")[0].trim()
    if (full.length > name.length) return full.length > 32 ? full.slice(0, 31) + "…" : full
  }
  return name
}

// The detail line is drawn in coloured pieces rather than as one string, so
// these are pieces. UDP is said and TCP is not: TCP is the default, and a UDP
// listener is usually not the thing a developer is looking for.
function rowPath(row) {
  return row.projectPath ? row.projectPath + "/" : "./"
}

function rowReach(row) {
  return row.isNetworkReachable ? "network" : "local"
}

function rowTrail(row) {
  return (row.protocol === "udp" ? "udp · " : "") + "pid " + row.processId
}

function rowTooltip(row) {
  return row.commandLine || row.processName
}

function stopRefusal(row) {
  return row.isStoppable ? "" : "This process cannot be stopped from here"
}

function confirmMessage(row, signalName) {
  var who = rowName(row) + " (pid " + row.processId + ") on port " + row.port
  return signalName === "KILL"
    ? "Force " + who + " to stop? It ignored the polite request, so this one cannot be caught or cleaned up after."
    : "Stop " + who + "?"
}

if (typeof module !== "undefined") {
  module.exports = {
    parse: parse,
    isDevelopmentPort: isDevelopmentPort,
    sections: sections,
    barSummary: barSummary,
    barTooltip: barTooltip,
    rowName: rowName,
    rowPath: rowPath,
    rowReach: rowReach,
    rowTrail: rowTrail,
    rowTooltip: rowTooltip,
    stopRefusal: stopRefusal,
    confirmMessage: confirmMessage
  }
}
