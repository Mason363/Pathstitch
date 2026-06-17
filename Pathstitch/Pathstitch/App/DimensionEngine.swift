import Foundation

/// One parametric dimension variable (MAS-110). Holds the raw expression the user
/// typed, its last evaluated value (mm), and whether it is a driven / reference
/// dimension (shown in parentheses, calculated by other geometry, not editable).
struct DimensionParameter: Identifiable, Codable, Hashable {
    var id: String          // "d1", "d2", …
    var expression: String  // raw text, e.g. "20*2", "(d1*0.5)+10", "50"
    var value: Double       // last evaluated value in mm
    var driven: Bool = false

    /// True when the expression is a plain number (no variables / math) — those
    /// render as the value; everything else renders with the `fx:` prefix.
    var isFormula: Bool {
        Double(expression.trimmingCharacters(in: .whitespaces)) == nil
    }
}

/// Errors surfaced to the UI (red field flash + message) when a formula can't be
/// committed (MAS-110 §4 / MAS-111 error handling).
enum DimensionError: LocalizedError, Equatable {
    case syntax(String)
    case unknownVariable(String)
    case circular(String)
    case divideByZero

    var errorDescription: String? {
        switch self {
        case .syntax(let s): return "Invalid expression: \(s)"
        case .unknownVariable(let v): return "Unknown variable “\(v)”"
        case .circular(let v): return "Circular dependency detected (\(v))"
        case .divideByZero: return "Division by zero"
        }
    }
}

/// The sketch parameter table + a small recursive-descent expression evaluator.
///
/// Supports: decimal numbers with optional unit suffix (mm / cm / m / in / inch /
/// "), the operators `+ - * / ^`, unary minus, parentheses, the `sqrt(...)`
/// function, and references to other parameters by name (`d1`, `d2`, …). All
/// values are stored internally in millimetres. Assigning an expression
/// re-evaluates every dependent parameter and rejects circular references.
struct DimensionEngine: Codable, Equatable {
    private(set) var params: [DimensionParameter] = []

    // MARK: Table management

    func parameter(_ id: String) -> DimensionParameter? {
        params.first { $0.id == id }
    }

    /// Next free sequential variable name (`d1`, `d2`, …).
    func nextVarName() -> String {
        var n = 1
        let used = Set(params.map { $0.id })
        while used.contains("d\(n)") { n += 1 }
        return "d\(n)"
    }

    /// Create a parameter with a fixed numeric value (no formula). Returns its id.
    @discardableResult
    mutating func addNumeric(value: Double, id: String? = nil, driven: Bool = false) -> String {
        let name = id ?? nextVarName()
        params.removeAll { $0.id == name }
        params.append(DimensionParameter(id: name, expression: trimmed(value), value: value, driven: driven))
        return name
    }

    mutating func remove(_ id: String) {
        params.removeAll { $0.id == id }
    }

    /// Assign / update a parameter's expression. Re-evaluates the parameter and all
    /// of its dependents, rejecting cycles and bad references. Throws on failure
    /// and leaves the table unchanged.
    mutating func setExpression(_ id: String, _ expression: String, driven: Bool? = nil) throws {
        // Build a trial graph with the new expression in place.
        var trial = params
        if let idx = trial.firstIndex(where: { $0.id == id }) {
            trial[idx].expression = expression
            if let driven = driven { trial[idx].driven = driven }
        } else {
            trial.append(DimensionParameter(id: id, expression: expression, value: 0, driven: driven ?? false))
        }

        // Cycle check via DFS over variable references.
        let exprById = Dictionary(uniqueKeysWithValues: trial.map { ($0.id, $0.expression) })
        try assertNoCycle(start: id, exprById: exprById)

        // Topologically evaluate so dependents see fresh values.
        var values: [String: Double] = [:]
        var visiting: Set<String> = []
        func resolve(_ name: String) throws -> Double {
            if let v = values[name] { return v }
            guard let expr = exprById[name] else { throw DimensionError.unknownVariable(name) }
            visiting.insert(name)
            let v = try Self.eval(expr) { ref in
                guard exprById[ref] != nil else { throw DimensionError.unknownVariable(ref) }
                return try resolve(ref)
            }
            visiting.remove(name)
            values[name] = v
            return v
        }
        for p in trial { _ = try resolve(p.id) }

        // Commit.
        params = trial.map { var p = $0; p.value = values[$0.id] ?? $0.value; return p }
    }

    private func assertNoCycle(start: String, exprById: [String: String]) throws {
        var stack: Set<String> = []
        func dfs(_ name: String) throws {
            if stack.contains(name) { throw DimensionError.circular(name) }
            stack.insert(name)
            for ref in Self.referencedVars(in: exprById[name] ?? "") where exprById[ref] != nil {
                try dfs(ref)
            }
            stack.remove(name)
        }
        try dfs(start)
    }

    /// Evaluate a one-off expression against the current table (used by the live
    /// floating input before committing). Throws on bad syntax / unknown var.
    func preview(_ expression: String) throws -> Double {
        let byId = Dictionary(uniqueKeysWithValues: params.map { ($0.id, $0.value) })
        return try Self.eval(expression) { ref in
            guard let v = byId[ref] else { throw DimensionError.unknownVariable(ref) }
            return v
        }
    }

    // MARK: Display helpers

    /// Canvas label for a parameter: `fx: 30.00` for formulas (hover reveals the
    /// raw equation), `(30.00 mm)` for driven/reference, plain `30.00 mm` else.
    static func label(value: Double, expression: String, driven: Bool) -> String {
        let v = String(format: "%.2f", value)
        let isFormula = Double(expression.trimmingCharacters(in: .whitespaces)) == nil
        if driven { return "(\(v) mm)" }
        if isFormula { return "fx: \(v)" }
        return "\(v) mm"
    }

    private func trimmed(_ v: Double) -> String {
        // 30.0 → "30", 30.5 → "30.5"
        if v == v.rounded() { return String(Int(v.rounded())) }
        return String(format: "%g", v)
    }

    // MARK: Expression evaluator (static, pure)

    /// Variable names referenced in an expression (identifiers that aren't the
    /// `sqrt` function).
    static func referencedVars(in expr: String) -> Set<String> {
        var out: Set<String> = []
        var cur = ""
        func flush() {
            if !cur.isEmpty && cur != "sqrt" && Double(cur) == nil { out.insert(cur) }
            cur = ""
        }
        for ch in expr {
            if ch.isLetter || ch.isNumber || ch == "_" { cur.append(ch) } else { flush() }
        }
        flush()
        // Drop unit suffixes that attached to numbers (handled by the lexer).
        return out.subtracting(["mm", "cm", "m", "in", "inch"])
    }

    /// Evaluate `expr`, resolving variable references through `resolveVar`.
    static func eval(_ expr: String, resolveVar: @escaping (String) throws -> Double) throws -> Double {
        var parser = Parser(expr, resolveVar: resolveVar)
        let v = try parser.parseExpression()
        try parser.expectEnd()
        return v
    }

    /// Recursive-descent parser:  expr → term (('+'|'-') term)*;  term → power
    /// (('*'|'/') power)*;  power → unary ('^' power)?;  unary → '-' unary | atom;
    /// atom → number[unit] | ident | sqrt(expr) | '(' expr ')'.
    private struct Parser {
        let s: [Character]
        var i = 0
        let resolveVar: (String) throws -> Double

        init(_ text: String, resolveVar: @escaping (String) throws -> Double) {
            self.s = Array(text)
            self.resolveVar = resolveVar
        }

        mutating func skipSpace() { while i < s.count, s[i] == " " { i += 1 } }
        func peek() -> Character? { i < s.count ? s[i] : nil }

        mutating func parseExpression() throws -> Double {
            var v = try parseTerm()
            while true {
                skipSpace()
                guard let c = peek(), c == "+" || c == "-" else { break }
                i += 1
                let rhs = try parseTerm()
                v = (c == "+") ? v + rhs : v - rhs
            }
            return v
        }

        mutating func parseTerm() throws -> Double {
            var v = try parsePower()
            while true {
                skipSpace()
                guard let c = peek(), c == "*" || c == "/" else { break }
                i += 1
                let rhs = try parsePower()
                if c == "/" {
                    if abs(rhs) < 1e-12 { throw DimensionError.divideByZero }
                    v /= rhs
                } else { v *= rhs }
            }
            return v
        }

        mutating func parsePower() throws -> Double {
            let base = try parseUnary()
            skipSpace()
            if peek() == "^" {
                i += 1
                let exp = try parsePower()   // right-associative
                return pow(base, exp)
            }
            return base
        }

        mutating func parseUnary() throws -> Double {
            skipSpace()
            if peek() == "-" { i += 1; return -(try parseUnary()) }
            if peek() == "+" { i += 1; return try parseUnary() }
            return try parseAtom()
        }

        mutating func parseAtom() throws -> Double {
            skipSpace()
            guard let c = peek() else { throw DimensionError.syntax("unexpected end") }
            if c == "(" {
                i += 1
                let v = try parseExpression()
                skipSpace()
                guard peek() == ")" else { throw DimensionError.syntax("missing )") }
                i += 1
                return v
            }
            if c.isNumber || c == "." {
                return try parseNumberWithUnit()
            }
            if c.isLetter {
                let name = parseIdentifier()
                if name == "sqrt" {
                    skipSpace()
                    guard peek() == "(" else { throw DimensionError.syntax("sqrt needs (") }
                    i += 1
                    let v = try parseExpression()
                    skipSpace()
                    guard peek() == ")" else { throw DimensionError.syntax("missing )") }
                    i += 1
                    return sqrt(v)
                }
                return try resolveVar(name)
            }
            throw DimensionError.syntax("unexpected “\(c)”")
        }

        mutating func parseIdentifier() -> String {
            var out = ""
            while i < s.count, s[i].isLetter || s[i].isNumber || s[i] == "_" { out.append(s[i]); i += 1 }
            return out
        }

        /// A number, optionally followed by a unit suffix that converts to mm.
        mutating func parseNumberWithUnit() throws -> Double {
            var num = ""
            while i < s.count, s[i].isNumber || s[i] == "." { num.append(s[i]); i += 1 }
            guard let base = Double(num) else { throw DimensionError.syntax("bad number") }
            // Optional unit (no space allowed inside, but "1 inch" is common, so we
            // also peek across a single space when the next token is alphabetic).
            let save = i
            skipSpace()
            var unit = ""
            while i < s.count, s[i].isLetter { unit.append(s[i]); i += 1 }
            switch unit.lowercased() {
            case "mm", "": if unit.isEmpty { i = save }; return base
            case "cm": return base * 10.0
            case "m":  return base * 1000.0
            case "in", "inch", "inches", "\"": return base * 25.4
            default:
                // Not a unit — it's a following variable/operator; rewind.
                i = save
                return base
            }
        }

        mutating func expectEnd() throws {
            skipSpace()
            if i < s.count { throw DimensionError.syntax("trailing “\(String(s[i...]))”") }
        }
    }
}
