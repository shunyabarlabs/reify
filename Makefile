LDC ?= ldc2
BUILD_DIR := build
REIFY_SOURCES := \
	source/reify/package.d \
	source/reify/errors.d \
	source/reify/model.d \
	source/reify/compiler.d \
	source/reify/formula.d \
	source/reify/dimacs.d \
	source/reify/opb.d \
	source/reify/result.d \
	source/reify/backend.d \
	source/reify/transport.d \
	source/reify/navokoj/client.d \
	source/reify/navokoj/backend.d \
	source/reify/navokoj/response_parser.d \
	source/reify/diagnostics.d \
	source/reify/router.d \
	source/reify/app.d \
	source/reify/document.d \
	source/reify/builders.d \
	source/reify/spacetime.d \
	source/reify/exports.d \
	source/reify/explain.d

.PHONY: all build test trust-test spacetime-test check interop clean

all: build

build:
	mkdir -p $(BUILD_DIR)
	$(LDC) source/app.d $(REIFY_SOURCES) -Isource -of=$(BUILD_DIR)/reify

test:
	mkdir -p $(BUILD_DIR)
	$(LDC) tests/test_runner.d $(REIFY_SOURCES) -Isource -of=$(BUILD_DIR)/reify-tests
	$(BUILD_DIR)/reify-tests
	$(LDC) tests/formula_mapping_tests.d $(REIFY_SOURCES) -Isource -of=$(BUILD_DIR)/formula-mapping-tests
	$(BUILD_DIR)/formula-mapping-tests
	$(LDC) -wi -Isource -i -unittest -main source/reify/opb.d -of=$(BUILD_DIR)/opb-tests
	$(BUILD_DIR)/opb-tests

trust-test:
	mkdir -p $(BUILD_DIR)
	$(LDC) tests/trust_primitive_tests.d $(REIFY_SOURCES) -Isource -of=$(BUILD_DIR)/trust-tests
	$(BUILD_DIR)/trust-tests

spacetime-test:
	mkdir -p $(BUILD_DIR)
	$(LDC) tests/spacetime_tests.d $(REIFY_SOURCES) -Isource -of=$(BUILD_DIR)/spacetime-tests
	$(BUILD_DIR)/spacetime-tests

check: build test
	$(LDC) examples/crop_app.d $(REIFY_SOURCES) -Isource -of=$(BUILD_DIR)/crop-app
	$(LDC) examples/vehicle_routing.d $(REIFY_SOURCES) -Isource -of=$(BUILD_DIR)/vehicle-routing-app
	$(BUILD_DIR)/reify validate --input examples/crop-allocation.json
	$(BUILD_DIR)/reify compile --input examples/exam-allocation.json
	$(BUILD_DIR)/reify compile --input examples/pigeonhole-3-2.cnf
	$(BUILD_DIR)/reify compile --input examples/pigeonhole-3-2.opb
	$(BUILD_DIR)/reify validate --format dimacs < examples/pigeonhole-3-2.cnf
	$(BUILD_DIR)/reify validate --format opb < examples/pigeonhole-3-2.opb
	$(BUILD_DIR)/crop-app validate --input examples/crop-allocation.json
	$(BUILD_DIR)/vehicle-routing-app validate --input examples/crop-allocation.json

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

clean:
	rm -rf $(BUILD_DIR)
