import QtQuick
import org.kde.plasma.plasma5support as Plasma5Support
import "js/ResponseCachePipeline.js" as Pipeline

Item {
    id: root

    property bool enabled: true
    property string configuredRoot: ""
    property string homeDir: ""
    readonly property int watchdogMs: 12000
    property var pipeline: null

    readonly property string cacheScript: {
        var u = Qt.resolvedUrl("../scripts/cache-response.sh").toString()
        return u.indexOf("file://") === 0 ? u.substring(7) : u
    }

    function ensurePipeline() {
        if (pipeline) return pipeline
        pipeline = Pipeline.create({
            settings: function() {
                return {
                    enabled: root.enabled,
                    configuredRoot: root.configuredRoot,
                    homeDir: root.homeDir,
                    cacheScript: root.cacheScript,
                    payloadChunkSize: 8192,
                    watchdogMs: root.watchdogMs,
                    maxAttempts: 2
                }
            },
            nowMs: function() { return Date.now() },
            startCommand: function(sourceName, command) {
                cacheWriter.connectSource(sourceName)
            },
            disconnectCommand: function(sourceName) {
                cacheWriter.disconnectSource(sourceName)
            },
            startWatchdog: function(milliseconds) {
                cacheWatchdog.interval = milliseconds
                cacheWatchdog.restart()
            },
            stopWatchdog: function() { cacheWatchdog.stop() },
            log: function(message) { console.log(message) }
        })
        return pipeline
    }

    function recordExchange(exchange) {
        ensurePipeline().recordExchange(exchange)
    }

    Component.onCompleted: ensurePipeline()

    Plasma5Support.DataSource {
        id: cacheWriter
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var exitCode = data["exit code"] !== undefined
                    ? data["exit code"] : data["exitCode"]
            var pipeline = root.ensurePipeline()
            pipeline.commandFinished(sourceName, {
                exitCode: exitCode || 0,
                stderr: data["stderr"] || ""
            })
        }
    }

    Timer {
        id: cacheWatchdog
        interval: 12000
        repeat: false
        onTriggered: {
            var pipeline = root.ensurePipeline()
            pipeline.watchdogFired()
        }
    }
}
