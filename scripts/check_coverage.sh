#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( dirname "$SCRIPT_DIR" )"

cd "$PROJECT_ROOT" || exit 1

# Run tests and generate coverage
echo "Running tests with coverage in $PROJECT_ROOT..."
flutter test --coverage

# Check if coverage was generated
if [ -f "coverage/lcov.info" ]; then
    echo "Parsing coverage report..."
    python3 scripts/parse_coverage.py
else
    echo "Error: coverage/lcov.info not found. Did tests run successfully?"
    exit 1
fi
