/**
 * Load a QML .pragma library JS file into a plain Node object.
 * Strips QML pragma/import lines and injects named dependencies.
 */
import { readFileSync } from "node:fs"

export function loadQmlJs(path, injected, exportedNames) {
    const source = readFileSync(path, "utf8")
        .replace(/^\s*\.pragma library\s*$/gm, "")
        .replace(/^\s*\.import[^\n]*$/gm, "")
    const names = Object.keys(injected || {})
    const exports = {}
    const exportCode = exportedNames
        .map(name => `exports.${name} = ${name};`)
        .join("\n")
    new Function(...names, "exports", source + "\n" + exportCode)(
        ...names.map(name => injected[name]), exports
    )
    return exports
}
