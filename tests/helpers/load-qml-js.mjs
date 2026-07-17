import { readFileSync } from "node:fs"

/**
 * Load a QML `.pragma library` JS file into a plain Node sandbox.
 * Strips `.pragma` / `.import` lines and injects named dependencies
 * (e.g. QC, QP) that the library would normally import.
 */
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
