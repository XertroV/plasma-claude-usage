import { readFileSync } from "node:fs"

/**
 * Load a QML `.pragma library` JS file into Node for unit tests.
 * Strips QML directives; injects named deps; returns selected exports.
 *
 * @param {string} path - absolute path to the .js file
 * @param {Record<string, unknown>} [injected] - name → value injected as free variables
 * @param {string[]} [exportedNames] - top-level names to export
 * @returns {Record<string, unknown>}
 */
export function loadQmlJs(path, injected, exportedNames) {
    const source = readFileSync(path, "utf8")
        .replace(/^\s*\.pragma library\s*$/gm, "")
        .replace(/^\s*\.import[^\n]*$/gm, "")
    const names = Object.keys(injected || {})
    const exports = {}
    const exportCode = (exportedNames || [])
        .map(name => `exports.${name} = ${name};`)
        .join("\n")
    new Function(...names, "exports", source + "\n" + exportCode)(
        ...names.map(name => injected[name]), exports
    )
    return exports
}
