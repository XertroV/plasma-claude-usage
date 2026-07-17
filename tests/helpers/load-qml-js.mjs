import { readFileSync } from "node:fs"

/**
 * Load a QML-compatible .js library into a Node Function sandbox.
 * Strips `.pragma library` / `.import` lines and returns selected exports.
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
