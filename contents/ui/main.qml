import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    // Translations
    Translations {
        id: i18n
        currentLanguage: Plasmoid.configuration.language || "system"
    }

    property real sessionUsagePercent: 0
    property real weeklyUsagePercent: 0
    property real sonnetWeeklyPercent: 0
    property real opusWeeklyPercent: 0
    // Additional rate limits (Codex Spark, etc.) - list of {name, percent} objects
    property var additionalLimits: []
    property string lastUpdate: ""
    property string planName: ""
    property string sessionReset: ""
    property string weeklyReset: ""
    property string errorMsg: ""
    property string accessToken: ""
    property bool isLoading: false
    property var sessionResetTime: null
    property var weeklyResetTime: null
    property real weeklyPeriodMs: 7 * 24 * 60 * 60 * 1000  // default 7 days

    readonly property string provider: Plasmoid.configuration.provider || "claude"
    readonly property string opencodeSubProvider: Plasmoid.configuration.opencodeSubProvider || "anthropic"
    readonly property int opencodeAccountIndex: Plasmoid.configuration.opencodeAccountIndex || 0
    readonly property string usageApiUrl: {
        if (provider === "codex") return "https://chatgpt.com/backend-api/wham/usage"
        if (provider === "zai") return "https://api.z.ai/api/monitor/usage/quota/limit"
        if (provider === "opencode") {
            if (opencodeSubProvider === "zai") return "https://api.z.ai/api/monitor/usage/quota/limit"
            if (opencodeSubProvider === "openai") return "https://chatgpt.com/backend-api/wham/usage"
            return "https://api.anthropic.com/api/oauth/usage"  // anthropic + others
        }
        return "https://api.anthropic.com/api/oauth/usage"
    }
    readonly property string displayName: Plasmoid.configuration.displayName || (function() {
        if (provider === "codex") return "Codex"
        if (provider === "zai") return "Z.ai"
        if (provider === "opencode") {
            var names = { "anthropic": "Claude", "openai": "Codex", "zai": "Z.ai", "kimi": "Kimi", "gemini": "Gemini" }
            return (names[opencodeSubProvider] || opencodeSubProvider) + " (OC)"
        }
        return "Claude"
    })()
    readonly property string sessionLabel: provider === "zai" ? i18n.tr("Tokens (5hr)") : i18n.tr("Session (5hr)")
    readonly property string weeklyLabel: provider === "zai" ? i18n.tr("Monthly (MCP)") : i18n.tr("Weekly (7day)")
    property string accountId: ""
    property real sessionTimePercent: 0
    property real weeklyTimePercent: 0
    property bool modelSectionExpanded: false
    property real requiredPace: 0

    // Data source for reading credentials file
    Plasma5Support.DataSource {
        id: fileReader
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            disconnectSource(sourceName)

            console.log("Claude Usage: Got credentials, length:", stdout.length)

            if (stdout.length > 10) {
                try {
                    var creds = JSON.parse(stdout)

                    if (root.provider === "codex") {
                        parseCodexCredentials(creds)
                    } else if (root.provider === "zai") {
                        parseZaiCredentials(creds)
                    } else if (root.provider === "opencode") {
                        parseOpencodeCredentials(creds)
                    } else {
                        parseClaudeCredentials(creds)
                    }
                } catch (e) {
                    console.log("Claude Usage: Failed to parse credentials:", e)
                    root.errorMsg = "Not logged in"
                    root.isLoading = false
                }
            } else {
                console.log("Claude Usage: No credentials file found")
                root.errorMsg = "Not logged in"
                root.isLoading = false
            }
        }
    }

    function parseClaudeCredentials(creds) {
        var oauth = creds.claudeAiOauth || {}
        root.accessToken = oauth.accessToken || ""

        var tier = oauth.rateLimitTier || "default_claude_pro"
        var planMap = {
            "default_claude_pro": "Pro",
            "default_claude_max_5x": "Max 5x",
            "default_claude_max_20x": "Max 20x"
        }
        root.planName = planMap[tier] || tier

        console.log("Claude Usage: Token found, plan:", root.planName)

        if (root.accessToken) {
            fetchUsageFromApi()
        } else {
            root.errorMsg = i18n.tr("Not logged in")
            root.isLoading = false
        }
    }

    function parseCodexCredentials(creds) {
        // Support both native ~/.codex/auth.json and OpenCode auth.json formats
        var tokens = creds.tokens || {}
        var openai = creds.openai || {}
        root.accessToken = tokens.access_token || openai.access || ""
        root.accountId = tokens.account_id || openai.accountId || ""

        // Try to extract plan from id_token JWT payload
        var idToken = tokens.id_token || ""
        if (idToken) {
            try {
                var parts = idToken.split(".")
                if (parts.length >= 2) {
                    var payload = JSON.parse(Qt.atob(parts[1]))
                    var plan = payload.plan_type || ""
                    if (plan) {
                        root.planName = plan.charAt(0).toUpperCase() + plan.slice(1)
                    }
                }
            } catch (e) {
                console.log("Claude Usage: Could not parse Codex id_token:", e)
            }
        }

        console.log("Claude Usage: Codex token found, plan:", root.planName)

        if (root.accessToken) {
            fetchUsageFromApi()
        } else {
            root.errorMsg = i18n.tr("Not logged in")
            root.isLoading = false
        }
    }

    function parseZaiCredentials(creds) {
        // OpenCode auth.json format: { "zai-coding-plan": { "type": "api", "key": "..." } }
        var zai = creds["zai-coding-plan"] || {}
        root.accessToken = zai.key || ""

        console.log("Claude Usage: Z.ai token found, length:", root.accessToken.length)

        if (root.accessToken) {
            fetchUsageFromApi()
        } else {
            root.errorMsg = i18n.tr("Not logged in")
            root.isLoading = false
        }
    }

    function parseOpencodeCredentials(creds) {
        var sub = root.opencodeSubProvider || "anthropic"

        if (sub === "anthropic") {
            // anthropic-accounts.json: { accounts: [{ access, expires, ... }] }
            if (creds.accounts && Array.isArray(creds.accounts)) {
                var accountIndex = root.opencodeAccountIndex || 0
                if (accountIndex < creds.accounts.length) {
                    root.accessToken = creds.accounts[accountIndex].access || ""
                    console.log("Claude Usage: OpenCode anthropic account", accountIndex, "token length:", root.accessToken.length)
                }
            } else {
                // Fallback: auth.json with { anthropic: { access, expires } }
                root.accessToken = (creds.anthropic || {}).access || ""
                console.log("Claude Usage: OpenCode anthropic fallback token length:", root.accessToken.length)
            }
        } else {
            // auth.json: { "<sub>": { access: "..." } } or { "<sub>": { key: "..." } }
            var subCreds = creds[sub] || {}
            root.accessToken = subCreds.access || subCreds.key || ""
            console.log("Claude Usage: OpenCode", sub, "token length:", root.accessToken.length)
        }

        if (root.accessToken) {
            fetchUsageFromApi()
        } else {
            root.errorMsg = i18n.tr("Not logged in")
            root.isLoading = false
        }
    }

    function loadCredentials() {
        root.isLoading = true
        root.errorMsg = ""
        var credPath = Plasmoid.configuration.credentialsPath || ""
        if (credPath === "") {
            var defaultPath
            if (root.provider === "codex") defaultPath = "$HOME/.codex/auth.json"
            else if (root.provider === "zai") defaultPath = "$HOME/.local/share/opencode/auth.json"
            else if (root.provider === "opencode") {
                // Anthropic gets the multi-account file; all others use auth.json
                if (root.opencodeSubProvider === "anthropic")
                    defaultPath = "$HOME/.config/opencode/anthropic-accounts.json"
                else
                    defaultPath = "$HOME/.local/share/opencode/auth.json"
            }
            else defaultPath = "$HOME/.claude/.credentials.json"
            fileReader.connectSource("cat " + defaultPath + " 2>/dev/null")
        } else {
            // Shell-quote user-provided path to prevent command injection
            var safePath = "'" + credPath.replace(/'/g, "'\\''") + "'"
            fileReader.connectSource("cat " + safePath + " 2>/dev/null")
        }
    }

    function fetchUsageFromApi() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", usageApiUrl)
        xhr.setRequestHeader("Content-Type", "application/json")

        var isZai = root.provider === "zai" || (root.provider === "opencode" && root.opencodeSubProvider === "zai")
        if (isZai) {
            // Z.ai API uses raw API key without "Bearer" prefix
            xhr.setRequestHeader("Authorization", root.accessToken)
        } else {
            xhr.setRequestHeader("Authorization", "Bearer " + root.accessToken)
        }

        var isAnthropic = root.provider === "claude" || (root.provider === "opencode" && root.opencodeSubProvider === "anthropic")
        var isCodex = root.provider === "codex" || (root.provider === "opencode" && root.opencodeSubProvider === "openai")
        if (isAnthropic) {
            xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20")
        } else if (isCodex) {
            if (root.accountId) {
                xhr.setRequestHeader("ChatGPT-Account-Id", root.accountId)
            }
        }

        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                root.isLoading = false

                if (xhr.status === 200) {
                    try {
                        var data = JSON.parse(xhr.responseText)

                        var sub = root.provider === "opencode" ? root.opencodeSubProvider : root.provider
                        if (sub === "codex" || sub === "openai") {
                            parseCodexUsage(data)
                        } else if (sub === "zai") {
                            parseZaiUsage(data)
                        } else {
                            parseClaudeUsage(data)
                        }

                        root.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
                        root.errorMsg = ""

                        console.log("Claude Usage: API success - session:", root.sessionUsagePercent, "weekly:", root.weeklyUsagePercent)
                    } catch (e) {
                        console.log("Claude Usage: JSON parse error:", e)
                        root.errorMsg = "Parse error"
                    }
                } else if (xhr.status === 401) {
                    root.errorMsg = i18n.tr("Token expired")
                    console.log("Claude Usage: 401 Unauthorized")
                } else {
                    root.errorMsg = i18n.tr("API error") + " (" + xhr.status + ")"
                    console.log("Claude Usage: API error:", xhr.status, xhr.statusText)
                }
            }
        }

        xhr.send()
    }

    function parseClaudeUsage(data) {
        var fiveHour = data.five_hour || {}
        var sevenDay = data.seven_day || {}
        var sevenDaySonnet = data.seven_day_sonnet || {}
        var sevenDayOpus = data.seven_day_opus || {}

        root.sessionUsagePercent = fiveHour.utilization || 0
        root.weeklyUsagePercent = sevenDay.utilization || 0
        root.additionalLimits = []
        root.sonnetWeeklyPercent = sevenDaySonnet ? (sevenDaySonnet.utilization || 0) : 0
        root.opusWeeklyPercent = sevenDayOpus ? (sevenDayOpus.utilization || 0) : 0

        if (fiveHour.resets_at) {
            root.sessionResetTime = new Date(fiveHour.resets_at)
            root.sessionReset = Qt.formatTime(root.sessionResetTime, "hh:mm")
            updateSessionTimePercent()
        }
        if (sevenDay.resets_at) {
            root.weeklyResetTime = new Date(sevenDay.resets_at)
            root.weeklyReset = Qt.formatDateTime(root.weeklyResetTime, "MMM d, hh:mm")
            updateWeeklyTimePercent()
        }
        updateRequiredPace()
    }

    function parseCodexUsage(data) {
        var rateLimit = data.rate_limit || {}
        var primary = rateLimit.primary_window || {}
        var secondary = rateLimit.secondary_window || {}

        root.sessionUsagePercent = primary.used_percent || 0
        root.weeklyUsagePercent = secondary.used_percent || 0
        root.sonnetWeeklyPercent = 0
        root.opusWeeklyPercent = 0

        if (primary.reset_at) {
            root.sessionResetTime = new Date(primary.reset_at * 1000)
            root.sessionReset = Qt.formatTime(root.sessionResetTime, "hh:mm")
            updateSessionTimePercent()
        }
        if (secondary.reset_at) {
            root.weeklyResetTime = new Date(secondary.reset_at * 1000)
            root.weeklyReset = Qt.formatDateTime(root.weeklyResetTime, "MMM d, hh:mm")
            updateWeeklyTimePercent()
        }
        updateRequiredPace()

        // Parse additional rate limits (e.g. Spark model)
        var extras = data.additional_rate_limits || []
        var parsed = []
        for (var i = 0; i < extras.length; i++) {
            var entry = extras[i]
            var name = entry.limit_name || entry.metered_feature || ("Limit " + i)
            var rl = entry.rate_limit || {}
            var sw = rl.secondary_window || rl.primary_window || {}
            parsed.push({ name: name, percent: sw.used_percent || 0 })
        }
        root.additionalLimits = parsed

        // Update plan name from API response if not already set from JWT
        if (data.plan_type && !root.planName) {
            var plan = data.plan_type
            root.planName = plan.charAt(0).toUpperCase() + plan.slice(1)
        }
    }

    function parseZaiUsage(data) {
        // Response: { data: { limits: [...], planName: "..." } } or { limits: [...] }
        var container = data.data || data
        var limits = container.limits || []

        // Find limit entries by type
        var tokenLimit = null
        var timeLimit = null
        for (var i = 0; i < limits.length; i++) {
            if (limits[i].type === "TOKENS_LIMIT") tokenLimit = limits[i]
            else if (limits[i].type === "TIME_LIMIT") timeLimit = limits[i]
        }

        // TOKENS_LIMIT = 5hr rolling token usage → session slot
        if (tokenLimit) {
            root.sessionUsagePercent = tokenLimit.percentage || 0
            if (tokenLimit.nextResetTime) {
                root.sessionResetTime = new Date(tokenLimit.nextResetTime)
                root.sessionReset = Qt.formatTime(root.sessionResetTime, "hh:mm")
                updateSessionTimePercent()
            }
        }

        // TIME_LIMIT = monthly MCP tool usage → weekly slot (repurposed)
        if (timeLimit) {
            root.weeklyUsagePercent = timeLimit.percentage || 0
            root.weeklyPeriodMs = 30 * 24 * 60 * 60 * 1000  // monthly
            if (timeLimit.nextResetTime) {
                root.weeklyResetTime = new Date(timeLimit.nextResetTime)
                root.weeklyReset = Qt.formatDateTime(root.weeklyResetTime, "MMM d, hh:mm")
                updateWeeklyTimePercent()
            }
        } else {
            root.weeklyUsagePercent = 0
        }

        // No per-model breakdown for Z.ai
        root.sonnetWeeklyPercent = 0
        root.opusWeeklyPercent = 0
        root.additionalLimits = []

        // Plan name from response
        var planName = container.planName || container.packageName || data.plan_type || ""
        if (planName) {
            root.planName = planName.charAt(0).toUpperCase() + planName.slice(1)
        } else if (!root.planName) {
            root.planName = "Z.ai"
        }
    }

    function refresh() {
        loadCredentials()
    }

    // Compact representation (panel) - shows both percentages
    compactRepresentation: Item {
        Layout.minimumWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        RowLayout {
            id: usageRow
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            // Claude icon
            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                source: Qt.resolvedUrl("../icons/claude.svg")
                Layout.rightMargin: Kirigami.Units.smallSpacing
            }

            // Error state
            PlasmaComponents.Label {
                visible: root.errorMsg !== ""
                text: "⚠"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                color: Kirigami.Theme.negativeTextColor
            }

            // Normal state
            Rectangle {
                visible: root.errorMsg === ""
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getSessionColor()
            }

            PlasmaComponents.Label {
                visible: root.errorMsg === ""
                text: Math.round(root.sessionUsagePercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
            }

            PlasmaComponents.Label {
                visible: root.errorMsg === ""
                text: "|"
                opacity: 0.5
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
            }

            Rectangle {
                visible: root.errorMsg === ""
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getWeeklyColor()
            }

            PlasmaComponents.Label {
                visible: root.errorMsg === ""
                text: Math.round(root.weeklyUsagePercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
            }

            // Error text
            PlasmaComponents.Label {
                visible: root.errorMsg !== ""
                text: root.errorMsg
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.negativeTextColor
            }
        }
    }

    // Full representation (popup)
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 16
        Layout.preferredWidth: Kirigami.Units.gridUnit * 16
        Layout.preferredHeight: Kirigami.Units.gridUnit * 18

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.mediumSpacing

            // Header
            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: root.displayName + " " + i18n.tr("Usage")
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.3
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: planLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                    Layout.preferredHeight: planLabel.implicitHeight + Kirigami.Units.smallSpacing
                    radius: 3
                    color: Kirigami.Theme.highlightColor
                    PlasmaComponents.Label {
                        id: planLabel
                        anchors.centerIn: parent
                        text: root.planName
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.highlightedTextColor
                    }
                }
            }

            // Error message
            Rectangle {
                visible: root.errorMsg !== ""
                Layout.fillWidth: true
                Layout.preferredHeight: errorColumn.implicitHeight + Kirigami.Units.largeSpacing
                radius: 5
                color: Kirigami.Theme.negativeBackgroundColor

                ColumnLayout {
                    id: errorColumn
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label {
                        text: "⚠ " + root.errorMsg
                        color: Kirigami.Theme.negativeTextColor
                        font.bold: true
                    }
                    PlasmaComponents.Label {
                        text: i18n.tr("Run 'claude' to log in")
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.negativeTextColor
                    }
                }
            }

            // Separator
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            // Session Usage
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        text: root.sessionLabel
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        text: root.sessionUsagePercent.toFixed(1) + "%"
                        color: getSessionColor()
                        font.bold: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 10
                    radius: 5
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.sessionUsagePercent / 100, 1)
                        height: parent.height
                        radius: 5
                        color: getSessionColor()
                    }
                }

                // Time elapsed bar
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.sessionResetTime !== null
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.fillWidth: true
                        height: 5
                        radius: 2
                        color: Kirigami.Theme.backgroundColor
                        border.color: Kirigami.Theme.disabledTextColor
                        border.width: 1
                        Rectangle {
                            width: parent.width * Math.min(root.sessionTimePercent / 100, 1)
                            height: parent.height
                            radius: 2
                            color: getSessionColor()
                        }
                    }

                    PlasmaComponents.Label {
                        text: root.sessionTimePercent.toFixed(0) + "%"
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: getSessionColor()
                        Layout.preferredWidth: implicitWidth
                    }
                }

                PlasmaComponents.Label {
                    visible: root.sessionReset !== ""
                    text: i18n.tr("Resets at:") + " " + root.sessionReset + (root.sessionResetTime ? " (" + formatTimeRemaining(root.sessionResetTime) + ")" : "")
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // Weekly Usage
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        text: root.weeklyLabel
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        text: root.weeklyUsagePercent.toFixed(1) + "%"
                        color: getWeeklyColor()
                        font.bold: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 10
                    radius: 5
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.weeklyUsagePercent / 100, 1)
                        height: parent.height
                        radius: 5
                        color: getWeeklyColor()
                    }
                }

                // Time elapsed bar
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.weeklyResetTime !== null
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.fillWidth: true
                        height: 5
                        radius: 2
                        color: Kirigami.Theme.backgroundColor
                        border.color: Kirigami.Theme.disabledTextColor
                        border.width: 1
                        Rectangle {
                            width: parent.width * Math.min(root.weeklyTimePercent / 100, 1)
                            height: parent.height
                            radius: 2
                            color: getWeeklyColor()
                        }
                    }

                    PlasmaComponents.Label {
                        text: root.weeklyTimePercent.toFixed(0) + "%"
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: getWeeklyColor()
                        Layout.preferredWidth: implicitWidth
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: root.weeklyReset !== ""

                    PlasmaComponents.Label {
                        text: i18n.tr("Resets:") + " " + root.weeklyReset + (root.weeklyResetTime ? " (" + formatTimeRemaining(root.weeklyResetTime) + ")" : "")
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.disabledTextColor
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        visible: root.weeklyResetTime !== null && root.weeklyUsagePercent < 100
                        text: i18n.tr("Pace:") + " " + formatPaceShort()
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: getPaceRequiredColor(root.requiredPace)
                    }
                }

            }

            // Separator (hidden for z.ai which has no model breakdown)
            Rectangle {
                visible: root.provider !== "zai"
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            // Model breakdown (collapsible) - hidden for z.ai
            RowLayout {
                Layout.fillWidth: true
                visible: root.provider !== "zai"

                MouseArea {
                    Layout.fillWidth: true
                    Layout.preferredHeight: modelHeaderLabel.implicitHeight
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.modelSectionExpanded = !root.modelSectionExpanded

                    RowLayout {
                        anchors.fill: parent
                        PlasmaComponents.Label {
                            id: modelHeaderLabel
                            text: (root.modelSectionExpanded ? "▾ " : "▸ ") + i18n.tr("By Model (Weekly)")
                            font.bold: true
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
            }

            // Sonnet (Claude)
            RowLayout {
                Layout.fillWidth: true
                visible: root.modelSectionExpanded && root.provider !== "zai" && root.sonnetWeeklyPercent > 0

                PlasmaComponents.Label {
                    text: i18n.tr("Sonnet")
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: 60
                    height: 8
                    radius: 3
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.sonnetWeeklyPercent / 100, 1)
                        height: parent.height
                        radius: 3
                        color: getUsageColor(root.sonnetWeeklyPercent)
                    }
                }
                PlasmaComponents.Label {
                    text: root.sonnetWeeklyPercent.toFixed(0) + "%"
                    Layout.preferredWidth: 40
                    horizontalAlignment: Text.AlignRight
                }
            }

            // Opus (Claude)
            RowLayout {
                Layout.fillWidth: true
                visible: root.modelSectionExpanded && root.provider !== "zai" && root.opusWeeklyPercent > 0

                PlasmaComponents.Label {
                    text: i18n.tr("Opus")
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: 60
                    height: 8
                    radius: 3
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.opusWeeklyPercent / 100, 1)
                        height: parent.height
                        radius: 3
                        color: getUsageColor(root.opusWeeklyPercent)
                    }
                }
                PlasmaComponents.Label {
                    text: root.opusWeeklyPercent.toFixed(0) + "%"
                    Layout.preferredWidth: 40
                    horizontalAlignment: Text.AlignRight
                }
            }

            // Additional rate limits (Codex Spark, etc.)
            Repeater {
                model: root.modelSectionExpanded ? root.additionalLimits : []

                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents.Label {
                        text: modelData.name
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        Layout.preferredWidth: 60
                        height: 8
                        radius: 3
                        color: Kirigami.Theme.backgroundColor
                        border.color: Kirigami.Theme.disabledTextColor
                        border.width: 1
                        Rectangle {
                            width: parent.width * Math.min(modelData.percent / 100, 1)
                            height: parent.height
                            radius: 3
                            color: getUsageColor(modelData.percent)
                        }
                    }
                    PlasmaComponents.Label {
                        text: modelData.percent.toFixed(0) + "%"
                        Layout.preferredWidth: 40
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }

            // No model data message
            PlasmaComponents.Label {
                visible: root.modelSectionExpanded && root.provider !== "zai" && root.sonnetWeeklyPercent === 0 && root.opusWeeklyPercent === 0 && root.additionalLimits.length === 0
                text: i18n.tr("No model breakdown available")
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.disabledTextColor
                font.italic: true
            }

            // Footer
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: root.lastUpdate !== "" ? i18n.tr("Updated:") + " " + root.lastUpdate : i18n.tr("Loading...")
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.Button {
                    icon.name: "view-refresh"
                    text: i18n.tr("Refresh")
                    onClicked: refresh()
                }
            }
        }
    }

    Timer {
        id: refreshTimer
        interval: (Plasmoid.configuration.refreshInterval || 1) * 60000
        running: true
        repeat: true
        onTriggered: loadCredentials()
    }

    Timer {
        id: timePercentTimer
        interval: 60000
        running: root.sessionResetTime !== null || root.weeklyResetTime !== null
        repeat: true
        onTriggered: {
            updateSessionTimePercent()
            updateWeeklyTimePercent()
            updateRequiredPace()
        }
    }

    function updateSessionTimePercent() {
        if (!root.sessionResetTime) return
        var now = new Date()
        var resetMs = root.sessionResetTime.getTime()
        var periodMs = 5 * 60 * 60 * 1000
        var startMs = resetMs - periodMs
        var elapsed = now.getTime() - startMs
        root.sessionTimePercent = Math.max(0, Math.min(100, (elapsed / periodMs) * 100))
    }

    function updateWeeklyTimePercent() {
        if (!root.weeklyResetTime) return
        var now = new Date()
        var resetMs = root.weeklyResetTime.getTime()
        var periodMs = root.weeklyPeriodMs
        var startMs = resetMs - periodMs
        var elapsed = now.getTime() - startMs
        root.weeklyTimePercent = Math.max(0, Math.min(100, (elapsed / periodMs) * 100))
    }

    function getPaceColor(usagePercent, timePercent) {
        if (timePercent < 1) timePercent = 1
        var pace = usagePercent / timePercent
        if (pace < 0.8) return Kirigami.Theme.positiveTextColor
        if (pace < 1.1) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function updateRequiredPace() {
        if (!root.weeklyResetTime) {
            root.requiredPace = 0
            return
        }
        var ratio = Plasmoid.configuration.sessionWeeklyRatio || 10
        var remainingWeekly = 100 - root.weeklyUsagePercent
        if (remainingWeekly <= 0) {
            root.requiredPace = 0
            return
        }
        var hoursNeeded = (remainingWeekly / ratio) * 5
        var now = new Date()
        var hoursRemaining = (root.weeklyResetTime.getTime() - now.getTime()) / 3600000
        if (hoursRemaining <= 0) {
            root.requiredPace = 999
            return
        }
        root.requiredPace = hoursNeeded / hoursRemaining
    }

    function formatPace() {
        var fmt = Plasmoid.configuration.paceFormat || "percent"
        var ratio = Plasmoid.configuration.sessionWeeklyRatio || 10
        var remainingWeekly = 100 - root.weeklyUsagePercent
        var hoursNeeded = Math.max(0, (remainingWeekly / ratio) * 5)
        var hoursRemaining = 0
        if (root.weeklyResetTime) {
            hoursRemaining = Math.max(0, (root.weeklyResetTime.getTime() - new Date().getTime()) / 3600000)
        }
        var sessionsNeeded = hoursNeeded / 5
        var sessionsRemaining = hoursRemaining / 5

        if (fmt === "sessions") {
            return i18n.tr("Pace:") + " " + sessionsNeeded.toFixed(1) + " / " + sessionsRemaining.toFixed(1)
        } else if (fmt === "hours") {
            return i18n.tr("Pace:") + " " + hoursNeeded.toFixed(1) + i18n.tr("h") + " / " + hoursRemaining.toFixed(1) + i18n.tr("h")
        }
        return i18n.tr("Pace:") + " " + Math.round(root.requiredPace * 100) + "%"
    }

    function formatPaceShort() {
        var fmt = Plasmoid.configuration.paceFormat || "percent"
        var ratio = Plasmoid.configuration.sessionWeeklyRatio || 10
        var remainingWeekly = 100 - root.weeklyUsagePercent
        var hoursNeeded = Math.max(0, (remainingWeekly / ratio) * 5)
        var hoursRemaining = 0
        if (root.weeklyResetTime) {
            hoursRemaining = Math.max(0, (root.weeklyResetTime.getTime() - new Date().getTime()) / 3600000)
        }
        var sessionsNeeded = hoursNeeded / 5
        var sessionsRemaining = hoursRemaining / 5

        if (fmt === "sessions") {
            return sessionsNeeded.toFixed(1) + " / " + sessionsRemaining.toFixed(1)
        } else if (fmt === "hours") {
            return hoursNeeded.toFixed(0) + i18n.tr("h") + " / " + hoursRemaining.toFixed(0) + i18n.tr("h")
        }
        return Math.round(root.requiredPace * 100) + "%"
    }

    function getPaceRequiredColor(pace) {
        if (pace < 0.5) return Kirigami.Theme.positiveTextColor
        if (pace < 0.85) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function getUsageColor(percent) {
        if (percent < 50) return Kirigami.Theme.positiveTextColor
        if (percent < 80) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    // Capacity mode: green when under pace, warns as you go over
    function capacityPaceColor(pace) {
        if (pace <= 1.0) return Kirigami.Theme.positiveTextColor
        if (pace < 2.0) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    // Efficiency mode: green when on pace (~1.0), orange when deviating, red when very over, blue when way under
    function efficiencyPaceColor(pace) {
        if (pace >= 0.8 && pace <= 1.1) return Kirigami.Theme.positiveTextColor
        if (pace < 0.4) return Kirigami.Theme.activeTextColor
        if (pace < 0.8) return Kirigami.Theme.neutralTextColor
        if (pace < 1.5) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function getSessionColor() {
        if (root.sessionTimePercent > 0) {
            var timeP = Math.max(1, root.sessionTimePercent)
            var pace = root.sessionUsagePercent / timeP
            var mode = Plasmoid.configuration.sessionColorMode || "capacity"
            return mode === "efficiency" ? efficiencyPaceColor(pace) : capacityPaceColor(pace)
        }
        return getUsageColor(root.sessionUsagePercent)
    }

    function getWeeklyColor() {
        if (root.weeklyTimePercent > 0) {
            var timeP = Math.max(1, root.weeklyTimePercent)
            var pace = root.weeklyUsagePercent / timeP
            var mode = Plasmoid.configuration.weeklyColorMode || "efficiency"
            return mode === "efficiency" ? efficiencyPaceColor(pace) : capacityPaceColor(pace)
        }
        return getUsageColor(root.weeklyUsagePercent)
    }

    function formatTimeRemaining(resetTime) {
        if (!resetTime) return ""
        var now = new Date()
        var diff = resetTime.getTime() - now.getTime()
        if (diff <= 0) return ""

        var hours = Math.floor(diff / (1000 * 60 * 60))
        var minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60))

        if (hours > 24) {
            var days = Math.floor(hours / 24)
            hours = hours % 24
            return days + i18n.tr("d") + " " + hours + i18n.tr("h")
        } else if (hours > 0) {
            return hours + i18n.tr("h") + " " + minutes + i18n.tr("m")
        } else {
            return minutes + i18n.tr("m")
        }
    }

    Component.onCompleted: {
        console.log("Claude Usage: Widget loaded")
        loadCredentials()
    }

    Plasmoid.icon: "claude-usage"
    toolTipMainText: root.displayName + " " + i18n.tr("Usage")
    toolTipSubText: root.sessionLabel + ": " + Math.round(root.sessionUsagePercent) + "% | " + root.weeklyLabel + ": " + Math.round(root.weeklyUsagePercent) + "%"
}
