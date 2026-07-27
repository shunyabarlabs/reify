// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.exports;

/**
 * Portable artifact exports for compiled Navokoj models.
 *
 * Exporters operate on the same CompiledModel used by the cloud client, so
 * local solver artifacts and remote requests share one lowering boundary.
 *
 * Viewed through the Kripke-inspired SpaceTime model, export is finite-model
 * reduction: named worlds and their accessibility-derived laws become Boolean
 * atoms and clauses. The verification manifest preserves the interpretation
 * needed to map a satisfying valuation back to domain worlds.
 */

import reify.compiler :
    CompileOptions,
    CompiledModel,
    backendName,
    compileModel = compile;
import reify.errors : CapabilityException;
import reify.model : ConstraintLevel, Model, VariableKind;

import std.array : appender;
import std.conv : to;
import std.json : JSONValue;
import std.math : floor, isFinite;

struct CNF {}
struct WCNF {}
struct DIMACS {}
struct OPB {}
struct NavokojIR {}

/**
 * A portable solver payload plus the provenance needed to hydrate and verify
 * assignments independently.
 */
struct ExportArtifact {
    string format;
    string payload;
    JSONValue verificationManifest;
}

/**
 * Type-directed export:
 *
 *   auto dimacs = model.emit!DIMACS();
 *   auto weighted = model.emit!WCNF();
 *   auto cloud = model.emit!NavokojIR();
 */
ExportArtifact emit(Target)(
    Model model,
    CompileOptions options = CompileOptions()
) {
    static if (is(Target == NavokojIR)) {
        auto compiled = compileModel(model, options);
        return ExportArtifact(
            "navokoj-ir",
            compiled.request.toPrettyString(),
            verificationManifest(compiled)
        );
    } else {
        // Portable Boolean formats need an exact clause lowering. Specialized
        // Q-State and native-XOR transport forms are deliberately disabled.
        options.preferQState = false;
        options.preferNativeParity = false;
        auto compiled = compileModel(model, options);

        static if (is(Target == CNF)) {
            requireHardOnly(compiled, "CNF");
            return ExportArtifact(
                "cnf",
                cnfJson(compiled).toPrettyString(),
                verificationManifest(compiled)
            );
        } else static if (is(Target == DIMACS)) {
            requireHardOnly(compiled, "DIMACS CNF");
            return ExportArtifact(
                "dimacs",
                dimacsText(compiled),
                verificationManifest(compiled)
            );
        } else static if (is(Target == WCNF)) {
            return ExportArtifact(
                "wcnf",
                wcnfText(compiled),
                verificationManifest(compiled)
            );
        } else static if (is(Target == OPB)) {
            requireHardOnly(compiled, "OPB");
            return ExportArtifact(
                "opb",
                opbText(compiled),
                verificationManifest(compiled)
            );
        } else {
            static assert(false, "Unsupported Navokoj export target");
        }
    }
}

JSONValue verificationManifest(CompiledModel compiled) {
    // A SAT assignment alone is only an anonymous valuation. This manifest
    // retains the interpretation function that maps encoded atoms and clauses
    // back to logical dimensions, decisions, and policy provenance.
    JSONValue[string] root;
    root["model"] = JSONValue(compiled.model.name);
    root["backend"] = JSONValue(backendName(compiled.backend));
    root["encoded_variables"] =
        JSONValue(cast(long) compiled.generatedVariableCount);

    JSONValue[] semanticOperations;
    foreach (operation; compiled.model.semanticOperations) {
        JSONValue[string] entry;
        entry["id"] = JSONValue(operation.id);
        entry["parent_id"] = JSONValue(operation.parentId);
        entry["domain"] = JSONValue(operation.semanticDomain);
        entry["kind"] = JSONValue(operation.kind);
        entry["label"] = JSONValue(operation.label);
        entry["source_file"] = JSONValue(operation.sourceFile);
        entry["source_line"] =
            JSONValue(cast(long) operation.sourceLine);
        JSONValue[] dimensions;
        foreach (dimension; operation.dimensions) {
            dimensions ~= JSONValue(dimension);
        }
        entry["dimensions"] = JSONValue(dimensions);
        JSONValue[string] attributes;
        foreach (key, value; operation.attributes) {
            attributes[key] = JSONValue(value);
        }
        entry["attributes"] = JSONValue(attributes);
        semanticOperations ~= JSONValue(entry);
    }
    root["semantic_operations"] = JSONValue(semanticOperations);

    JSONValue[] variables;
    auto logicalVariables = compiled.model.variables;
    foreach (logicalIndex, variable; logicalVariables) {
        JSONValue[string] entry;
        entry["logical_index"] = JSONValue(cast(long) logicalIndex);
        entry["name"] = JSONValue(variable.name);
        entry["kind"] = JSONValue(variable.kind.to!string);
        entry["lower_bound"] = JSONValue(variable.lowerBound);
        entry["upper_bound"] = JSONValue(variable.upperBound);

        JSONValue[] states;
        foreach (state; variable.states) {
            states ~= JSONValue(state);
        }
        entry["states"] = JSONValue(states);

        JSONValue[] atoms;
        foreach (atom; compiled.atoms[logicalIndex]) {
            JSONValue[string] atomEntry;
            atomEntry["value"] = JSONValue(atom.value);
            atomEntry["literal_when_selected"] =
                JSONValue(cast(long) atom.literalWhenSelected);
            atoms ~= JSONValue(atomEntry);
        }
        entry["atoms"] = JSONValue(atoms);

        JSONValue[] orderLiterals;
        foreach (literal; compiled.integerOrderLiterals[logicalIndex]) {
            orderLiterals ~= JSONValue(cast(long) literal);
        }
        entry["integer_order_literals"] = JSONValue(orderLiterals);
        variables ~= JSONValue(entry);
    }
    root["variables"] = JSONValue(variables);

    JSONValue[] clauses;
    foreach (index, clause; compiled.clauses) {
        JSONValue[string] entry;
        entry["index"] = JSONValue(cast(long) index);
        entry["name"] = JSONValue(clause.constraintName);
        entry["semantic_operation_id"] =
            JSONValue(clause.semanticOperationId);
        entry["level"] = JSONValue(clause.level.to!string);
        entry["weight"] = JSONValue(clause.weight);
        entry["structural"] = JSONValue(clause.structural);
        entry["priority_level"] = JSONValue(cast(long) clause.priorityLevel);
        JSONValue[] literals;
        foreach (literal; clause.literals) {
            literals ~= JSONValue(cast(long) literal);
        }
        entry["literals"] = JSONValue(literals);
        JSONValue[] constraintNames;
        foreach (name; clause.constraintNames) {
            constraintNames ~= JSONValue(name);
        }
        entry["constraint_names"] = JSONValue(constraintNames);
        JSONValue[] operationIds;
        foreach (operationId; clause.semanticOperationIds) {
            operationIds ~= JSONValue(operationId);
        }
        entry["semantic_operation_ids"] = JSONValue(operationIds);
        clauses ~= JSONValue(entry);
    }
    root["clauses"] = JSONValue(clauses);

    JSONValue[] warnings;
    foreach (warning; compiled.warnings) {
        warnings ~= JSONValue(warning);
    }
    root["warnings"] = JSONValue(warnings);
    return JSONValue(root);
}

private bool hasSoftSemantics(CompiledModel compiled) {
    foreach (clause; compiled.clauses) {
        if (clause.level != ConstraintLevel.hard) return true;
    }
    return false;
}

private void requireHardOnly(CompiledModel compiled, string target) {
    if (hasSoftSemantics(compiled)) {
        throw new CapabilityException(
            target ~ " cannot preserve soft constraints; export WCNF instead"
        );
    }
}

private JSONValue cnfJson(CompiledModel compiled) {
    JSONValue[string] result;
    result["num_vars"] =
        JSONValue(cast(long) compiled.generatedVariableCount);
    JSONValue[] clauses;
    foreach (clause; compiled.clauses) {
        JSONValue[] literals;
        foreach (literal; clause.literals) {
            literals ~= JSONValue(cast(long) literal);
        }
        clauses ~= JSONValue(literals);
    }
    result["clauses"] = JSONValue(clauses);
    return JSONValue(result);
}

private string dimacsText(CompiledModel compiled) {
    auto output = appender!string();
    output.put("c name: ");
    output.put(compiled.model.name);
    output.put("\n");
    output.put("c generated by Navokoj\n");
    output.put("p cnf ");
    output.put(compiled.generatedVariableCount.to!string);
    output.put(" ");
    output.put(compiled.clauses.length.to!string);
    output.put("\n");
    foreach (clause; compiled.clauses) {
        foreach (literal; clause.literals) {
            output.put(literal.to!string);
            output.put(" ");
        }
        output.put("0\n");
    }
    return output.data;
}

private ulong exactPositiveWeight(double weight) {
    if (
        !weight.isFinite ||
        weight <= 0.0 ||
        floor(weight) != weight ||
        weight > cast(double) ulong.max
    ) {
        throw new CapabilityException(
            "WCNF requires positive integral weights after compilation"
        );
    }
    return cast(ulong) weight;
}

private string wcnfText(CompiledModel compiled) {
    ulong softTotal;
    foreach (clause; compiled.clauses) {
        if (clause.level == ConstraintLevel.hard) continue;
        const weight = exactPositiveWeight(clause.weight);
        if (ulong.max - softTotal < weight) {
            throw new CapabilityException("WCNF soft-weight sum overflow");
        }
        softTotal += weight;
    }
    if (softTotal == ulong.max) {
        throw new CapabilityException("WCNF hard-weight overflow");
    }
    const top = softTotal + 1;

    auto output = appender!string();
    output.put("c name: ");
    output.put(compiled.model.name);
    output.put("\n");
    output.put("c generated by Navokoj; hard weight is ");
    output.put(top.to!string);
    output.put("\n");
    output.put("p wcnf ");
    output.put(compiled.generatedVariableCount.to!string);
    output.put(" ");
    output.put(compiled.clauses.length.to!string);
    output.put(" ");
    output.put(top.to!string);
    output.put("\n");

    foreach (clause; compiled.clauses) {
        const weight =
            clause.level == ConstraintLevel.hard
                ? top
                : exactPositiveWeight(clause.weight);
        output.put(weight.to!string);
        output.put(" ");
        foreach (literal; clause.literals) {
            output.put(literal.to!string);
            output.put(" ");
        }
        output.put("0\n");
    }
    return output.data;
}

private string opbText(CompiledModel compiled) {
    auto output = appender!string();
    output.put("* #variable= ");
    output.put(compiled.generatedVariableCount.to!string);
    output.put(" #constraint= ");
    output.put(compiled.clauses.length.to!string);
    output.put("\n");
    output.put("* name: ");
    output.put(compiled.model.name);
    output.put("\n");

    foreach (clause; compiled.clauses) {
        if (clause.literals.length == 0) {
            output.put("0 >= 1 ;\n");
            continue;
        }
        foreach (literal; clause.literals) {
            output.put("+1 ");
            if (literal < 0) output.put("~");
            const variable =
                literal < 0
                    ? -cast(long) literal
                    : cast(long) literal;
            output.put("x");
            output.put(variable.to!string);
            output.put(" ");
        }
        output.put(">= 1 ;\n");
    }
    return output.data;
}