// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.dimacs;

import reify.errors : NavokojException;

import std.algorithm : sort;
import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.string : lineSplitter, split, startsWith, strip;

/**
 * Resource limits applied while parsing, validating, or serializing DIMACS.
 *
 * The defaults align with navokoj-app's encoded-model safeguards. Callers
 * importing larger trusted instances can raise them explicitly.
 */
struct DimacsLimits {
    size_t maxVariables = 1_000_000;
    size_t maxClauses = 5_000_000;
    size_t maxLiterals = 50_000_000;
}

/**
 * Controls which optional metadata is included by the DIMACS serializer.
 */
struct DimacsSerializeOptions {
    bool includeName = true;
    bool includeComments = true;
    bool includeVariableLabels = true;
    bool trailingNewline = true;
}

/**
 * A malformed or resource-exceeding DIMACS input.
 */
class DimacsException : NavokojException {
    size_t inputLine;

    this(
        string message,
        size_t inputLine = 0,
        string file = __FILE__,
        size_t line = __LINE__
    ) {
        super(
            inputLine == 0
                ? "Invalid DIMACS CNF: " ~ message
                : format(
                    "Invalid DIMACS CNF at line %s: %s",
                    inputLine,
                    message
                ),
            file,
            line
        );
        this.inputLine = inputLine;
    }
}

/**
 * A validated CNF instance using one-based DIMACS variable numbers.
 *
 * `variableLabels` is keyed by the one-based variable number. `comments`
 * stores unstructured comment bodies without the leading `c`; recognized
 * `c varname ...`, `c name: ...`, and `c description: ...` metadata is
 * represented by `variableLabels` and `name` instead.
 */
struct DimacsInstance {
    size_t numVariables;
    int[][] clauses;
    string[size_t] variableLabels;
    string[] comments;
    string name;

    /**
     * Validate a programmatically constructed instance.
     */
    void validate(DimacsLimits limits = DimacsLimits()) const {
        if (numVariables > limits.maxVariables) {
            throw new DimacsException(format(
                "variable count %s exceeds configured limit %s",
                numVariables,
                limits.maxVariables
            ));
        }
        if (numVariables > int.max) {
            throw new DimacsException(format(
                "variable count %s exceeds the largest representable literal %s",
                numVariables,
                int.max
            ));
        }
        if (clauses.length > limits.maxClauses) {
            throw new DimacsException(format(
                "clause count %s exceeds configured limit %s",
                clauses.length,
                limits.maxClauses
            ));
        }

        size_t literalCount;
        foreach (clauseIndex, clause; clauses) {
            if (
                clause.length > limits.maxLiterals ||
                literalCount > limits.maxLiterals - clause.length
            ) {
                throw new DimacsException(format(
                    "literal count exceeds configured limit %s at clause %s",
                    limits.maxLiterals,
                    clauseIndex + 1
                ));
            }
            literalCount += clause.length;

            foreach (literal; clause) {
                if (literal == 0) {
                    throw new DimacsException(format(
                        "clause %s contains literal zero; zero is only a " ~
                        "DIMACS clause terminator",
                        clauseIndex + 1
                    ));
                }
                const magnitude = literal < 0
                    ? -cast(long) literal
                    : cast(long) literal;
                if (
                    magnitude < 1 ||
                    cast(ulong) magnitude > numVariables
                ) {
                    throw new DimacsException(format(
                        "literal %s in clause %s is outside declared range 1..%s",
                        literal,
                        clauseIndex + 1,
                        numVariables
                    ));
                }
            }
        }

        validateSingleLineMetadata(name, "instance name");
        foreach (commentIndex, comment; comments) {
            validateSingleLineMetadata(
                comment,
                format("comment %s", commentIndex + 1)
            );
        }
        foreach (variable, label; variableLabels) {
            if (variable == 0 || variable > numVariables) {
                throw new DimacsException(format(
                    "variable label ID %s is outside declared range 1..%s",
                    variable,
                    numVariables
                ));
            }
            if (label.length == 0) {
                throw new DimacsException(format(
                    "variable label %s cannot be empty",
                    variable
                ));
            }
            validateSingleLineMetadata(
                label,
                format("variable label %s", variable)
            );
        }
    }

    /**
     * Render canonical DIMACS: metadata comments, one header, and one
     * zero-terminated clause per line. Empty clauses serialize as `0`.
     */
    string toDimacs(
        DimacsSerializeOptions options = DimacsSerializeOptions(),
        DimacsLimits limits = DimacsLimits()
    ) const {
        validate(limits);

        auto output = appender!string();
        if (options.includeName && name.length != 0) {
            appendComment(output, "name: " ~ name);
        }
        if (options.includeComments) {
            foreach (comment; comments) {
                appendComment(output, comment);
            }
        }
        if (options.includeVariableLabels) {
            foreach (variable; sortedVariableLabelIds(variableLabels)) {
                appendComment(
                    output,
                    "varname " ~ variable.to!string ~ " " ~
                        variableLabels[variable]
                );
            }
        }

        output.put("p cnf ");
        output.put(numVariables.to!string);
        output.put(" ");
        output.put(clauses.length.to!string);
        output.put("\n");

        foreach (clause; clauses) {
            foreach (literal; clause) {
                output.put(literal.to!string);
                output.put(" ");
            }
            output.put("0\n");
        }

        auto rendered = output.data;
        if (!options.trailingNewline && rendered.length != 0) {
            rendered = rendered[0 .. $ - 1];
        }
        return rendered;
    }

    /**
     * Adapt this instance to navokoj-app's compact raw-CNF document shape.
     *
     * Clauses remain numbered literals under `cnf`; they are not expanded into
     * Boolean variables or expression AST nodes.
     */
    JSONValue toDocumentJson(DimacsLimits limits = DimacsLimits()) const {
        validate(limits);

        JSONValue[] clauseValues;
        foreach (clause; clauses) {
            JSONValue[] literalValues;
            foreach (literal; clause) {
                literalValues ~= JSONValue(cast(long) literal);
            }
            clauseValues ~= JSONValue(literalValues);
        }

        JSONValue[string] cnf;
        cnf["num_vars"] = JSONValue(cast(long) numVariables);
        cnf["clauses"] = JSONValue(clauseValues);

        if (variableLabels.length != 0) {
            JSONValue[string] labels;
            foreach (variable; sortedVariableLabelIds(variableLabels)) {
                labels[variable.to!string] =
                    JSONValue(variableLabels[variable]);
            }
            cnf["variable_labels"] = JSONValue(labels);
        }
        if (comments.length != 0) {
            JSONValue[] commentValues;
            foreach (comment; comments) {
                commentValues ~= JSONValue(comment);
            }
            cnf["comments"] = JSONValue(commentValues);
        }

        JSONValue[string] document;
        if (name.length != 0) {
            document["name"] = JSONValue(name);
        }
        document["cnf"] = JSONValue(cnf);
        return JSONValue(document);
    }
}

/**
 * Parse a complete DIMACS CNF string.
 *
 * Comments and blank lines may occur anywhere. Exactly one `p cnf N M`
 * header is required before clause data. Clause boundaries are defined by
 * zero tokens, so clauses may span lines and multiple clauses may share a
 * line.
 */
DimacsInstance parseDimacs(
    string source,
    DimacsLimits limits = DimacsLimits()
) {
    return new DimacsParser(source, limits).parse();
}

/**
 * Parse DIMACS and immediately return the compact navokoj-app document.
 */
JSONValue dimacsToDocumentJson(
    string source,
    DimacsLimits limits = DimacsLimits()
) {
    return parseDimacs(source, limits).toDocumentJson(limits);
}

/**
 * Serialize an instance as canonical DIMACS.
 */
string serializeDimacs(
    const ref DimacsInstance instance,
    DimacsSerializeOptions options = DimacsSerializeOptions(),
    DimacsLimits limits = DimacsLimits()
) {
    return instance.toDimacs(options, limits);
}

private final class DimacsParser {
    string source;
    DimacsLimits limits;
    DimacsInstance instance;
    bool hasHeader;
    size_t expectedClauses;
    size_t totalLiterals;
    int[] currentClause;
    bool hasExplicitName;
    bool hasDescription;

    this(string source, DimacsLimits limits) {
        this.source = source;
        this.limits = limits;
    }

    DimacsInstance parse() {
        size_t lineNumber;
        foreach (rawLine; source.lineSplitter()) {
            ++lineNumber;
            const line = rawLine.strip;
            if (line.length == 0) {
                continue;
            }

            if (line[0] == 'c') {
                parseComment(line[1 .. $].strip, lineNumber);
                continue;
            }
            if (line[0] == 'p') {
                parseHeader(line, lineNumber);
                continue;
            }
            if (!hasHeader) {
                fail(
                    "clause data appears before the `p cnf` header",
                    lineNumber
                );
            }
            parseClauseTokens(line, lineNumber);
        }

        if (!hasHeader) {
            fail("missing `p cnf <variables> <clauses>` header", 0);
        }
        if (currentClause.length != 0) {
            fail("last clause is missing its zero terminator", lineNumber);
        }
        if (instance.clauses.length != expectedClauses) {
            fail(
                format(
                    "header declares %s clauses but input contains %s",
                    expectedClauses,
                    instance.clauses.length
                ),
                0
            );
        }

        instance.validate(limits);
        return instance;
    }

    private void parseHeader(string line, size_t lineNumber) {
        if (hasHeader) {
            fail("multiple problem headers are not allowed", lineNumber);
        }
        if (instance.clauses.length != 0 || currentClause.length != 0) {
            fail("problem header must precede all clause data", lineNumber);
        }

        const fields = line.split();
        if (
            fields.length != 4 ||
            fields[0] != "p" ||
            fields[1] != "cnf"
        ) {
            fail(
                "problem header must be exactly `p cnf <variables> <clauses>`",
                lineNumber
            );
        }

        const numVariables = parseUnsigned(
            fields[2],
            lineNumber,
            "variable count"
        );
        const numClauses = parseUnsigned(
            fields[3],
            lineNumber,
            "clause count"
        );
        if (numVariables > limits.maxVariables) {
            fail(
                format(
                    "variable count %s exceeds configured limit %s",
                    numVariables,
                    limits.maxVariables
                ),
                lineNumber
            );
        }
        if (numVariables > int.max) {
            fail(
                format(
                    "variable count %s exceeds the largest representable " ~
                    "literal %s",
                    numVariables,
                    int.max
                ),
                lineNumber
            );
        }
        if (numClauses > limits.maxClauses) {
            fail(
                format(
                    "clause count %s exceeds configured limit %s",
                    numClauses,
                    limits.maxClauses
                ),
                lineNumber
            );
        }

        instance.numVariables = numVariables;
        expectedClauses = numClauses;
        hasHeader = true;
    }

    private void parseComment(string body, size_t lineNumber) {
        size_t cursor;
        const first = nextToken(body, cursor);
        if (first == "varname") {
            const idToken = nextToken(body, cursor);
            const label = body[cursor .. $].strip;
            if (idToken.length == 0 || label.length == 0) {
                fail(
                    "variable-name comment must be `c varname <id> <label>`",
                    lineNumber
                );
            }
            const variable = parseUnsigned(
                idToken,
                lineNumber,
                "variable label ID"
            );
            if (variable == 0) {
                fail("variable label ID must be nonzero", lineNumber);
            }
            if (
                hasHeader &&
                variable > instance.numVariables
            ) {
                fail(
                    format(
                        "variable label ID %s exceeds declared variable count %s",
                        variable,
                        instance.numVariables
                    ),
                    lineNumber
                );
            }
            if ((variable in instance.variableLabels) !is null) {
                fail(
                    format("duplicate label for variable %s", variable),
                    lineNumber
                );
            }
            validateSingleLineMetadata(
                label,
                format("variable label %s", variable),
                lineNumber
            );
            instance.variableLabels[variable] = label;
            return;
        }

        if (body.startsWith("name:")) {
            const parsedName = body["name:".length .. $].strip;
            if (parsedName.length == 0) {
                fail("name comment cannot be empty", lineNumber);
            }
            if (hasExplicitName) {
                fail("multiple name comments are not allowed", lineNumber);
            }
            instance.name = parsedName;
            hasExplicitName = true;
            return;
        }

        if (body.startsWith("description:")) {
            const description =
                body["description:".length .. $].strip;
            if (description.length == 0) {
                fail("description comment cannot be empty", lineNumber);
            }
            if (hasDescription) {
                fail(
                    "multiple description comments are not allowed",
                    lineNumber
                );
            }
            if (!hasExplicitName) {
                instance.name = description;
            }
            hasDescription = true;
            return;
        }

        instance.comments ~= body;
    }

    private void parseClauseTokens(string line, size_t lineNumber) {
        size_t cursor;
        while (true) {
            const token = nextToken(line, cursor);
            if (token.length == 0) {
                break;
            }

            const value = parseLiteral(token, lineNumber);
            if (value == 0) {
                if (instance.clauses.length >= expectedClauses) {
                    fail(
                        format(
                            "input contains more than the %s clauses declared " ~
                            "by the header",
                            expectedClauses
                        ),
                        lineNumber
                    );
                }
                if (instance.clauses.length >= limits.maxClauses) {
                    fail(
                        format(
                            "clause count exceeds configured limit %s",
                            limits.maxClauses
                        ),
                        lineNumber
                    );
                }
                instance.clauses ~= currentClause;
                currentClause = null;
                continue;
            }

            if (totalLiterals >= limits.maxLiterals) {
                fail(
                    format(
                        "literal count exceeds configured limit %s",
                        limits.maxLiterals
                    ),
                    lineNumber
                );
            }
            ++totalLiterals;
            currentClause ~= value;
        }
    }

    private int parseLiteral(string token, size_t lineNumber) {
        bool negative;
        size_t cursor;
        if (token[0] == '-') {
            negative = true;
            cursor = 1;
        }
        if (cursor == token.length) {
            fail("literal sign must be followed by digits", lineNumber);
        }

        uint magnitude;
        foreach (character; token[cursor .. $]) {
            if (character < '0' || character > '9') {
                fail(
                    "clause entries must be signed decimal integers",
                    lineNumber
                );
            }
            const digit = cast(uint) character - cast(uint) '0';
            if (magnitude > (cast(uint) int.max - digit) / 10) {
                fail(
                    format(
                        "literal token exceeds supported range -%s..%s",
                        int.max,
                        int.max
                    ),
                    lineNumber
                );
            }
            magnitude = magnitude * 10 + digit;
        }

        if (magnitude == 0) {
            if (negative) {
                fail(
                    "negative zero is not a valid clause terminator",
                    lineNumber
                );
            }
            return 0;
        }
        if (magnitude > instance.numVariables) {
            fail(
                format(
                    "literal %s%s exceeds declared variable count %s",
                    negative ? "-" : "",
                    magnitude,
                    instance.numVariables
                ),
                lineNumber
            );
        }

        return negative
            ? -cast(int) magnitude
            : cast(int) magnitude;
    }

    private void fail(string message, size_t lineNumber) {
        throw new DimacsException(message, lineNumber);
    }
}

private size_t parseUnsigned(
    string token,
    size_t lineNumber,
    string field
) {
    if (token.length == 0) {
        throw new DimacsException(field ~ " cannot be empty", lineNumber);
    }

    size_t value;
    foreach (character; token) {
        if (character < '0' || character > '9') {
            throw new DimacsException(
                field ~ " must be a non-negative decimal integer",
                lineNumber
            );
        }
        const digit = cast(size_t) character - cast(size_t) '0';
        if (value > (size_t.max - digit) / 10) {
            throw new DimacsException(
                field ~ " exceeds the platform integer range",
                lineNumber
            );
        }
        value = value * 10 + digit;
    }
    return value;
}

private string nextToken(string text, ref size_t cursor) {
    while (cursor < text.length && isDimacsWhitespace(text[cursor])) {
        ++cursor;
    }
    const start = cursor;
    while (cursor < text.length && !isDimacsWhitespace(text[cursor])) {
        ++cursor;
    }
    return text[start .. cursor];
}

private bool isDimacsWhitespace(char value) {
    return value == ' ' ||
        value == '\t' ||
        value == '\v' ||
        value == '\f' ||
        value == '\r' ||
        value == '\n';
}

private size_t[] sortedVariableLabelIds(
    const string[size_t] variableLabels
) {
    size_t[] ids;
    foreach (variable, _; variableLabels) {
        ids ~= variable;
    }
    ids.sort();
    return ids;
}

private void appendComment(ref typeof(appender!string()) output, string text) {
    output.put("c");
    if (text.length != 0) {
        output.put(" ");
        output.put(text);
    }
    output.put("\n");
}

private void validateSingleLineMetadata(
    string value,
    string field,
    size_t inputLine = 0
) {
    foreach (character; value) {
        if (character == '\r' || character == '\n') {
            throw new DimacsException(
                field ~ " must not contain a line break",
                inputLine
            );
        }
    }
}