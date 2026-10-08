import Foundation

/// The same closed vector dialect accepted by the server. Never resolves entities or URLs.
enum SVGMarkupValidator {
    static func accepts(_ markup: String) -> Bool {
        guard !markup.isEmpty, markup.utf8.count <= 80_000,
              !markup.contains("&"), !markup.contains("<!"), !markup.contains("<?") else { return false }
        let delegate = VectorXMLDelegate()
        let parser = XMLParser(data: Data(markup.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() && delegate.valid && delegate.root == "svg" && delegate.references.allSatisfy { id, attribute in
            attribute == "clip-path" ? delegate.ids[id] == "clipPath"
                : ["linearGradient", "radialGradient"].contains(delegate.ids[id] ?? "")
        }
    }
}
private final class VectorXMLDelegate: NSObject, XMLParserDelegate {
    let tags = Set("""
        svg g path rect circle ellipse polygon polyline line defs linearGradient radialGradient stop clipPath
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    let attributes = Set("""
        xmlns viewBox width height x y x1 y1 x2 y2 cx cy r rx ry d points fill stroke stroke-width stroke-linecap stroke-linejoin
        stroke-dasharray fill-rule clip-rule opacity fill-opacity stroke-opacity transform id clip-path clipPathUnits offset
        stop-color stop-opacity gradientUnits gradientTransform
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    var valid = true
    var root: String?
    var ids: [String: String] = [:]
    var references: [(String, String)] = []
    var stack: [String] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes values: [String: String]) {
        if root == nil { root = elementName }
        if !tags.contains(elementName) { valid = false }
        if stack.count > 32 || (elementName == "svg" && !stack.isEmpty) { valid = false }
        if elementName == "clipPath", values["clipPathUnits"] != "userSpaceOnUse" { valid = false }
        for (key, value) in values {
            if !attributes.contains(key) { valid = false }
            if key == "id" {
                if value.range(of: "^[A-Za-z][A-Za-z0-9_-]*$", options: .regularExpression) == nil || ids[value] != nil { valid = false }
                ids[value] = elementName
            }
            if value.hasPrefix("url(#"), value.hasSuffix(")") {
                if stack.contains("defs") || elementName == "clipPath" || !["fill", "stroke", "clip-path"].contains(key) { valid = false }
                references.append((String(value.dropFirst(5).dropLast()), key))
            }
            if key == "xmlns" {
                if value != "http://www.w3.org/2000/svg" { valid = false }
            } else if value.contains(":") || value.contains("\\") || value.contains("@") {
                valid = false
            } else if value.contains("url("), value.range(of: "^url\\(#[A-Za-z][A-Za-z0-9_-]*\\)$", options: .regularExpression) == nil {
                valid = false
            }
        }
        if !valid { parser.abortParsing() }
        stack.append(elementName)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { valid = false; parser.abortParsing() }
    }
}
