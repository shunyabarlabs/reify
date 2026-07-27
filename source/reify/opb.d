// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

/**
 * Clean-room restricted-linear OPB adapter.
 *
 * Syntax is implemented from the official PB24 General OPB Format and
 * Restricted OPB Format specifications published by CRIL, not from a solver
 * or generator implementation:
 *
 * - https://www.cril.univ-artois.fr/PB24/OPBgeneral.pdf
 * - https://www.cril.univ-artois.fr/PB24/OPBcompetition.pdf
 */
module reify.opb;

import reify.errors :
    CapabilityException,
    ModelException,
    NavokojException;
import reify.model :
    BoolExpr,
    ExpressionKind,
    ExpressionNode,
    IntExpr,
    Model,
    asInteger,
    equal,
    greaterEqual,
    greaterThan,
    integer,
    lessEqual,
    lessThan,
    notEqual;

import std.algorithm : canFind;
import std.array : appender;
import std.bigint : BigInt;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.string :
    indexOf,
    lineSplitter,
    split,
    startsWith,
    strip;

/**
 * Resource limits for parsing, validating, serializing, and adapting OPB.
 *
 * OPB coefficients are arbitrary-precision integers. `maxIntegerDigits`
 * therefore limits resource use rather than narrowing coefficients to a
 * machine integer. Trusted applications may raise any limit explicitly.
 */
struct OpbLimits {
    size_t maxInputBytes = 256 * 1024 * 1024;
    size_t maxVariables = 1_000_000;
    size_t maxConstraints = 5_000_000;
    size_t maxTerms = 50_000_000;
    size_t maxTermsPerStatement = 1_000_000;
    size_t maxExecutableTermsPerStatement = 10_000;
    size_t maxIntegerDigits = 100_000;
    size_t maxIntSize = 1_000_000;
    size_t maxStatementBytes = 64 * 1024 * 1024;
    size_t maxCommentBytes = 16 * 1024 * 1024;
}

/**
 * Controls canonical OPB serialization.
 */
struct OpbSerializeOptions {
    /**
     * Emit a freshly calculated PB24 header. This includes variables which do
     * not occur in any term because `OpbInstance.numVariables` is authoritative.
     */
    bool includeHeader = true;
    bool includeComments = true;
    bool trailingNewline = true;
}

/**
 * A malformed, unsupported, or resource-exceeding OPB input.
 */
class OpbException : NavokojException {
    size_t inputLine;
    size_t inputColumn;

    this(
        string message,
        size_t inputLine = 0,
        size_t inputColumn = 0,
        string file = __FILE__,
        size_t line = __LINE__
    ) {
        string location;
        if (inputLine != 0) {
            location = inputColumn == 0
                ? format(" at line %s", inputLine)
                : format(
                    " at line %s, column %s",
                    inputLine,
                    inputColumn
                );
        }
        super("Invalid OPB" ~ location ~ ": " ~ message, file, line);
        this.inputLine = inputLine;
        this.inputColumn = inputColumn;
    }
}

/**
 * The relation between a pseudo-Boolean linear sum and an integer right-hand
 * side. Both `=` and `==` parse to `equal`.
 */
enum OpbRelation {
    less,
    lessEqual,
    equal,
    notEqual,
    greaterEqual,
    greater
}

enum OpbObjectiveSense {
    minimize,
    maximize
}

/**
 * One arbitrary-precision integer coefficient and one Boolean literal.
 *
 * Variables use the official restricted-form names `x1` through `xN`.
 * `negated == true` represents `~xN`. The parser also accepts the Unicode
 * negation glyphs used by the general OPB specification.
 */
struct OpbTerm {
    BigInt coefficient;
    uint variable;
    bool negated;
}

struct OpbObjective {
    OpbObjectiveSense sense;
    OpbTerm[] terms;
}

struct OpbConstraint {
    OpbTerm[] terms;
    OpbRelation relation;
    BigInt rightHandSide;
}

/**
 * Metadata from a PB24 restricted header.
 *
 * `hasEqualCount` and `hasIntSize` allow older headers containing only
 * `#variable=` and `#constraint=` to round-trip through the in-memory form.
 * Serialization always calculates a complete current PB24 header.
 */
struct OpbHeader {
    bool present;
    size_t declaredVariables;
    size_t declaredConstraints;
    size_t declaredEqualConstraints;
    size_t intSize;
    bool hasEqualCount;
    bool hasIntSize;
}

/**
 * A lossless restricted-linear OPB instance.
 *
 * Coefficients and right-hand sides remain `BigInt`; no expansion to a Boolean
 * expression AST occurs. A declared header determines `numVariables`, even
 * when its highest variables are unused. Without a header, the parser derives
 * the value from the greatest `xN` encountered.
 */
struct OpbInstance {
    size_t numVariables;
    OpbConstraint[] constraints;
    bool hasObjective;
    OpbObjective objective;
    string[] comments;
    OpbHeader header;

    /**
     * Validate an instance, including programmatically constructed values.
     */
    void validate(OpbLimits limits = OpbLimits()) const {
        validateVariableCount(numVariables, limits);

        if (constraints.length > limits.maxConstraints) {
            throw new OpbException(format(
                "constraint count %s exceeds configured limit %s",
                constraints.length,
                limits.maxConstraints
            ));
        }

        size_t commentBytes;
        foreach (commentIndex, comment; comments) {
            foreach (character; comment) {
                if (character == '\r' || character == '\n') {
                    throw new OpbException(format(
                        "comment %s contains a line break",
                        commentIndex + 1
                    ));
                }
            }
            checkedAccumulate(
                commentBytes,
                comment.length,
                limits.maxCommentBytes,
                "comment bytes"
            );
        }

        size_t termCount;
        if (hasObjective) {
            validateSense(objective.sense);
            validateTerms(
                objective.terms,
                numVariables,
                termCount,
                limits,
                "objective"
            );
        }

        size_t equalCount;
        foreach (constraintIndex, constraint; constraints) {
            validateRelation(constraint.relation);
            validateTerms(
                constraint.terms,
                numVariables,
                termCount,
                limits,
                format("constraint %s", constraintIndex + 1)
            );
            validateBigInteger(
                constraint.rightHandSide,
                limits,
                format(
                    "right-hand side of constraint %s",
                    constraintIndex + 1
                )
            );
            if (constraint.relation == OpbRelation.equal) {
                ++equalCount;
            }
        }

        if (header.present) {
            if (header.declaredVariables != numVariables) {
                throw new OpbException(format(
                    "header declares %s variables but instance has %s",
                    header.declaredVariables,
                    numVariables
                ));
            }
            if (header.declaredConstraints != constraints.length) {
                throw new OpbException(format(
                    "header declares %s constraints but instance has %s",
                    header.declaredConstraints,
                    constraints.length
                ));
            }
            if (
                header.hasEqualCount &&
                header.declaredEqualConstraints != equalCount
            ) {
                throw new OpbException(format(
                    "header declares %s equality constraints but instance has %s",
                    header.declaredEqualConstraints,
                    equalCount
                ));
            }
            if (header.hasIntSize && header.intSize > limits.maxIntSize) {
                throw new OpbException(format(
                    "header intsize %s exceeds configured limit %s",
                    header.intSize,
                    limits.maxIntSize
                ));
            }
        }
    }

    /**
     * Render a canonical, ASCII restricted-linear OPB representation.
     *
     * General-format relations and `max:` are retained. Unicode relation and
     * negation aliases are normalized to ASCII.
     */
    string toOpb(
        OpbSerializeOptions options = OpbSerializeOptions(),
        OpbLimits limits = OpbLimits()
    ) const {
        validate(limits);

        auto output = appender!string();
        if (options.includeHeader) {
            output.put("* #variable= ");
            output.put(numVariables.to!string);
            output.put(" #constraint= ");
            output.put(constraints.length.to!string);
            output.put(" #equal= ");
            output.put(equalityConstraintCount().to!string);
            output.put(" intsize= ");
            output.put(calculatedIntSize().to!string);
            output.put("\n");
        }
        if (options.includeComments) {
            foreach (comment; comments) {
                output.put("*");
                if (comment.length != 0) {
                    output.put(" ");
                    output.put(comment);
                }
                output.put("\n");
            }
        }

        if (hasObjective) {
            auto statement = appender!string();
            statement.put(
                objective.sense == OpbObjectiveSense.minimize
                    ? "min:"
                    : "max:"
            );
            appendTerms(statement, objective.terms);
            statement.put(" ;");
            appendStatement(output, statement.data, limits);
        }

        foreach (constraint; constraints) {
            auto statement = appender!string();
            appendTerms(statement, constraint.terms);
            statement.put(" ");
            statement.put(relationText(constraint.relation));
            statement.put(" ");
            statement.put(bigIntText(constraint.rightHandSide));
            statement.put(" ;");
            appendStatement(output, statement.data, limits);
        }

        auto rendered = output.data;
        if (rendered.length > limits.maxInputBytes) {
            throw new OpbException(format(
                "serialized input size %s exceeds configured limit %s",
                rendered.length,
                limits.maxInputBytes
            ));
        }
        if (
            !options.trailingNewline &&
            rendered.length != 0 &&
            rendered[$ - 1] == '\n'
        ) {
            rendered = rendered[0 .. $ - 1];
        }
        return rendered;
    }

    /**
     * Convert to navokoj-app's compact raw-OPB document shape.
     *
     * Arbitrary-precision integers are JSON decimal strings. Literals are
     * signed one-based numbers (`-N` means `~xN`). This representation stays
     * linear and does not allocate one AST node per Boolean operation.
     */
    JSONValue toDocumentJson(OpbLimits limits = OpbLimits()) const {
        validate(limits);

        JSONValue[string] opb;
        opb["num_vars"] = JSONValue(cast(long) numVariables);

        if (header.present) {
            JSONValue[string] headerValue;
            headerValue["num_variables"] =
                JSONValue(cast(long) header.declaredVariables);
            headerValue["num_constraints"] =
                JSONValue(cast(long) header.declaredConstraints);
            if (header.hasEqualCount) {
                headerValue["num_equal"] =
                    JSONValue(cast(long) header.declaredEqualConstraints);
            }
            if (header.hasIntSize) {
                headerValue["intsize"] =
                    JSONValue(cast(long) header.intSize);
            }
            opb["header"] = JSONValue(headerValue);
        }

        if (comments.length != 0) {
            JSONValue[] values;
            foreach (comment; comments) {
                values ~= JSONValue(comment);
            }
            opb["comments"] = JSONValue(values);
        }

        if (hasObjective) {
            JSONValue[string] objectiveValue;
            objectiveValue["sense"] = JSONValue(
                objective.sense == OpbObjectiveSense.minimize
                    ? "min"
                    : "max"
            );
            objectiveValue["terms"] = termsToJson(objective.terms);
            opb["objective"] = JSONValue(objectiveValue);
        }

        JSONValue[] constraintValues;
        foreach (constraint; constraints) {
            JSONValue[string] constraintValue;
            constraintValue["terms"] = termsToJson(constraint.terms);
            constraintValue["relation"] =
                JSONValue(relationText(constraint.relation));
            constraintValue["rhs"] =
                JSONValue(bigIntText(constraint.rightHandSide));
            constraintValues ~= JSONValue(constraintValue);
        }
        opb["constraints"] = JSONValue(constraintValues);

        JSONValue[string] document;
        document["opb"] = JSONValue(opb);
        return JSONValue(document);
    }

    size_t equalityConstraintCount() const {
        size_t result;
        foreach (constraint; constraints) {
            if (constraint.relation == OpbRelation.equal) {
                ++result;
            }
        }
        return result;
    }

    /**
     * Calculate the PB24 `intsize` hint from arbitrary-precision values.
     */
    size_t calculatedIntSize() const {
        BigInt maximum;

        if (hasObjective) {
            BigInt magnitude;
            foreach (term; objective.terms) {
                magnitude += absoluteCopy(term.coefficient);
            }
            if (magnitude > maximum) {
                maximum = magnitude;
            }
        }

        foreach (constraint; constraints) {
            auto magnitude = absoluteCopy(constraint.rightHandSide);
            foreach (term; constraint.terms) {
                magnitude += absoluteCopy(term.coefficient);
            }
            if (magnitude > maximum) {
                maximum = magnitude;
            }
        }

        if (maximum == 0) {
            return 1;
        }

        size_t bits;
        while (maximum != 0) {
            maximum >>= 1;
            ++bits;
        }
        return bits;
    }
}

/**
 * Parse a complete restricted-linear OPB string.
 *
 * Supported syntax is the intersection needed by formula generators and the
 * user-friendly general format: `xN`/`~xN` literals, `min:`/`max:`, and all
 * ordinary linear relations. In addition to the official semicolon terminator,
 * the parser accepts the line-oriented PB generator dialect in which one
 * complete statement occupies a physical line and the semicolon is omitted.
 * Products, WBO/soft constraints, model-counting directives, and general
 * quoted or named variables are rejected explicitly.
 */
OpbInstance parseOpb(
    string source,
    OpbLimits limits = OpbLimits()
) {
    return new OpbParser(source, limits).parse();
}

/**
 * Parse OPB directly into the compact navokoj-app document.
 */
JSONValue opbToDocumentJson(
    string source,
    OpbLimits limits = OpbLimits()
) {
    return parseOpb(source, limits).toDocumentJson(limits);
}

/**
 * Serialize an in-memory instance as canonical OPB.
 */
string serializeOpb(
    const ref OpbInstance instance,
    OpbSerializeOptions options = OpbSerializeOptions(),
    OpbLimits limits = OpbLimits()
) {
    return instance.toOpb(options, limits);
}

/**
 * Reconstruct a validated OPB instance from the compact `{ "opb": ... }`
 * document emitted by `OpbInstance.toDocumentJson`.
 *
 * This is deliberately strict: unknown fields, JSON numbers in place of
 * arbitrary-precision decimal strings, zero literals, and inconsistent header
 * metadata are rejected.
 */
OpbInstance opbFromDocumentJson(
    JSONValue document,
    OpbLimits limits = OpbLimits()
) {
    const root = requireJsonObject(document, "document");
    ensureOnlyJsonFields(root, ["opb"], "document");
    auto opbField = "opb" in root;
    if (opbField is null) {
        throw new OpbException(
            "compact OPB document requires an `opb` object"
        );
    }

    const object = requireJsonObject(*opbField, "opb");
    ensureOnlyJsonFields(
        object,
        [
            "num_vars",
            "header",
            "comments",
            "objective",
            "constraints"
        ],
        "opb"
    );

    OpbInstance result;
    result.numVariables = requireJsonSize(
        requireJsonField(object, "num_vars", "opb"),
        "opb.num_vars"
    );

    auto headerField = "header" in object;
    if (headerField !is null) {
        const headerObject = requireJsonObject(
            *headerField,
            "opb.header"
        );
        ensureOnlyJsonFields(
            headerObject,
            [
                "num_variables",
                "num_constraints",
                "num_equal",
                "intsize"
            ],
            "opb.header"
        );
        result.header.present = true;
        result.header.declaredVariables = requireJsonSize(
            requireJsonField(
                headerObject,
                "num_variables",
                "opb.header"
            ),
            "opb.header.num_variables"
        );
        result.header.declaredConstraints = requireJsonSize(
            requireJsonField(
                headerObject,
                "num_constraints",
                "opb.header"
            ),
            "opb.header.num_constraints"
        );

        auto equalField = "num_equal" in headerObject;
        if (equalField !is null) {
            result.header.hasEqualCount = true;
            result.header.declaredEqualConstraints = requireJsonSize(
                *equalField,
                "opb.header.num_equal"
            );
        }
        auto intSizeField = "intsize" in headerObject;
        if (intSizeField !is null) {
            result.header.hasIntSize = true;
            result.header.intSize = requireJsonSize(
                *intSizeField,
                "opb.header.intsize"
            );
        }
    }

    auto commentsField = "comments" in object;
    if (commentsField !is null) {
        if (commentsField.type != JSONType.array) {
            throw new OpbException("opb.comments must be an array");
        }
        foreach (index, value; commentsField.array) {
            if (value.type != JSONType.string) {
                throw new OpbException(format(
                    "opb.comments[%s] must be a string",
                    index
                ));
            }
            result.comments ~= value.str;
        }
    }

    auto objectiveField = "objective" in object;
    if (objectiveField !is null) {
        const objectiveObject = requireJsonObject(
            *objectiveField,
            "opb.objective"
        );
        ensureOnlyJsonFields(
            objectiveObject,
            ["sense", "terms"],
            "opb.objective"
        );
        const senseValue = requireJsonField(
            objectiveObject,
            "sense",
            "opb.objective"
        );
        if (senseValue.type != JSONType.string) {
            throw new OpbException(
                "opb.objective.sense must be `min` or `max`"
            );
        }
        switch (senseValue.str) {
            case "min":
                result.objective.sense = OpbObjectiveSense.minimize;
                break;
            case "max":
                result.objective.sense = OpbObjectiveSense.maximize;
                break;
            default:
                throw new OpbException(
                    "opb.objective.sense must be `min` or `max`"
                );
        }
        result.objective.terms = termsFromJson(
            requireJsonField(
                objectiveObject,
                "terms",
                "opb.objective"
            ),
            "opb.objective.terms",
            limits
        );
        result.hasObjective = true;
    }

    const constraintsValue = requireJsonField(
        object,
        "constraints",
        "opb"
    );
    if (constraintsValue.type != JSONType.array) {
        throw new OpbException("opb.constraints must be an array");
    }
    if (constraintsValue.array.length > limits.maxConstraints) {
        throw new OpbException(format(
            "opb.constraints has %s entries, exceeding configured limit %s",
            constraintsValue.array.length,
            limits.maxConstraints
        ));
    }
    foreach (index, value; constraintsValue.array) {
        const field = format("opb.constraints[%s]", index);
        const constraintObject = requireJsonObject(value, field);
        ensureOnlyJsonFields(
            constraintObject,
            ["terms", "relation", "rhs"],
            field
        );

        OpbConstraint constraint;
        constraint.terms = termsFromJson(
            requireJsonField(
                constraintObject,
                "terms",
                field
            ),
            field ~ ".terms",
            limits
        );

        const relationValue = requireJsonField(
            constraintObject,
            "relation",
            field
        );
        if (relationValue.type != JSONType.string) {
            throw new OpbException(
                field ~ ".relation must be a string"
            );
        }
        constraint.relation = relationFromText(
            relationValue.str,
            field ~ ".relation"
        );
        constraint.rightHandSide = bigIntFromJson(
            requireJsonField(constraintObject, "rhs", field),
            field ~ ".rhs",
            limits
        );
        result.constraints ~= constraint;
    }

    result.validate(limits);
    return result;
}

/**
 * Lower a validated OPB instance into the executable Navokoj `Model`.
 *
 * Duplicate and complementary literals are normalized with `BigInt` first:
 * `c * ~x` becomes the constant `c` plus coefficient `-c` on `x`. Only the
 * final aggregate coefficients, constant, and adjusted right-hand side are
 * converted to `long`. A clear `CapabilityException` is raised before the
 * model is mutated if any final value is outside the current Model's signed
 * 64-bit arithmetic boundary.
 */
void populateModelFromOpb(
    Model model,
    const ref OpbInstance instance,
    OpbLimits limits = OpbLimits()
) {
    if (model is null) {
        throw new ModelException(
            "populateModelFromOpb requires a non-null Model"
        );
    }
    if (model.frozen) {
        throw new ModelException(
            "Cannot populate a Model after it has been compiled"
        );
    }

    instance.validate(limits);

    PreparedOpbObjective preparedObjective;
    if (instance.hasObjective) {
        preparedObjective.present = true;
        preparedObjective.sense = instance.objective.sense;
        preparedObjective.linear = prepareLinear(
            instance.objective.terms,
            "OPB objective"
        );
        enforceExecutableTermLimit(
            preparedObjective.linear,
            limits,
            "OPB objective"
        );
    }

    PreparedOpbConstraint[] preparedConstraints;
    foreach (index, constraint; instance.constraints) {
        const field = format("OPB constraint %s", index + 1);
        auto normalized = normalizeTerms(constraint.terms);
        checkedModelLong(
            normalized.constant,
            field ~ " normalized constant"
        );

        auto normalizedRightHandSide = BigInt(
            bigIntText(constraint.rightHandSide)
        );
        normalizedRightHandSide -= normalized.constant;

        PreparedOpbConstraint prepared;
        prepared.linear = prepareNormalizedLinear(
            normalized,
            field,
            0
        );
        enforceExecutableTermLimit(
            prepared.linear,
            limits,
            field
        );
        prepared.relation = constraint.relation;
        prepared.rightHandSide = checkedModelLong(
            normalizedRightHandSide,
            field ~ " normalized right-hand side"
        );
        preparedConstraints ~= prepared;
    }

    foreach (offset; 0 .. instance.numVariables) {
        const variable = offset + 1;
        const name = "x" ~ variable.to!string;
        if (model.hasVariable(name)) {
            throw new ModelException(
                "Cannot populate OPB variable `" ~ name ~
                "` because that name already exists in the Model"
            );
        }
    }
    ensureGeneratedNamesAvailable(
        model,
        preparedConstraints.length,
        preparedObjective.present
    );

    BoolExpr[] variables;
    foreach (offset; 0 .. instance.numVariables) {
        const variable = offset + 1;
        variables ~= model.booleanVar("x" ~ variable.to!string);
    }

    foreach (index, prepared; preparedConstraints) {
        auto left = buildPreparedExpression(
            prepared.linear,
            variables
        );
        auto right = integer(prepared.rightHandSide);
        BoolExpr expression;
        final switch (prepared.relation) {
            case OpbRelation.less:
                expression = lessThan(left, right);
                break;
            case OpbRelation.lessEqual:
                expression = lessEqual(left, right);
                break;
            case OpbRelation.equal:
                expression = equal(left, right);
                break;
            case OpbRelation.notEqual:
                expression = notEqual(left, right);
                break;
            case OpbRelation.greaterEqual:
                expression = greaterEqual(left, right);
                break;
            case OpbRelation.greater:
                expression = greaterThan(left, right);
                break;
        }
        model.require(
            generatedConstraintName(index),
            expression
        );
    }

    if (preparedObjective.present) {
        auto expression = buildPreparedExpression(
            preparedObjective.linear,
            variables
        );
        final switch (preparedObjective.sense) {
            case OpbObjectiveSense.minimize:
                model.minimize(generatedObjectiveName, expression);
                break;
            case OpbObjectiveSense.maximize:
                model.maximize(generatedObjectiveName, expression);
                break;
        }
    }
}

/**
 * Strictly decode a compact OPB document and populate an executable Model.
 */
void populateModelFromOpbDocument(
    Model model,
    JSONValue document,
    OpbLimits limits = OpbLimits()
) {
    auto instance = opbFromDocumentJson(document, limits);
    populateModelFromOpb(model, instance, limits);
}

private final class OpbParser {
    string source;
    OpbLimits limits;
    OpbInstance instance;
    size_t lineNumber;
    size_t totalTerms;
    size_t totalCommentBytes;
    size_t maximumVariableSeen;
    bool sawStatement;

    this(string source, OpbLimits limits) {
        this.source = source;
        this.limits = limits;
    }

    OpbInstance parse() {
        if (source.length > limits.maxInputBytes) {
            fail(format(
                "input size %s exceeds configured limit %s",
                source.length,
                limits.maxInputBytes
            ));
        }

        foreach (rawLine; source.lineSplitter()) {
            ++lineNumber;
            const line = rawLine.strip;
            if (line.length == 0) {
                continue;
            }

            if (line[0] == '*') {
                parseComment(line[1 .. $].strip);
                continue;
            }
            if (line.length > limits.maxStatementBytes) {
                fail(format(
                    "statement length %s exceeds configured limit %s",
                    line.length,
                    limits.maxStatementBytes
                ));
            }
            parseStatement(line);
            sawStatement = true;
        }

        if (instance.header.present) {
            instance.numVariables = instance.header.declaredVariables;
            if (
                instance.constraints.length !=
                    instance.header.declaredConstraints
            ) {
                fail(
                    format(
                        "header declares %s constraints but input contains %s",
                        instance.header.declaredConstraints,
                        instance.constraints.length
                    ),
                    0
                );
            }
            if (
                instance.header.hasEqualCount &&
                instance.equalityConstraintCount() !=
                    instance.header.declaredEqualConstraints
            ) {
                fail(
                    format(
                        "header declares %s equality constraints but input " ~
                        "contains %s",
                        instance.header.declaredEqualConstraints,
                        instance.equalityConstraintCount()
                    ),
                    0
                );
            }
        } else {
            instance.numVariables = maximumVariableSeen;
        }

        instance.validate(limits);
        return instance;
    }

    private void parseComment(string body) {
        checkedAccumulate(
            totalCommentBytes,
            body.length,
            limits.maxCommentBytes,
            "comment bytes",
            lineNumber
        );

        if (
            body.indexOf("#product=") >= 0 ||
            body.indexOf("sizeproduct=") >= 0
        ) {
            fail(
                "nonlinear OPB products are unsupported by this linear adapter"
            );
        }

        if (
            body.startsWith("#variable=") ||
            body.startsWith("#variable")
        ) {
            parseHeader(body);
            return;
        }

        instance.comments ~= body;
    }

    private void parseHeader(string body) {
        if (sawStatement) {
            fail("the OPB header must precede all objective and constraint data");
        }
        if (instance.header.present) {
            fail("multiple OPB headers are not allowed");
        }

        const fields = body.split();
        if ((fields.length & 1) != 0) {
            fail(
                "header must contain keyword/value pairs separated by spaces"
            );
        }

        bool sawVariables;
        bool sawConstraints;
        for (size_t index; index < fields.length; index += 2) {
            const key = fields[index];
            const value = parseHeaderUnsigned(
                fields[index + 1],
                key
            );
            switch (key) {
                case "#variable=":
                    if (sawVariables) {
                        fail("header contains duplicate #variable=");
                    }
                    sawVariables = true;
                    instance.header.declaredVariables = value;
                    break;

                case "#constraint=":
                    if (sawConstraints) {
                        fail("header contains duplicate #constraint=");
                    }
                    sawConstraints = true;
                    instance.header.declaredConstraints = value;
                    break;

                case "#equal=":
                    if (instance.header.hasEqualCount) {
                        fail("header contains duplicate #equal=");
                    }
                    instance.header.hasEqualCount = true;
                    instance.header.declaredEqualConstraints = value;
                    break;

                case "intsize=":
                    if (instance.header.hasIntSize) {
                        fail("header contains duplicate intsize=");
                    }
                    instance.header.hasIntSize = true;
                    instance.header.intSize = value;
                    break;

                case "#product=":
                case "sizeproduct=":
                    fail(
                        "nonlinear OPB products are unsupported by this " ~
                        "linear adapter"
                    );
                    break;

                default:
                    fail("unsupported OPB header keyword `" ~ key ~ "`");
            }
        }

        if (!sawVariables || !sawConstraints) {
            fail(
                "header requires both #variable= and #constraint= fields"
            );
        }
        validateVariableCount(instance.header.declaredVariables, limits);
        if (
            instance.header.declaredConstraints >
                limits.maxConstraints
        ) {
            fail(format(
                "declared constraint count %s exceeds configured limit %s",
                instance.header.declaredConstraints,
                limits.maxConstraints
            ));
        }
        if (
            instance.header.hasEqualCount &&
            instance.header.declaredEqualConstraints >
                instance.header.declaredConstraints
        ) {
            fail(
                "#equal= cannot exceed the declared constraint count"
            );
        }
        if (
            instance.header.hasIntSize &&
            instance.header.intSize > limits.maxIntSize
        ) {
            fail(format(
                "declared intsize %s exceeds configured limit %s",
                instance.header.intSize,
                limits.maxIntSize
            ));
        }
        instance.header.present = true;
        instance.numVariables = instance.header.declaredVariables;
    }

    private size_t parseHeaderUnsigned(string token, string field) {
        if (token.length == 0) {
            fail("header field " ~ field ~ " cannot be empty");
        }

        size_t value;
        foreach (character; token) {
            if (character < '0' || character > '9') {
                fail(
                    "header field " ~ field ~
                    " must be a non-negative decimal integer"
                );
            }
            const digit =
                cast(size_t) character - cast(size_t) '0';
            if (value > (size_t.max - digit) / 10) {
                fail(
                    "header field " ~ field ~
                    " exceeds the platform integer range"
                );
            }
            value = value * 10 + digit;
        }
        return value;
    }

    private void parseStatement(string line) {
        const terminator = line.indexOf(';');
        if (
            terminator >= 0 &&
            line[cast(size_t) terminator + 1 .. $].strip.length != 0
        ) {
            fail(
                "only one semicolon-terminated statement is allowed per line",
                cast(size_t) terminator + 2
            );
        }

        const content = terminator < 0
            ? line
            : line[0 .. cast(size_t) terminator].strip;
        if (content.length == 0) {
            fail("empty OPB statements are not allowed");
        }

        if (
            content.startsWith("soft:") ||
            content[0] == '[' ||
            content.indexOf("[") >= 0
        ) {
            fail(
                "WBO `soft:` headers and weighted soft constraints are " ~
                "unsupported; use a linear min/max objective"
            );
        }
        if (content.startsWith("models:")) {
            fail(
                "model-counting and model-enumeration directives are " ~
                "unsupported by this linear optimization adapter"
            );
        }

        if (
            content.startsWith("min:") ||
            content.startsWith("max:")
        ) {
            if (sawStatement || instance.hasObjective) {
                fail(
                    "the objective must be the first non-comment statement " ~
                    "and may occur only once"
                );
            }
            parseObjective(content);
            return;
        }

        if (instance.constraints.length >= limits.maxConstraints) {
            fail(format(
                "constraint count exceeds configured limit %s",
                limits.maxConstraints
            ));
        }
        instance.constraints ~= parseConstraint(content);
    }

    private void parseObjective(string content) {
        instance.hasObjective = true;
        instance.objective.sense = content.startsWith("min:")
            ? OpbObjectiveSense.minimize
            : OpbObjectiveSense.maximize;

        size_t cursor = 4;
        instance.objective.terms = parseTerms(
            content,
            cursor,
            false
        );
        skipWhitespace(content, cursor);
        if (cursor != content.length) {
            if (isRelationAt(content, cursor)) {
                fail(
                    "an OPB objective is a linear sum and cannot contain a " ~
                    "relation",
                    cursor + 1
                );
            }
            fail("unexpected token in objective", cursor + 1);
        }
    }

    private OpbConstraint parseConstraint(string content) {
        OpbConstraint result;
        size_t cursor;
        result.terms = parseTerms(content, cursor, true);
        skipWhitespace(content, cursor);
        if (cursor == content.length) {
            fail("constraint is missing a relational operator");
        }

        result.relation = parseRelation(content, cursor);
        skipWhitespace(content, cursor);
        if (cursor == content.length) {
            fail(
                "constraint relation must be followed by an integer " ~
                "right-hand side",
                cursor + 1
            );
        }
        result.rightHandSide = parseBigInteger(
            content,
            cursor,
            "right-hand side"
        );
        skipWhitespace(content, cursor);
        if (cursor != content.length) {
            fail(
                "unexpected data after constraint right-hand side",
                cursor + 1
            );
        }
        return result;
    }

    private OpbTerm[] parseTerms(
        string content,
        ref size_t cursor,
        bool stopAtRelation
    ) {
        OpbTerm[] result;

        while (true) {
            skipWhitespace(content, cursor);
            if (cursor == content.length) {
                break;
            }
            if (stopAtRelation && isRelationAt(content, cursor)) {
                break;
            }
            if (looksLikeLiteral(content, cursor)) {
                fail(
                    result.length == 0
                        ? "each linear term requires an integer coefficient"
                        : "nonlinear products are unsupported; every " ~
                            "coefficient must be followed by exactly one literal",
                    cursor + 1
                );
            }
            if (content[cursor] == '[' || content.startsWith("soft:")) {
                fail(
                    "WBO soft constraints are unsupported",
                    cursor + 1
                );
            }

            OpbTerm term;
            term.coefficient = parseBigInteger(
                content,
                cursor,
                "coefficient"
            );
            if (!skipWhitespace(content, cursor)) {
                fail(
                    "a coefficient and its literal must be separated by " ~
                    "whitespace",
                    cursor + 1
                );
            }
            term = parseLiteral(content, cursor, term.coefficient);
            result ~= term;
            noteTerm(term.variable, result.length);

            const separated = skipWhitespace(content, cursor);
            if (cursor == content.length) {
                break;
            }
            if (!separated) {
                if (looksLikeLiteral(content, cursor)) {
                    fail(
                        "nonlinear products are unsupported; a term may " ~
                        "contain only one literal",
                        cursor + 1
                    );
                }
                fail(
                    "a literal must be followed by whitespace",
                    cursor + 1
                );
            }
            if (looksLikeLiteral(content, cursor)) {
                fail(
                    "nonlinear products are unsupported; a term may contain " ~
                    "only one literal",
                    cursor + 1
                );
            }
            if (stopAtRelation && isRelationAt(content, cursor)) {
                break;
            }
        }

        if (result.length == 0) {
            fail("a linear sum must contain at least one weighted literal");
        }
        return result;
    }

    private BigInt parseBigInteger(
        string content,
        ref size_t cursor,
        string field
    ) {
        const start = cursor;
        if (
            cursor < content.length &&
            (content[cursor] == '+' || content[cursor] == '-')
        ) {
            ++cursor;
        }
        const digitStart = cursor;
        while (
            cursor < content.length &&
            content[cursor] >= '0' &&
            content[cursor] <= '9'
        ) {
            ++cursor;
        }
        if (cursor == digitStart) {
            fail(
                field ~ " must be a signed or unsigned decimal integer",
                start + 1
            );
        }
        const digitCount = cursor - digitStart;
        if (digitCount > limits.maxIntegerDigits) {
            fail(
                format(
                    "%s has %s digits, exceeding configured limit %s",
                    field,
                    digitCount,
                    limits.maxIntegerDigits
                ),
                start + 1
            );
        }
        return BigInt(content[start .. cursor]);
    }

    private OpbTerm parseLiteral(
        string content,
        ref size_t cursor,
        BigInt coefficient
    ) {
        OpbTerm result;
        result.coefficient = coefficient;

        if (consumePrefix(content, cursor, "~")) {
            result.negated = true;
        } else if (
            consumePrefix(content, cursor, "\u223C") ||
            consumePrefix(content, cursor, "\u02DC")
        ) {
            result.negated = true;
        }

        if (cursor == content.length || content[cursor] != 'x') {
            fail(
                "this restricted adapter accepts only xN and ~xN literals",
                cursor + 1
            );
        }
        ++cursor;
        const digitStart = cursor;
        ulong variable;
        while (
            cursor < content.length &&
            content[cursor] >= '0' &&
            content[cursor] <= '9'
        ) {
            const digit =
                cast(ulong) content[cursor] - cast(ulong) '0';
            if (variable > (ulong.max - digit) / 10) {
                fail("variable identifier is too large", digitStart);
            }
            variable = variable * 10 + digit;
            ++cursor;
        }
        if (cursor == digitStart) {
            fail(
                "variable name must be x followed by a positive integer",
                digitStart + 1
            );
        }
        if (variable == 0 || variable > uint.max) {
            fail(
                format(
                    "variable identifier must be in 1..%s",
                    uint.max
                ),
                digitStart + 1
            );
        }
        if (
            cursor < content.length &&
            isRestrictedIdentifierCharacter(content[cursor])
        ) {
            fail(
                "variable names must be exactly x followed by decimal digits",
                digitStart
            );
        }

        result.variable = cast(uint) variable;
        return result;
    }

    private OpbRelation parseRelation(
        string content,
        ref size_t cursor
    ) {
        if (consumePrefix(content, cursor, "!=")) {
            return OpbRelation.notEqual;
        }
        if (consumePrefix(content, cursor, "==")) {
            return OpbRelation.equal;
        }
        if (consumePrefix(content, cursor, ">=")) {
            return OpbRelation.greaterEqual;
        }
        if (consumePrefix(content, cursor, "<=")) {
            return OpbRelation.lessEqual;
        }
        if (consumePrefix(content, cursor, "\u2260")) {
            return OpbRelation.notEqual;
        }
        if (consumePrefix(content, cursor, "\u2265")) {
            return OpbRelation.greaterEqual;
        }
        if (consumePrefix(content, cursor, "\u2264")) {
            return OpbRelation.lessEqual;
        }
        if (consumePrefix(content, cursor, "=")) {
            return OpbRelation.equal;
        }
        if (consumePrefix(content, cursor, ">")) {
            return OpbRelation.greater;
        }
        if (consumePrefix(content, cursor, "<")) {
            return OpbRelation.less;
        }
        fail("unsupported relational operator", cursor + 1);
        assert(0);
    }

    private void noteTerm(uint variable, size_t statementTerms) {
        if (statementTerms > limits.maxTermsPerStatement) {
            fail(format(
                "term count in statement exceeds configured limit %s",
                limits.maxTermsPerStatement
            ));
        }
        if (totalTerms >= limits.maxTerms) {
            fail(format(
                "total term count exceeds configured limit %s",
                limits.maxTerms
            ));
        }
        ++totalTerms;

        if (
            instance.header.present &&
            cast(size_t) variable > instance.header.declaredVariables
        ) {
            fail(format(
                "literal x%s exceeds header-declared variable range 1..%s",
                variable,
                instance.header.declaredVariables
            ));
        }
        if (cast(size_t) variable > limits.maxVariables) {
            fail(format(
                "literal x%s exceeds configured variable limit %s",
                variable,
                limits.maxVariables
            ));
        }
        if (variable > maximumVariableSeen) {
            maximumVariableSeen = variable;
        }
    }

    private bool skipWhitespace(string content, ref size_t cursor) {
        const start = cursor;
        while (
            cursor < content.length &&
            isOpbWhitespace(content[cursor])
        ) {
            ++cursor;
        }
        return cursor != start;
    }

    private void fail(
        string message,
        size_t column = 0
    ) {
        throw new OpbException(message, lineNumber, column);
    }
}

private struct NormalizedOpbLinear {
    BigInt constant;
    BigInt[uint] coefficients;
}

private struct PreparedOpbLinear {
    long constant;
    long[uint] coefficients;
}

private struct PreparedOpbConstraint {
    PreparedOpbLinear linear;
    OpbRelation relation;
    long rightHandSide;
}

private struct PreparedOpbObjective {
    bool present;
    OpbObjectiveSense sense;
    PreparedOpbLinear linear;
}

private enum generatedObjectiveName = "opb.objective";

private string generatedConstraintName(size_t zeroBasedIndex) {
    return "opb.constraint." ~ (zeroBasedIndex + 1).to!string;
}

private NormalizedOpbLinear normalizeTerms(const OpbTerm[] terms) {
    NormalizedOpbLinear result;
    foreach (term; terms) {
        auto coefficient = BigInt(bigIntText(term.coefficient));
        if (term.negated) {
            result.constant += coefficient;
            coefficient = -coefficient;
        }

        auto existing = term.variable in result.coefficients;
        if (existing is null) {
            result.coefficients[term.variable] = coefficient;
        } else {
            *existing += coefficient;
        }
    }
    return result;
}

private PreparedOpbLinear prepareLinear(
    const OpbTerm[] terms,
    string field
) {
    auto normalized = normalizeTerms(terms);
    const constant = checkedModelLong(
        normalized.constant,
        field ~ " normalized constant"
    );
    return prepareNormalizedLinear(
        normalized,
        field,
        constant
    );
}

private PreparedOpbLinear prepareNormalizedLinear(
    const ref NormalizedOpbLinear normalized,
    string field,
    long expressionConstant
) {
    PreparedOpbLinear result;
    result.constant = expressionConstant;
    foreach (variable, coefficient; normalized.coefficients) {
        if (coefficient == 0) {
            continue;
        }
        result.coefficients[variable] = checkedModelLong(
            coefficient,
            format("%s normalized coefficient for x%s", field, variable)
        );
    }
    return result;
}

private long checkedModelLong(
    const ref BigInt value,
    string field
) {
    if (value < BigInt(long.min) || value > BigInt(long.max)) {
        throw new CapabilityException(
            field ~ " `" ~ bigIntText(value) ~
            "` does not fit the current Model's signed 64-bit arithmetic; " ~
            "rescale the OPB model or use a future arbitrary-precision backend"
        );
    }
    return value.toLong();
}

private void enforceExecutableTermLimit(
    const ref PreparedOpbLinear prepared,
    OpbLimits limits,
    string field
) {
    if (
        prepared.coefficients.length >
            limits.maxExecutableTermsPerStatement
    ) {
        throw new CapabilityException(format(
            "%s has %s normalized terms, exceeding the executable model " ~
            "limit of %s; split the constraint or raise the trusted OPB limit",
            field,
            prepared.coefficients.length,
            limits.maxExecutableTermsPerStatement
        ));
    }
}

private IntExpr buildPreparedExpression(
    const ref PreparedOpbLinear prepared,
    BoolExpr[] variables
) {
    IntExpr[] terms;
    if (prepared.constant != 0) {
        terms ~= integer(prepared.constant);
    }

    foreach (offset; 0 .. variables.length) {
        const variable = offset + 1;
        auto coefficient = cast(uint) variable in prepared.coefficients;
        if (coefficient is null) {
            continue;
        }

        auto value = asInteger(variables[offset]);
        if (*coefficient == 1) {
            terms ~= value;
        } else if (*coefficient == -1) {
            terms ~= -value;
        } else {
            terms ~= value * *coefficient;
        }
    }
    return balancedSum(terms, 0, terms.length);
}

private IntExpr balancedSum(
    IntExpr[] terms,
    size_t begin,
    size_t end
) {
    const length = end - begin;
    if (length == 0) {
        return integer(0);
    }
    if (length == 1) {
        return terms[begin];
    }
    const middle = begin + length / 2;
    return balancedSum(terms, begin, middle) +
        balancedSum(terms, middle, end);
}

private void ensureGeneratedNamesAvailable(
    Model model,
    size_t constraintCount,
    bool hasObjective
) {
    bool[string] existingConstraintNames;
    foreach (constraint; model.constraints) {
        existingConstraintNames[constraint.name] = true;
    }
    foreach (index; 0 .. constraintCount) {
        const name = generatedConstraintName(index);
        if ((name in existingConstraintNames) !is null) {
            throw new ModelException(
                "Cannot populate OPB constraint `" ~ name ~
                "` because that name already exists in the Model"
            );
        }
    }
    if (hasObjective) {
        foreach (objective; model.objectives) {
            if (objective.name == generatedObjectiveName) {
                throw new ModelException(
                    "Cannot populate OPB objective `" ~
                    generatedObjectiveName ~
                    "` because that name already exists in the Model"
                );
            }
        }
    }
}

private JSONValue[string] requireJsonObject(
    JSONValue value,
    string field
) {
    if (value.type != JSONType.object) {
        throw new OpbException(field ~ " must be an object");
    }
    return value.object;
}

private JSONValue requireJsonField(
    const JSONValue[string] object,
    string key,
    string field
) {
    auto found = key in object;
    if (found is null) {
        throw new OpbException(
            field ~ " requires field `" ~ key ~ "`"
        );
    }
    return *found;
}

private void ensureOnlyJsonFields(
    const JSONValue[string] object,
    const(string)[] allowed,
    string field
) {
    foreach (key, _; object) {
        if (!allowed.canFind(key)) {
            throw new OpbException(
                field ~ " contains unknown field `" ~ key ~ "`"
            );
        }
    }
}

private size_t requireJsonSize(JSONValue value, string field) {
    ulong parsed;
    if (value.type == JSONType.integer) {
        if (value.integer < 0) {
            throw new OpbException(
                field ~ " must be a non-negative integer"
            );
        }
        parsed = cast(ulong) value.integer;
    } else if (value.type == JSONType.uinteger) {
        parsed = value.uinteger;
    } else {
        throw new OpbException(
            field ~ " must be a non-negative JSON integer"
        );
    }
    if (parsed > size_t.max) {
        throw new OpbException(
            field ~ " exceeds the platform integer range"
        );
    }
    return cast(size_t) parsed;
}

private OpbTerm[] termsFromJson(
    JSONValue value,
    string field,
    OpbLimits limits
) {
    if (value.type != JSONType.array) {
        throw new OpbException(field ~ " must be an array");
    }
    if (value.array.length > limits.maxTermsPerStatement) {
        throw new OpbException(format(
            "%s has %s terms, exceeding configured limit %s",
            field,
            value.array.length,
            limits.maxTermsPerStatement
        ));
    }

    OpbTerm[] result;
    foreach (index, entry; value.array) {
        const termField = format("%s[%s]", field, index);
        const object = requireJsonObject(entry, termField);
        ensureOnlyJsonFields(
            object,
            ["coefficient", "literal"],
            termField
        );

        OpbTerm term;
        term.coefficient = bigIntFromJson(
            requireJsonField(object, "coefficient", termField),
            termField ~ ".coefficient",
            limits
        );

        const literalValue = requireJsonField(
            object,
            "literal",
            termField
        );
        ulong magnitude;
        if (literalValue.type == JSONType.integer) {
            const literal = literalValue.integer;
            if (literal == 0) {
                throw new OpbException(
                    termField ~ ".literal cannot be zero"
                );
            }
            if (literal < 0) {
                term.negated = true;
                if (literal == long.min) {
                    throw new OpbException(
                        termField ~ ".literal is outside the xN range"
                    );
                }
                magnitude = cast(ulong) -literal;
            } else {
                magnitude = cast(ulong) literal;
            }
        } else if (literalValue.type == JSONType.uinteger) {
            magnitude = literalValue.uinteger;
            if (magnitude == 0) {
                throw new OpbException(
                    termField ~ ".literal cannot be zero"
                );
            }
        } else {
            throw new OpbException(
                termField ~ ".literal must be a signed JSON integer"
            );
        }
        if (magnitude > uint.max) {
            throw new OpbException(
                termField ~ ".literal is outside the OPB xN range"
            );
        }
        term.variable = cast(uint) magnitude;
        result ~= term;
    }
    return result;
}

private BigInt bigIntFromJson(
    JSONValue value,
    string field,
    OpbLimits limits
) {
    if (value.type != JSONType.string) {
        throw new OpbException(
            field ~
            " must be a decimal string to preserve arbitrary precision"
        );
    }
    const text = value.str;
    if (text.length == 0) {
        throw new OpbException(field ~ " cannot be empty");
    }

    size_t cursor;
    if (text[cursor] == '+' || text[cursor] == '-') {
        ++cursor;
    }
    const digitStart = cursor;
    while (
        cursor < text.length &&
        text[cursor] >= '0' &&
        text[cursor] <= '9'
    ) {
        ++cursor;
    }
    if (cursor == digitStart || cursor != text.length) {
        throw new OpbException(
            field ~ " must be a signed or unsigned decimal integer string"
        );
    }
    const digits = cursor - digitStart;
    if (digits > limits.maxIntegerDigits) {
        throw new OpbException(format(
            "%s has %s digits, exceeding configured limit %s",
            field,
            digits,
            limits.maxIntegerDigits
        ));
    }
    return BigInt(text);
}

private OpbRelation relationFromText(string text, string field) {
    switch (text) {
        case "<":
            return OpbRelation.less;
        case "<=":
        case "\u2264":
            return OpbRelation.lessEqual;
        case "=":
        case "==":
            return OpbRelation.equal;
        case "!=":
        case "\u2260":
            return OpbRelation.notEqual;
        case ">=":
        case "\u2265":
            return OpbRelation.greaterEqual;
        case ">":
            return OpbRelation.greater;
        default:
            throw new OpbException(
                field ~ " contains unsupported relation `" ~ text ~ "`"
            );
    }
}

private JSONValue termsToJson(const OpbTerm[] terms) {
    JSONValue[] values;
    foreach (term; terms) {
        JSONValue[string] value;
        value["coefficient"] =
            JSONValue(bigIntText(term.coefficient));
        const literal = term.negated
            ? -cast(long) term.variable
            : cast(long) term.variable;
        value["literal"] = JSONValue(literal);
        values ~= JSONValue(value);
    }
    return JSONValue(values);
}

private void appendTerms(
    ref typeof(appender!string()) output,
    const OpbTerm[] terms
) {
    foreach (term; terms) {
        output.put(" ");
        auto coefficient = bigIntText(term.coefficient);
        if (term.coefficient >= 0) {
            output.put("+");
        }
        output.put(coefficient);
        output.put(" ");
        if (term.negated) {
            output.put("~");
        }
        output.put("x");
        output.put(term.variable.to!string);
    }
}

private void appendStatement(
    ref typeof(appender!string()) output,
    string statement,
    OpbLimits limits
) {
    if (statement.length > limits.maxStatementBytes) {
        throw new OpbException(format(
            "serialized statement length %s exceeds configured limit %s",
            statement.length,
            limits.maxStatementBytes
        ));
    }
    output.put(statement);
    output.put("\n");
}

private string relationText(OpbRelation relation) {
    final switch (relation) {
        case OpbRelation.less:
            return "<";
        case OpbRelation.lessEqual:
            return "<=";
        case OpbRelation.equal:
            return "=";
        case OpbRelation.notEqual:
            return "!=";
        case OpbRelation.greaterEqual:
            return ">=";
        case OpbRelation.greater:
            return ">";
    }
}

private void validateRelation(OpbRelation relation) {
    switch (relation) {
        case OpbRelation.less:
        case OpbRelation.lessEqual:
        case OpbRelation.equal:
        case OpbRelation.notEqual:
        case OpbRelation.greaterEqual:
        case OpbRelation.greater:
            return;
        default:
            throw new OpbException("instance contains an invalid relation");
    }
}

private void validateSense(OpbObjectiveSense sense) {
    switch (sense) {
        case OpbObjectiveSense.minimize:
        case OpbObjectiveSense.maximize:
            return;
        default:
            throw new OpbException(
                "instance contains an invalid objective sense"
            );
    }
}

private void validateTerms(
    const OpbTerm[] terms,
    size_t numVariables,
    ref size_t totalTerms,
    OpbLimits limits,
    string field
) {
    if (terms.length == 0) {
        throw new OpbException(field ~ " must contain at least one term");
    }
    if (terms.length > limits.maxTermsPerStatement) {
        throw new OpbException(format(
            "%s has %s terms, exceeding configured per-statement limit %s",
            field,
            terms.length,
            limits.maxTermsPerStatement
        ));
    }
    checkedAccumulate(
        totalTerms,
        terms.length,
        limits.maxTerms,
        "total terms"
    );

    foreach (termIndex, term; terms) {
        if (
            term.variable == 0 ||
            cast(size_t) term.variable > numVariables
        ) {
            throw new OpbException(format(
                "%s term %s refers to x%s outside declared range 1..%s",
                field,
                termIndex + 1,
                term.variable,
                numVariables
            ));
        }
        validateBigInteger(
            term.coefficient,
            limits,
            format("%s coefficient %s", field, termIndex + 1)
        );
    }
}

private void validateBigInteger(
    const ref BigInt value,
    OpbLimits limits,
    string field
) {
    auto rendered = bigIntText(value);
    const digits =
        rendered.length != 0 && rendered[0] == '-'
            ? rendered.length - 1
            : rendered.length;
    if (digits > limits.maxIntegerDigits) {
        throw new OpbException(format(
            "%s has %s digits, exceeding configured limit %s",
            field,
            digits,
            limits.maxIntegerDigits
        ));
    }
}

private void validateVariableCount(
    size_t count,
    OpbLimits limits
) {
    if (count > limits.maxVariables) {
        throw new OpbException(format(
            "variable count %s exceeds configured limit %s",
            count,
            limits.maxVariables
        ));
    }
    if (count > uint.max) {
        throw new OpbException(format(
            "variable count %s exceeds the OPB xN identifier range %s",
            count,
            uint.max
        ));
    }
}

private void checkedAccumulate(
    ref size_t current,
    size_t increment,
    size_t limit,
    string field,
    size_t inputLine = 0
) {
    if (increment > limit || current > limit - increment) {
        throw new OpbException(
            format("%s exceeds configured limit %s", field, limit),
            inputLine
        );
    }
    current += increment;
}

private bool consumePrefix(
    string content,
    ref size_t cursor,
    string prefix
) {
    if (!content[cursor .. $].startsWith(prefix)) {
        return false;
    }
    cursor += prefix.length;
    return true;
}

private bool isRelationAt(string content, size_t cursor) {
    const remainder = content[cursor .. $];
    return remainder.startsWith("!=") ||
        remainder.startsWith("==") ||
        remainder.startsWith(">=") ||
        remainder.startsWith("<=") ||
        remainder.startsWith("\u2260") ||
        remainder.startsWith("\u2265") ||
        remainder.startsWith("\u2264") ||
        remainder.startsWith("=") ||
        remainder.startsWith(">") ||
        remainder.startsWith("<");
}

private bool looksLikeLiteral(string content, size_t cursor) {
    const remainder = content[cursor .. $];
    return remainder.startsWith("x") ||
        remainder.startsWith("~") ||
        remainder.startsWith("\u223C") ||
        remainder.startsWith("\u02DC");
}

private bool isRestrictedIdentifierCharacter(char character) {
    return (
        character >= 'a' && character <= 'z'
    ) || (
        character >= 'A' && character <= 'Z'
    ) || (
        character >= '0' && character <= '9'
    ) || character == '_';
}

private bool isOpbWhitespace(char character) {
    return character == ' ' ||
        character == '\t' ||
        character == '\v' ||
        character == '\f' ||
        character == '\r' ||
        character == '\n';
}

private string bigIntText(const ref BigInt value) {
    return value.to!string;
}

private BigInt absoluteCopy(const ref BigInt value) {
    auto result = BigInt(bigIntText(value));
    if (result < 0) {
        result = -result;
    }
    return result;
}

version (unittest) {
    private long evaluateTestInteger(
        ExpressionNode node,
        const(long)[] assignment
    ) {
        final switch (node.kind) {
            case ExpressionKind.integerConstant:
                return node.integerValue;
            case ExpressionKind.variable:
                return assignment[node.variableIndex];
            case ExpressionKind.add:
                return evaluateTestInteger(node.children[0], assignment) +
                    evaluateTestInteger(node.children[1], assignment);
            case ExpressionKind.subtract:
                return evaluateTestInteger(node.children[0], assignment) -
                    evaluateTestInteger(node.children[1], assignment);
            case ExpressionKind.multiply:
                return evaluateTestInteger(node.children[0], assignment) *
                    evaluateTestInteger(node.children[1], assignment);
            case ExpressionKind.negate:
                return -evaluateTestInteger(node.children[0], assignment);
            case ExpressionKind.booleanAsInteger:
                return evaluateTestInteger(node.children[0], assignment);

            case ExpressionKind.booleanConstant:
            case ExpressionKind.logicalNot:
            case ExpressionKind.logicalAnd:
            case ExpressionKind.logicalOr:
            case ExpressionKind.logicalXor:
            case ExpressionKind.implies:
            case ExpressionKind.equivalent:
            case ExpressionKind.equal:
            case ExpressionKind.notEqual:
            case ExpressionKind.lessThan:
            case ExpressionKind.lessEqual:
            case ExpressionKind.greaterThan:
            case ExpressionKind.greaterEqual:
            case ExpressionKind.allDifferent:
                assert(0, "unexpected Boolean node in OPB integer expression");
        }
    }

    private bool evaluateTestBoolean(
        ExpressionNode node,
        const(long)[] assignment
    ) {
        final switch (node.kind) {
            case ExpressionKind.equal:
                return evaluateTestInteger(node.children[0], assignment) ==
                    evaluateTestInteger(node.children[1], assignment);
            case ExpressionKind.notEqual:
                return evaluateTestInteger(node.children[0], assignment) !=
                    evaluateTestInteger(node.children[1], assignment);
            case ExpressionKind.lessThan:
                return evaluateTestInteger(node.children[0], assignment) <
                    evaluateTestInteger(node.children[1], assignment);
            case ExpressionKind.lessEqual:
                return evaluateTestInteger(node.children[0], assignment) <=
                    evaluateTestInteger(node.children[1], assignment);
            case ExpressionKind.greaterThan:
                return evaluateTestInteger(node.children[0], assignment) >
                    evaluateTestInteger(node.children[1], assignment);
            case ExpressionKind.greaterEqual:
                return evaluateTestInteger(node.children[0], assignment) >=
                    evaluateTestInteger(node.children[1], assignment);

            case ExpressionKind.booleanConstant:
                return node.booleanValue;
            case ExpressionKind.logicalNot:
                return !evaluateTestBoolean(node.children[0], assignment);
            case ExpressionKind.logicalAnd:
                return evaluateTestBoolean(node.children[0], assignment) &&
                    evaluateTestBoolean(node.children[1], assignment);
            case ExpressionKind.logicalOr:
                return evaluateTestBoolean(node.children[0], assignment) ||
                    evaluateTestBoolean(node.children[1], assignment);
            case ExpressionKind.logicalXor:
                return evaluateTestBoolean(node.children[0], assignment) !=
                    evaluateTestBoolean(node.children[1], assignment);
            case ExpressionKind.implies:
                return !evaluateTestBoolean(node.children[0], assignment) ||
                    evaluateTestBoolean(node.children[1], assignment);
            case ExpressionKind.equivalent:
                return evaluateTestBoolean(node.children[0], assignment) ==
                    evaluateTestBoolean(node.children[1], assignment);

            case ExpressionKind.integerConstant:
            case ExpressionKind.variable:
            case ExpressionKind.add:
            case ExpressionKind.subtract:
            case ExpressionKind.multiply:
            case ExpressionKind.negate:
            case ExpressionKind.booleanAsInteger:
            case ExpressionKind.allDifferent:
                assert(0, "unexpected integer node in OPB Boolean expression");
        }
    }
}

unittest {
    import std.exception : assertThrown;

    enum input =
        "* #variable= 5 #constraint= 2 #equal= 1 intsize= 130\n" ~
        "* arbitrary precision and an intentionally unused x5\n" ~
        "max: +123456789012345678901234567890 x1 -7 ~x2 ;\n" ~
        "+1 x1 +2 ~x2 >= -3 ;\n" ~
        "+4 x1 -9 x4 == 2 ;\n";

    auto parsed = parseOpb(input);
    assert(parsed.numVariables == 5);
    assert(parsed.hasObjective);
    assert(parsed.objective.sense == OpbObjectiveSense.maximize);
    assert(parsed.objective.terms[1].negated);
    assert(
        parsed.objective.terms[0].coefficient ==
            BigInt("123456789012345678901234567890")
    );
    assert(parsed.constraints.length == 2);
    assert(parsed.constraints[1].relation == OpbRelation.equal);
    assert(parsed.comments.length == 1);

    auto json = parsed.toDocumentJson();
    assert(json["opb"]["num_vars"].integer == 5);
    assert(
        json["opb"]["objective"]["terms"][0]["coefficient"].str ==
            "123456789012345678901234567890"
    );
    assert(
        json["opb"]["objective"]["terms"][1]["literal"].integer == -2
    );

    auto roundTrip = parseOpb(parsed.toOpb());
    assert(roundTrip.numVariables == 5);
    assert(roundTrip.constraints.length == 2);
    assert(roundTrip.objective.terms[0].coefficient ==
        parsed.objective.terms[0].coefficient);

    assertThrown!OpbException(parseOpb(
        "* #variable= 2 #constraint= 1\n" ~
        "+1 x1 x2 >= 1 ;\n"
    ));
    assertThrown!OpbException(parseOpb(
        "soft: 10 ;\n" ~
        "[2] +1 x1 >= 1 ;\n"
    ));
}

unittest {
    enum relations =
        "+1 x1 < 1 ;\n" ~
        "+1 x1 <= 1 ;\n" ~
        "+1 x1 = 1 ;\n" ~
        "+1 x1 == 1 ;\n" ~
        "+1 x1 != 1 ;\n" ~
        "+1 x1 >= 1 ;\n" ~
        "+1 x1 > 1 ;\n";
    auto parsed = parseOpb(relations);
    assert(parsed.constraints.length == 7);
    assert(parsed.constraints[0].relation == OpbRelation.less);
    assert(parsed.constraints[1].relation == OpbRelation.lessEqual);
    assert(parsed.constraints[2].relation == OpbRelation.equal);
    assert(parsed.constraints[3].relation == OpbRelation.equal);
    assert(parsed.constraints[4].relation == OpbRelation.notEqual);
    assert(parsed.constraints[5].relation == OpbRelation.greaterEqual);
    assert(parsed.constraints[6].relation == OpbRelation.greater);

    auto unicode = parseOpb(
        "+1 \u223Cx1 \u2265 0 ;\n" ~
        "+1 x1 \u2264 1 ;\n" ~
        "+1 x1 \u2260 2 ;\n"
    );
    assert(unicode.constraints[0].terms[0].negated);
    assert(unicode.constraints[0].relation == OpbRelation.greaterEqual);
    assert(unicode.constraints[1].relation == OpbRelation.lessEqual);
    assert(unicode.constraints[2].relation == OpbRelation.notEqual);
}

unittest {
    import std.exception : assertThrown;

    // Line-oriented PB generators intentionally emit one statement per line without
    // the semicolon required by the official OPB grammar.
    enum pbgenDialect =
        "* #variable= 12 #constraint= 7\n" ~
        "* generator: pbgen\n" ~
        "+1 x1 +1 x2 +1 x3 >= 1\n" ~
        "+1 x4 +1 x5 +1 x6 >= 1\n" ~
        "+1 x7 +1 x8 +1 x9 >= 1\n" ~
        "+1 x10 +1 x11 +1 x12 >= 1\n" ~
        "+1 ~x1 +1 ~x4 +1 ~x7 +1 ~x10 >= 3\n" ~
        "+1 ~x2 +1 ~x5 +1 ~x8 +1 ~x11 >= 3\n" ~
        "+1 ~x3 +1 ~x6 +1 ~x9 +1 ~x12 >= 3\n";
    auto parsed = parseOpb(pbgenDialect);
    assert(parsed.numVariables == 12);
    assert(parsed.constraints.length == 7);
    assert(parsed.constraints[4].terms[0].negated);
    assert(parsed.toOpb().indexOf(";") >= 0);

    OpbLimits small;
    small.maxVariables = 11;
    assertThrown!OpbException(parseOpb(pbgenDialect, small));

    OpbLimits shortIntegers;
    shortIntegers.maxIntegerDigits = 3;
    assertThrown!OpbException(parseOpb(
        "+1234 x1 >= 1 ;\n",
        shortIntegers
    ));

    assertThrown!OpbException(parseOpb(
        "* #variable= 2 #constraint= 2\n" ~
        "+1 x1 >= 1\n"
    ));
}

unittest {
    import std.exception : assertThrown;

    enum huge = "9223372036854775808";
    enum executable =
        "* #variable= 2 #constraint= 1\n" ~
        "max: +" ~ huge ~ " x1 -" ~ huge ~
            " x1 +5 ~x1 +2 x1 ;\n" ~
        "+" ~ huge ~ " x1 -" ~ huge ~
            " x1 +5 ~x1 +2 x1 >= 3 ;\n";

    auto parsed = parseOpb(executable);
    auto document = parsed.toDocumentJson();
    auto decoded = opbFromDocumentJson(document);
    assert(decoded.numVariables == 2);
    assert(decoded.objective.terms.length == 4);

    auto model = new Model("opb-executable");
    populateModelFromOpbDocument(model, document);
    assert(model.variables.length == 2);
    assert(model.variables[0].name == "x1");
    assert(model.variables[1].name == "x2");
    assert(model.constraints.length == 1);
    assert(model.constraints[0].name == "opb.constraint.1");
    assert(model.objectives.length == 1);
    assert(model.objectives[0].name == "opb.objective");

    // After exact BigInt aggregation:
    //   huge*x - huge*x + 5*~x + 2*x == 5 - 3*x.
    assert(evaluateTestBoolean(
        model.constraints[0].expression.node,
        [0L, 0L]
    ));
    assert(!evaluateTestBoolean(
        model.constraints[0].expression.node,
        [1L, 0L]
    ));
    assert(evaluateTestInteger(
        model.objectives[0].expression.node,
        [0L, 0L]
    ) == 5);
    assert(evaluateTestInteger(
        model.objectives[0].expression.node,
        [1L, 0L]
    ) == 2);

    auto unknownField = parsed.toDocumentJson();
    unknownField.object["unexpected"] = JSONValue(true);
    assertThrown!OpbException(opbFromDocumentJson(unknownField));

    auto numericCoefficient = parsed.toDocumentJson();
    numericCoefficient["opb"]["objective"]["terms"][0]["coefficient"] =
        JSONValue(1);
    assertThrown!OpbException(opbFromDocumentJson(numericCoefficient));

    auto coefficientOverflow = parseOpb(
        "+" ~ huge ~ " x1 >= 0 ;\n"
    );
    auto coefficientModel = new Model;
    assertThrown!CapabilityException(populateModelFromOpb(
        coefficientModel,
        coefficientOverflow
    ));
    assert(coefficientModel.variables.length == 0);

    auto constantOverflow = parseOpb(
        "+" ~ huge ~ " ~x1 +" ~ huge ~ " x1 >= 0 ;\n"
    );
    auto constantModel = new Model;
    assertThrown!CapabilityException(populateModelFromOpb(
        constantModel,
        constantOverflow
    ));
    assert(constantModel.variables.length == 0);

    auto rightHandSideOverflow = parseOpb(
        "+1 ~x1 >= -9223372036854775808 ;\n"
    );
    auto rightHandSideModel = new Model;
    assertThrown!CapabilityException(populateModelFromOpb(
        rightHandSideModel,
        rightHandSideOverflow
    ));
    assert(rightHandSideModel.variables.length == 0);
}