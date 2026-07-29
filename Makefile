LDC ?= ldc2
BUILD_DIR := build
LIBREIFY := $(BUILD_DIR)/libreify.a

# Reify is compiled once into a static archive. Every consumer (CLI, examples,
# test harnesses, the OPB unittest) links against it. Editing one example now
# relinks the example only — the ~15K-LoC source tree is not rebuilt.

.PHONY: all libreify build test trust-test spacetime-test check interop studio clean

all: build

libreify: $(LIBREIFY)

$(LIBREIFY):
	@mkdir -p $(BUILD_DIR)
	$(LDC) --lib -wi -Isource -i source/reify/package.d -od=$(BUILD_DIR) -of=$(LIBREIFY)

# Linker flags must be wrapped in -L so ldc2 forwards them: -L-L<dir> adds a
# library search path, -L-l<name> links against lib<name>.a.
LDFLAGS := -L-L$(BUILD_DIR) -L-lreify

build: libreify
	$(LDC) source/app.d -Isource $(LDFLAGS) -of=$(BUILD_DIR)/reify

test: libreify
	$(LDC) tests/test_runner.d -Isource $(LDFLAGS) -of=$(BUILD_DIR)/reify-tests
	$(BUILD_DIR)/reify-tests
	$(LDC) tests/formula_mapping_tests.d -Isource $(LDFLAGS) -of=$(BUILD_DIR)/formula-mapping-tests
	$(BUILD_DIR)/formula-mapping-tests

trust-test: libreify
	$(LDC) tests/trust_primitive_tests.d -Isource $(LDFLAGS) -of=$(BUILD_DIR)/trust-tests
	$(BUILD_DIR)/trust-tests

spacetime-test: libreify
	$(LDC) tests/spacetime_tests.d -Isource $(LDFLAGS) -of=$(BUILD_DIR)/spacetime-tests
	$(BUILD_DIR)/spacetime-tests

check: build test trust-test spacetime-test
	$(LDC) examples/d/crop_app.d -Isource $(LDFLAGS) -of=$(BUILD_DIR)/crop-app
	$(LDC) examples/d/vehicle_routing.d -Isource $(LDFLAGS) -of=$(BUILD_DIR)/vehicle-routing-app
	$(LDC) examples/d/nurse_wcnf_scheduling.d -Isource $(LDFLAGS) -of=$(BUILD_DIR)/nurse-wcnf-scheduling-app
	$(LDC) -Isource -i -unittest -main $(LDFLAGS) source/reify/opb.d -od=$(BUILD_DIR) -of=$(BUILD_DIR)/opb-tests
	$(BUILD_DIR)/opb-tests
	$(BUILD_DIR)/reify validate --input examples/json/crop-allocation.json
	$(BUILD_DIR)/reify compile --input examples/json/exam-allocation.json
	$(BUILD_DIR)/reify compile --input examples/json/pigeonhole-3-2.cnf
	$(BUILD_DIR)/reify compile --input examples/json/pigeonhole-3-2.opb
	$(BUILD_DIR)/reify validate --format dimacs < examples/json/pigeonhole-3-2.cnf
	$(BUILD_DIR)/reify validate --format opb < examples/json/pigeonhole-3-2.opb
	$(BUILD_DIR)/crop-app validate --input examples/json/crop-allocation.json
	$(BUILD_DIR)/vehicle-routing-app validate --input examples/json/crop-allocation.json
	$(BUILD_DIR)/nurse-wcnf-scheduling-app validate --input examples/json/nurse-scheduling.json

interop: build
	command -v cnfgen
	command -v pbgen
	cnfgen true | $(BUILD_DIR)/reify validate --format dimacs >/dev/null
	cnfgen false | $(BUILD_DIR)/reify validate --format dimacs >/dev/null
	cnfgen bphp 5 4 | $(BUILD_DIR)/reify validate --format dimacs >/dev/null
	cnfgen op 5 -T shuffle | $(BUILD_DIR)/reify validate --format dimacs >/dev/null
	cnfgen peb pyramid 2 -T xor 2 | $(BUILD_DIR)/reify validate --format dimacs >/dev/null
	cnfgen cpls 3 4 8 | $(BUILD_DIR)/reify validate --format dimacs >/dev/null
	pbgen php 4 3 | $(BUILD_DIR)/reify validate --format opb >/dev/null
	pbgen bphp 4 3 | $(BUILD_DIR)/reify validate --format opb >/dev/null

studio:
	@echo "Launching Reify Compiler Studio on http://localhost:8080 ..."
	python3 -m http.server 8080 --directory studio

clean:
	rm -rf $(BUILD_DIR)
