// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.document;

import reify.app : NavokojApp, decisionApp;
import reify.errors : ModelException;
import reify.model;
import reify.opb : populateModelFromOpbDocument;

import std.algorithm : canFind;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;

private enum maximumObjectivePriority = 1_024;

/**
 * Build the standalone application which consumes the universal JSON model
 * document described in README.md.
 */
NavokojApp documentApp() {
    return decisionApp(
        "navokoj-app",
        (Model model, JSONValue input) {
            new DocumentParser(model, input).parse();
        }
    );
}

private final class DocumentParser {
    Model model;
    JSONValue document;
    BoolExpr[string] booleans;
    BoolExpr[] booleanOrder;
    IntExpr[string] integers;
    CategoryExpr[string] categories;

    this(Model model, JSONValue document) {
        this.model = model;
        this.document = document;
    }

    void parse() {
        auto root = requireObject(document, "document");
        ensureOnlyFields(
            root,
            [
                "name",
                "variables",
                "cnf",
                "opb",
                "constraints",
                "objectives",
                "parity_constraints"
            ],
            "document"
        );
        auto documentName = "name" in root;
        if (documentName !is null) {
            if (documentName.type != JSONType.string) {
                throw new ModelException("'name' must be a string");
            }
            if (documentName.str.length == 0) {
                throw new ModelException("'name' cannot be empty");
            }
            model.name = documentName.str;
        }

        auto variableValue = "variables" in root;
        auto cnfValue = "cnf" in root;
        auto opbValue = "opb" in root;
        if (
            variableValue is null &&
            cnfValue is null &&
            opbValue is null
        ) {
            throw new ModelException(
                "Document requires 'variables', a raw 'cnf', or a linear 'opb' object"
            );
        }

        if (opbValue !is null) {
            if (
                variableValue !is null ||
                cnfValue !is null ||
                ("constraints" in root) !is null ||
                ("objectives" in root) !is null ||
                ("parity_constraints" in root) !is null
            ) {
                throw new ModelException(
                    "A compact 'opb' document cannot be mixed with variables, " ~
                    "CNF, symbolic constraints, objectives, or parity constraints"
                );
            }
            JSONValue[string] compact;
            compact["opb"] = *opbValue;
            populateModelFromOpbDocument(model, JSONValue(compact));
            return;
        }

        if (variableValue !is null) {
            if (variableValue.type != JSONType.array) {
                throw new ModelException("'variables' must be an array");
            }
            foreach (entry; variableValue.array) {
                parseVariable(entry);
            }
        }
        if (cnfValue !is null) {
            parseNativeCnf(*cnfValue, variableValue !is null);
        }

        auto constraints = "constraints" in root;
        if (constraints !is null) {
            if (constraints.type != JSONType.array) {
                throw new ModelException("'constraints' must be an array");
            }
            foreach (entry; constraints.array) {
                parseConstraint(entry);
            }
        }

        auto objectives = "objectives" in root;
        if (objectives !is null) {
            if (objectives.type != JSONType.array) {
                throw new ModelException("'objectives' must be an array");
            }
            foreach (entry; objectives.array) {
                parseObjective(entry);
            }
        }

        auto parityConstraints = "parity_constraints" in root;
        if (parityConstraints !is null) {
            if (parityConstraints.type != JSONType.array) {
                throw new ModelException(
                    "'parity_constraints' must be an array"
                );
            }
            foreach (entry; parityConstraints.array) {
                parseParity(entry);
            }
        }
    }

    private void parseVariable(JSONValue value) {
        auto object = requireObject(value, "variable");
        const name = requireString(object, "name");
        const type = requireString(object, "type");

        switch (type) {
            case "boolean":
            case "bool":
                ensureOnlyFields(
                    object,
                    ["name", "type"],
                    "Boolean variable '" ~ name ~ "'"
                );
                auto expression = model.booleanVar(name);
                booleans[name] = expression;
                booleanOrder ~= expression;
                break;

            case "integer":
            case "int":
                ensureOnlyFields(
                    object,
                    ["name", "type", "lower", "upper"],
                    "integer variable '" ~ name ~ "'"
                );
                integers[name] = model.integerVar(
                    name,
                    requireInteger(object, "lower"),
                    requireInteger(object, "upper")
                );
                break;

            case "categorical":
            case "category":
                ensureOnlyFields(
                    object,
                    ["name", "type", "states"],
                    "categorical variable '" ~ name ~ "'"
                );
                auto stateValue = requireField(object, "states");
                if (stateValue.type != JSONType.array) {
                    throw new ModelException(
                        "Variable '" ~ name ~ "' states must be an array"
                    );
                }
                string[] states;
                foreach (state; stateValue.array) {
                    if (state.type != JSONType.string) {
                        throw new ModelException(
                            "Categorical states must be strings"
                        );
                    }
                    states ~= state.str;
                }
                auto category = model.categoricalVar(name, states);
                categories[name] = category;
                integers[name] = category.asInteger();
                break;

            default:
                throw new ModelException(
                    "Unknown variable type '" ~ type ~ "'"
                );
        }
    }

    private void parseNativeCnf(
        JSONValue value,
        bool hasDeclaredVariables
    ) {
        auto object = requireObject(value, "cnf");
        ensureOnlyFields(
            object,
            ["num_vars", "clauses", "variable_labels", "comments"],
            "cnf"
        );

        const countValue = requireInteger(object, "num_vars");
        if (countValue < 0 || countValue > int.max) {
            throw new ModelException(format(
                "cnf.num_vars must be between 0 and %s",
                int.max
            ));
        }
        const variableCount = cast(size_t) countValue;

        string[size_t] labels;
        auto labelValue = "variable_labels" in object;
        if (labelValue !is null) {
            if (labelValue.type != JSONType.object) {
                throw new ModelException(
                    "cnf.variable_labels must be an object keyed by one-based IDs"
                );
            }
            foreach (key, label; labelValue.object) {
                if (label.type != JSONType.string || label.str.length == 0) {
                    throw new ModelException(
                        "CNF variable labels must be non-empty strings"
                    );
                }
                long parsed;
                try {
                    parsed = key.to!long;
                } catch (Exception error) {
                    throw new ModelException(
                        "Invalid CNF variable label ID '" ~ key ~ "'"
                    );
                }
                if (parsed <= 0 || parsed > countValue) {
                    throw new ModelException(format(
                        "CNF variable label ID %s is outside 1..%s",
                        parsed,
                        countValue
                    ));
                }
                labels[cast(size_t) parsed] = label.str;
            }
        }

        auto comments = "comments" in object;
        if (comments !is null) {
            if (comments.type != JSONType.array) {
                throw new ModelException("cnf.comments must be an array");
            }
            foreach (comment; comments.array) {
                if (comment.type != JSONType.string) {
                    throw new ModelException(
                        "Every CNF comment must be a string"
                    );
                }
            }
        }

        if (hasDeclaredVariables) {
            if (
                model.internalVariables.length != variableCount ||
                booleanOrder.length != variableCount
            ) {
                throw new ModelException(
                    "A raw CNF combined with 'variables' requires exactly " ~
                    "num_vars Boolean variables in declaration order"
                );
            }
        } else {
            foreach (wireId; 1 .. variableCount + 1) {
                auto found = wireId in labels;
                auto requested = found is null
                    ? "x" ~ wireId.to!string
                    : *found;
                auto resolved = requested;
                size_t suffix = wireId;
                while (model.hasVariable(resolved)) {
                    resolved =
                        requested ~ "#" ~ suffix.to!string;
                    ++suffix;
                }
                auto expression = model.booleanVar(resolved);
                booleans[resolved] = expression;
                booleanOrder ~= expression;
            }
        }

        auto clauses = requireField(object, "clauses");
        if (clauses.type != JSONType.array) {
            throw new ModelException("cnf.clauses must be an array");
        }
        foreach (clauseIndex, clauseValue; clauses.array) {
            if (clauseValue.type != JSONType.array) {
                throw new ModelException(
                    "Every CNF clause must be an array of signed integers"
                );
            }
            BoolExpr[] literals;
            foreach (literalValue; clauseValue.array) {
                const literal = asInteger(literalValue, "CNF literal");
                if (
                    literal == 0 ||
                    literal < -countValue ||
                    literal > countValue
                ) {
                    throw new ModelException(format(
                        "CNF literal %s is outside the declared range -%s..%s " ~
                        "or is zero",
                        literal,
                        countValue,
                        countValue
                    ));
                }
                const id = cast(size_t) (
                    literal < 0 ? -literal : literal
                );
                auto expression = booleanOrder[id - 1];
                literals ~= literal < 0
                    ? logicalNot(expression)
                    : expression;
            }
            model.requireClause(
                "$cnf:" ~ (clauseIndex + 1).to!string,
                literals
            );
        }
    }

    private void parseConstraint(JSONValue value) {
        auto object = requireObject(value, "constraint");
        ensureOnlyFields(
            object,
            ["name", "level", "weight", "expression"],
            "constraint"
        );
        const name = requireString(object, "name");
        const level = optionalString(object, "level", "hard");
        const weight = optionalNumber(object, "weight", 1.0);
        auto expression = parseBoolean(requireField(object, "expression"));

        switch (level) {
            case "hard":
            case "required":
                if (("weight" in object) !is null) {
                    throw new ModelException(
                        "Hard constraint '" ~ name ~
                        "' cannot declare a weight; weights are only valid " ~
                        "for medium and soft constraints"
                    );
                }
                model.require(name, expression);
                break;
            case "medium":
                model.medium(name, expression, weight);
                break;
            case "soft":
            case "preferred":
                model.prefer(name, expression, weight);
                break;
            default:
                throw new ModelException(
                    "Unknown constraint level '" ~ level ~ "'"
                );
        }
    }

    private void parseObjective(JSONValue value) {
        auto object = requireObject(value, "objective");
        ensureOnlyFields(
            object,
            ["name", "sense", "priority", "expression"],
            "objective"
        );
        const name = requireString(object, "name");
        const sense = optionalString(object, "sense", "maximize");
        const priorityValue = optionalInteger(object, "priority", 0);
        if (
            priorityValue < 0 ||
            priorityValue > maximumObjectivePriority
        ) {
            throw new ModelException(format(
                "Objective priority must be between 0 and %s",
                maximumObjectivePriority
            ));
        }
        const priority = cast(int) priorityValue;
        auto expression = parseInteger(requireField(object, "expression"));

        switch (sense) {
            case "maximize":
            case "max":
                model.maximize(name, expression, priority);
                break;
            case "minimize":
            case "min":
                model.minimize(name, expression, priority);
                break;
            default:
                throw new ModelException(
                    "Unknown objective sense '" ~ sense ~ "'"
                );
        }
    }

    private void parseParity(JSONValue value) {
        auto object = requireObject(value, "parity constraint");
        ensureOnlyFields(
            object,
            ["name", "variables", "target"],
            "parity constraint"
        );
        const name = requireString(object, "name");
        const targetValue = requireInteger(object, "target");
        if (targetValue != 0 && targetValue != 1) {
            throw new ModelException(
                "Parity constraint target must be either 0 or 1"
            );
        }
        const target = cast(int) targetValue;
        auto variables = requireField(object, "variables");
        if (variables.type != JSONType.array) {
            throw new ModelException(
                "Parity constraint variables must be an array"
            );
        }

        BoolExpr[] expressions;
        foreach (variable; variables.array) {
            if (variable.type != JSONType.string) {
                throw new ModelException(
                    "Parity variable names must be strings"
                );
            }
            expressions ~= lookupBoolean(variable.str);
        }
        model.parity(name, expressions, target);
    }

    private BoolExpr parseBoolean(JSONValue value) {
        if (value.type == JSONType.true_ || value.type == JSONType.false_) {
            return boolean(value.boolean);
        }
        if (value.type == JSONType.string) {
            return lookupBoolean(value.str);
        }

        auto object = requireObject(value, "Boolean expression");
        if ("var" in object) {
            ensureOnlyFields(object, ["var"], "Boolean variable expression");
            return lookupBoolean(requireString(object, "var"));
        }

        const operator = requireString(object, "op");
        switch (operator) {
            case "not":
                ensureOnlyFields(object, ["op", "arg"], "'not' expression");
                return logicalNot(
                    parseBoolean(requireField(object, "arg"))
                );

            case "and":
                ensureOnlyFields(object, ["op", "args"], "'and' expression");
                return foldBoolean(
                    requireArguments(object),
                    true,
                    ExpressionKind.logicalAnd
                );

            case "or":
                ensureOnlyFields(object, ["op", "args"], "'or' expression");
                return foldBoolean(
                    requireArguments(object),
                    false,
                    ExpressionKind.logicalOr
                );

            case "xor":
                ensureOnlyFields(object, ["op", "args"], "'xor' expression");
                return foldBoolean(
                    requireArguments(object),
                    false,
                    ExpressionKind.logicalXor
                );

            case "implies":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'implies' expression"
                );
                return implies(
                    parseBoolean(requireField(object, "left")),
                    parseBoolean(requireField(object, "right"))
                );

            case "iff":
            case "equivalent":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'" ~ operator ~ "' expression"
                );
                return equivalent(
                    parseBoolean(requireField(object, "left")),
                    parseBoolean(requireField(object, "right"))
                );

            case "eq":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'eq' expression"
                );
                return equal(
                    parseInteger(requireField(object, "left")),
                    parseInteger(requireField(object, "right"))
                );
            case "ne":
            case "neq":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'" ~ operator ~ "' expression"
                );
                return notEqual(
                    parseInteger(requireField(object, "left")),
                    parseInteger(requireField(object, "right"))
                );
            case "lt":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'lt' expression"
                );
                return lessThan(
                    parseInteger(requireField(object, "left")),
                    parseInteger(requireField(object, "right"))
                );
            case "le":
            case "lte":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'" ~ operator ~ "' expression"
                );
                return lessEqual(
                    parseInteger(requireField(object, "left")),
                    parseInteger(requireField(object, "right"))
                );
            case "gt":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'gt' expression"
                );
                return greaterThan(
                    parseInteger(requireField(object, "left")),
                    parseInteger(requireField(object, "right"))
                );
            case "ge":
            case "gte":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'" ~ operator ~ "' expression"
                );
                return greaterEqual(
                    parseInteger(requireField(object, "left")),
                    parseInteger(requireField(object, "right"))
                );

            case "is":
                ensureOnlyFields(
                    object,
                    ["op", "var", "state"],
                    "'is' expression"
                );
                return lookupCategory(requireString(object, "var"))
                    .equals(requireString(object, "state"));

            case "is_not":
                ensureOnlyFields(
                    object,
                    ["op", "var", "state"],
                    "'is_not' expression"
                );
                return lookupCategory(requireString(object, "var"))
                    .differs(requireString(object, "state"));

            case "same":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'same' expression"
                );
                return lookupCategory(requireString(object, "left")).same(
                    lookupCategory(requireString(object, "right"))
                );

            case "different":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'different' expression"
                );
                return lookupCategory(requireString(object, "left")).different(
                    lookupCategory(requireString(object, "right"))
                );

            case "all_different":
                ensureOnlyFields(
                    object,
                    ["op", "args"],
                    "'all_different' expression"
                );
                auto arguments = requireArguments(object);
                CategoryExpr[] values;
                foreach (argument; arguments) {
                    if (argument.type != JSONType.string) {
                        throw new ModelException(
                            "all_different arguments must be categorical names"
                        );
                    }
                    values ~= lookupCategory(argument.str);
                }
                return allDifferent(values);

            case "at_most":
            case "at_least":
            case "exactly":
                ensureOnlyFields(
                    object,
                    ["op", "args", "count"],
                    "'" ~ operator ~ "' expression"
                );
                auto arguments = requireArguments(object);
                BoolExpr[] values;
                foreach (argument; arguments) {
                    values ~= parseBoolean(argument);
                }
                const countValue = requireInteger(object, "count");
                if (countValue < 0) {
                    throw new ModelException(
                        "Cardinality count must be non-negative"
                    );
                }
                if (cast(ulong) countValue > size_t.max) {
                    throw new ModelException(
                        "Cardinality count exceeds the platform size range"
                    );
                }
                const count = cast(size_t) countValue;
                if (operator == "at_most") {
                    return atMost(count, values);
                }
                if (operator == "at_least") {
                    return atLeast(count, values);
                }
                return exactly(count, values);

            default:
                throw new ModelException(
                    "Unknown Boolean operator '" ~ operator ~ "'"
                );
        }
    }

    private IntExpr parseInteger(JSONValue value) {
        if (
            value.type == JSONType.integer ||
            value.type == JSONType.uinteger
        ) {
            return integer(asInteger(value, "integer literal"));
        }
        if (value.type == JSONType.string) {
            return lookupInteger(value.str);
        }

        auto object = requireObject(value, "integer expression");
        if ("var" in object) {
            ensureOnlyFields(object, ["var"], "integer variable expression");
            return lookupInteger(requireString(object, "var"));
        }
        if ("value" in object) {
            ensureOnlyFields(object, ["value"], "integer literal expression");
            return integer(asInteger(object["value"], "integer value"));
        }

        const operator = requireString(object, "op");
        switch (operator) {
            case "add":
            case "sum":
                ensureOnlyFields(
                    object,
                    ["op", "args"],
                    "'" ~ operator ~ "' expression"
                );
                auto arguments = requireArguments(object);
                IntExpr[] expressions;
                foreach (argument; arguments) {
                    expressions ~= parseInteger(argument);
                }
                return sumExpr(expressions);

            case "sub":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'sub' expression"
                );
                return parseInteger(requireField(object, "left")) -
                    parseInteger(requireField(object, "right"));

            case "neg":
                ensureOnlyFields(object, ["op", "arg"], "'neg' expression");
                return -parseInteger(requireField(object, "arg"));

            case "mul":
                ensureOnlyFields(
                    object,
                    ["op", "left", "right"],
                    "'mul' expression"
                );
                auto left = requireField(object, "left");
                auto right = requireField(object, "right");
                if (isIntegerLiteral(left)) {
                    return parseInteger(right) *
                        asInteger(left, "multiplication coefficient");
                }
                if (isIntegerLiteral(right)) {
                    return parseInteger(left) *
                        asInteger(right, "multiplication coefficient");
                }
                throw new ModelException(
                    "Multiplication requires one constant integer operand; " ~
                    "variable-by-variable products need a future QP backend"
                );

            default:
                throw new ModelException(
                    "Unknown integer operator '" ~ operator ~ "'"
                );
        }
    }

    private BoolExpr foldBoolean(
        JSONValue[] arguments,
        bool identity,
        ExpressionKind kind
    ) {
        auto result = boolean(identity);
        foreach (argument; arguments) {
            auto expression = parseBoolean(argument);
            switch (kind) {
                case ExpressionKind.logicalAnd:
                    result = result & expression;
                    break;
                case ExpressionKind.logicalOr:
                    result = result | expression;
                    break;
                case ExpressionKind.logicalXor:
                    result = result ^ expression;
                    break;
                default:
                    throw new ModelException(
                        "Internal error: invalid Boolean fold operator"
                    );
            }
        }
        return result;
    }

    private BoolExpr lookupBoolean(string name) {
        auto found = name in booleans;
        if (found is null) {
            throw new ModelException(
                "Unknown Boolean variable '" ~ name ~ "'"
            );
        }
        return *found;
    }

    private IntExpr lookupInteger(string name) {
        auto found = name in integers;
        if (found is null) {
            throw new ModelException(
                "Unknown integer/categorical variable '" ~ name ~ "'"
            );
        }
        return *found;
    }

    private CategoryExpr lookupCategory(string name) {
        auto found = name in categories;
        if (found is null) {
            throw new ModelException(
                "Unknown categorical variable '" ~ name ~ "'"
            );
        }
        return *found;
    }
}

private JSONValue[string] requireObject(JSONValue value, string context) {
    if (value.type != JSONType.object) {
        throw new ModelException(context ~ " must be a JSON object");
    }
    return value.object;
}

private void ensureOnlyFields(
    JSONValue[string] object,
    const(string)[] allowed,
    string context
) {
    foreach (name; object.keys) {
        if (!allowed.canFind(name)) {
            throw new ModelException(
                context ~ " contains unknown field '" ~ name ~ "'"
            );
        }
    }
}

private JSONValue requireField(
    JSONValue[string] object,
    string name
) {
    auto found = name in object;
    if (found is null) {
        throw new ModelException("Missing required field '" ~ name ~ "'");
    }
    return *found;
}

private string requireString(
    JSONValue[string] object,
    string name
) {
    auto value = requireField(object, name);
    if (value.type != JSONType.string) {
        throw new ModelException("Field '" ~ name ~ "' must be a string");
    }
    return value.str;
}

private string optionalString(
    JSONValue[string] object,
    string name,
    string defaultValue
) {
    auto found = name in object;
    if (found is null) {
        return defaultValue;
    }
    if (found.type != JSONType.string) {
        throw new ModelException("Field '" ~ name ~ "' must be a string");
    }
    return found.str;
}

private long requireInteger(
    JSONValue[string] object,
    string name
) {
    return asInteger(requireField(object, name), name);
}

private long optionalInteger(
    JSONValue[string] object,
    string name,
    long defaultValue
) {
    auto found = name in object;
    return found is null ? defaultValue : asInteger(*found, name);
}

private double optionalNumber(
    JSONValue[string] object,
    string name,
    double defaultValue
) {
    auto found = name in object;
    if (found is null) {
        return defaultValue;
    }
    if (found.type == JSONType.float_) {
        return found.floating;
    }
    return cast(double) asInteger(*found, name);
}

private long asInteger(JSONValue value, string context) {
    if (value.type == JSONType.integer) {
        return value.integer;
    }
    if (value.type == JSONType.uinteger) {
        if (value.uinteger > long.max) {
            throw new ModelException(context ~ " exceeds signed integer range");
        }
        return cast(long) value.uinteger;
    }
    throw new ModelException(context ~ " must be an integer");
}

private bool isIntegerLiteral(JSONValue value) {
    return value.type == JSONType.integer ||
        value.type == JSONType.uinteger;
}

private JSONValue[] requireArguments(JSONValue[string] object) {
    auto value = requireField(object, "args");
    if (value.type != JSONType.array) {
        throw new ModelException("'args' must be an array");
    }
    return value.array;
}