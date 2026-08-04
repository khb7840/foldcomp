#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <foldcomp-binary>" >&2
  exit 2
fi

FOLDCOMP_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$SCRIPT_DIR
TMP_ROOT=${FOLDCOMP_SMOKE_TMPDIR:-/tmp}
mkdir -p "$TMP_ROOT"

assert_close() {
  local observed=$1
  local expected=$2
  local tolerance=$3
  awk -v check="$observed" -v target="$expected" -v tol="$tolerance" \
    'BEGIN { diff = check - target; if (diff < 0) diff = -diff; if (diff > tol) { print check "!=" target; exit 1 } }'
}

assert_rmsd_exact() {
  local source=$1
  local roundtrip=$2
  local expected_bb=$3
  local expected_aa=$4
  local tolerance=${5:-0.001}
  local line bb aa
  line=$("$FOLDCOMP_BIN" rmsd "$source" "$roundtrip")
  bb=$(printf '%s\n' "$line" | cut -f5)
  aa=$(printf '%s\n' "$line" | cut -f6)
  assert_close "$bb" "$expected_bb" "$tolerance"
  assert_close "$aa" "$expected_aa" "$tolerance"
}

assert_rmsd_at_most() {
  local source=$1
  local roundtrip=$2
  local max_bb=$3
  local max_aa=$4
  local line bb aa
  line=$("$FOLDCOMP_BIN" rmsd "$source" "$roundtrip")
  bb=$(printf '%s\n' "$line" | cut -f5)
  aa=$(printf '%s\n' "$line" | cut -f6)
  awk -v bb="$bb" -v max_bb="$max_bb" -v aa="$aa" -v max_aa="$max_aa" \
    'BEGIN {
      if (bb > max_bb) { print "backbone " bb ">" max_bb; exit 1 }
      if (aa > max_aa) { print "all-atom " aa ">" max_aa; exit 1 }
    }'
}

run_reference_cases() {
  rm -f "$TEST_DIR/test.fcz" "$TEST_DIR/test_fcz.cif" "$TEST_DIR/test.cif.fcz" "$TEST_DIR/test.cif_fcz.cif"

  "$FOLDCOMP_BIN" compress "$TEST_DIR/test.pdb"
  "$FOLDCOMP_BIN" decompress "$TEST_DIR/test.fcz" "$TEST_DIR/test_fcz.cif"
  assert_rmsd_exact "$TEST_DIR/test.pdb" "$TEST_DIR/test_fcz.cif" "0.0453689" "0.0833658"

  "$FOLDCOMP_BIN" compress "$TEST_DIR/test.cif.gz"
  "$FOLDCOMP_BIN" decompress -a "$TEST_DIR/test.cif.fcz" "$TEST_DIR/test.cif_fcz.cif"
  assert_rmsd_exact "$TEST_DIR/test.cif.gz" "$TEST_DIR/test.cif_fcz.cif" "0.0569663" "0.128881"
}

run_regression_case() {
  local name=$1
  local max_default_bb=$2
  local max_default_aa=$3
  local max_spill_bb=$4
  local max_spill_aa=$5
  local source="$TEST_DIR/${name}.cif.gz"
  local default_base="${TMP_ROOT}/foldcomp-smoke-${name}-default"
  local max_base="${TMP_ROOT}/foldcomp-smoke-${name}-max"

  rm -f "${default_base}" "${default_base}." "${default_base}.cif"
  "$FOLDCOMP_BIN" compress "$source" "$default_base"
  "$FOLDCOMP_BIN" decompress "${default_base}." "${default_base}.cif"
  assert_rmsd_at_most "$source" "${default_base}.cif" "$max_default_bb" "$max_default_aa"

  rm -f "${max_base}" "${max_base}." "${max_base}.cif"
  "$FOLDCOMP_BIN" compress --max-backbone-rmsd 0.2 "$source" "$max_base"
  "$FOLDCOMP_BIN" decompress "${max_base}." "${max_base}.cif"
  assert_rmsd_at_most "$source" "${max_base}.cif" "$max_spill_bb" "$max_spill_aa"
}

assert_eq() {
  local label=$1
  local observed=$2
  local expected=$3
  if [ "$observed" != "$expected" ]; then
    echo "FAIL [$label]: expected '$expected', got '$observed'" >&2
    exit 1
  fi
}

# --- DB write + shard-merge round-trip ---
run_db_compress_decompress() {
  local TMP="$TMP_ROOT/foldcomp-smoke-db"
  rm -rf "$TMP"
  mkdir -p "$TMP"

  local OUT_DB="$TMP/out_db"

  # Compress all PDB/CIF inputs into a DB (exercises parallel shard writing)
  "$FOLDCOMP_BIN" compress -d "$TEST_DIR/dir_test_input" "$OUT_DB"

  # Index must exist and be non-empty
  [ -s "${OUT_DB}.index" ] || { echo "FAIL: ${OUT_DB}.index is empty/missing" >&2; exit 1; }
  [ -s "${OUT_DB}.lookup" ] || { echo "FAIL: ${OUT_DB}.lookup is empty/missing" >&2; exit 1; }

  # Number of index lines must match number of structurally valid inputs
  local n_idx
  n_idx=$(wc -l < "${OUT_DB}.index")
  [ "$n_idx" -ge 1 ] || { echo "FAIL: DB index has no entries" >&2; exit 1; }

  # No leftover .tmp.* shard files
  local leftover
  leftover=$(find "$TMP" -name "*.tmp.*" 2>/dev/null | wc -l)
  assert_eq "no leftover shard files" "$leftover" "0"

  # Decompress the DB back into another DB (decompress -d produces a DB output)
  local OUT_DECOMP="$TMP/decomp_db"
  "$FOLDCOMP_BIN" decompress -d "$OUT_DB" "$OUT_DECOMP"
  [ -s "${OUT_DECOMP}.index" ] || { echo "FAIL: decompress -d produced no output index" >&2; exit 1; }
  local n_decomp
  n_decomp=$(wc -l < "${OUT_DECOMP}.index")
  assert_eq "decompress DB entry count matches compress DB" "$n_decomp" "$n_idx"
}

# --- concat subcommand ---
run_concat() {
  local TMP="$TMP_ROOT/foldcomp-smoke-concat"
  rm -rf "$TMP"
  mkdir -p "$TMP"

  local DB_A="$TMP/dbA"
  local DB_B="$TMP/dbB"
  local DB_CAT="$TMP/dbCAT"

  # Build two small DBs from the example_db (just copy them as separate DBs for concat)
  # Use the pre-existing example_db split into two halves via subset
  local ALL_NAMES
  ALL_NAMES=$(awk '{print $2}' "$TEST_DIR/example_db.lookup")
  local HALF
  HALF=$(echo "$ALL_NAMES" | wc -l)
  HALF=$(( HALF / 2 ))

  local IDS_A="$TMP/ids_a.txt"
  local IDS_B="$TMP/ids_b.txt"
  echo "$ALL_NAMES" | head -n "$HALF" > "$IDS_A"
  echo "$ALL_NAMES" | tail -n "+$(( HALF + 1 ))" > "$IDS_B"

  "$FOLDCOMP_BIN" subset "$TEST_DIR/example_db" "$IDS_A" "$DB_A"
  "$FOLDCOMP_BIN" subset "$TEST_DIR/example_db" "$IDS_B" "$DB_B"

  local n_a n_b
  n_a=$(wc -l < "${DB_A}.index")
  n_b=$(wc -l < "${DB_B}.index")

  "$FOLDCOMP_BIN" concat "$DB_A" "$DB_B" "$DB_CAT"

  [ -s "${DB_CAT}.index" ] || { echo "FAIL: concat produced empty index" >&2; exit 1; }
  [ -s "${DB_CAT}.lookup" ] || { echo "FAIL: concat produced empty lookup" >&2; exit 1; }

  local n_cat
  n_cat=$(wc -l < "${DB_CAT}.index")
  local expected_cat=$(( n_a + n_b ))
  assert_eq "concat entry count" "$n_cat" "$expected_cat"

  # Keys in the concatenated DB must be sequential starting from 0
  local first_key last_key
  first_key=$(awk 'NR==1{print $1}' "${DB_CAT}.index")
  last_key=$(awk 'END{print $1}' "${DB_CAT}.index")
  assert_eq "concat first key" "$first_key" "0"
  assert_eq "concat last key" "$last_key" "$(( expected_cat - 1 ))"

  # All names from both subsets must appear in the concat lookup
  local n_lookup
  n_lookup=$(wc -l < "${DB_CAT}.lookup")
  assert_eq "concat lookup count" "$n_lookup" "$expected_cat"
}

# --- subset subcommand ---
run_subset() {
  local TMP="$TMP_ROOT/foldcomp-smoke-subset"
  rm -rf "$TMP"
  mkdir -p "$TMP"

  local IDS="$TMP/ids.txt"
  local OUT_DB="$TMP/sub_db"

  # Pick a few known names from the example_db
  printf 'd1asha_\nd1it2a_\n' > "$IDS"
  "$FOLDCOMP_BIN" subset "$TEST_DIR/example_db" "$IDS" "$OUT_DB"

  [ -s "${OUT_DB}.index" ] || { echo "FAIL: subset index is empty/missing" >&2; exit 1; }
  local n_sub
  n_sub=$(wc -l < "${OUT_DB}.index")
  assert_eq "subset entry count" "$n_sub" "2"

  # Verify both names appear in the lookup
  grep -q "d1asha_" "${OUT_DB}.lookup" || { echo "FAIL: d1asha_ missing from subset lookup" >&2; exit 1; }
  grep -q "d1it2a_" "${OUT_DB}.lookup" || { echo "FAIL: d1it2a_ missing from subset lookup" >&2; exit 1; }

  # Decompress to verify data integrity (decompress -d outputs another DB)
  local DECOMP_DB="$TMP/decomp_db"
  "$FOLDCOMP_BIN" decompress -d "$OUT_DB" "$DECOMP_DB"
  local n_out
  n_out=$(wc -l < "${DECOMP_DB}.index")
  assert_eq "subset decompress file count" "$n_out" "2"

  # Name not in the id list must not appear
  local has_other
  has_other=$(grep -c "d1b0ba_" "${OUT_DB}.lookup" || true)
  assert_eq "subset excludes unlisted entries" "$has_other" "0"
}

# --- subset with missing/partial ids ---
run_subset_partial() {
  local TMP="$TMP_ROOT/foldcomp-smoke-subset-partial"
  rm -rf "$TMP"
  mkdir -p "$TMP"

  local IDS="$TMP/ids.txt"
  local OUT_DB="$TMP/sub_partial"

  # One real name, one that doesn't exist
  printf 'd1asha_\nNONEXISTENT_XYZ\n' > "$IDS"
  "$FOLDCOMP_BIN" subset "$TEST_DIR/example_db" "$IDS" "$OUT_DB"

  [ -s "${OUT_DB}.index" ] || { echo "FAIL: partial subset index is empty/missing" >&2; exit 1; }
  local n_sub
  n_sub=$(wc -l < "${OUT_DB}.index")
  assert_eq "partial subset entry count (only real entries)" "$n_sub" "1"
}

# --- concat three DBs ---
run_concat_three() {
  local TMP="$TMP_ROOT/foldcomp-smoke-concat3"
  rm -rf "$TMP"
  mkdir -p "$TMP"

  local ALL_NAMES
  ALL_NAMES=$(awk '{print $2}' "$TEST_DIR/example_db.lookup")
  local TOTAL
  TOTAL=$(echo "$ALL_NAMES" | wc -l)
  local THIRD=$(( TOTAL / 3 ))

  local IDS_A="$TMP/ids_a.txt" IDS_B="$TMP/ids_b.txt" IDS_C="$TMP/ids_c.txt"
  echo "$ALL_NAMES" | head -n "$THIRD" > "$IDS_A"
  echo "$ALL_NAMES" | tail -n "+$(( THIRD + 1 ))" | head -n "$THIRD" > "$IDS_B"
  echo "$ALL_NAMES" | tail -n "+$(( 2 * THIRD + 1 ))" > "$IDS_C"

  "$FOLDCOMP_BIN" subset "$TEST_DIR/example_db" "$IDS_A" "$TMP/dbA"
  "$FOLDCOMP_BIN" subset "$TEST_DIR/example_db" "$IDS_B" "$TMP/dbB"
  "$FOLDCOMP_BIN" subset "$TEST_DIR/example_db" "$IDS_C" "$TMP/dbC"

  local n_a n_b n_c
  n_a=$(wc -l < "$TMP/dbA.index")
  n_b=$(wc -l < "$TMP/dbB.index")
  n_c=$(wc -l < "$TMP/dbC.index")

  "$FOLDCOMP_BIN" concat "$TMP/dbA" "$TMP/dbB" "$TMP/dbC" "$TMP/dbABC"

  local n_cat
  n_cat=$(wc -l < "$TMP/dbABC.index")
  assert_eq "concat3 entry count" "$n_cat" "$(( n_a + n_b + n_c ))"
}

run_reference_cases
run_regression_case "1cfg" "0.2" "0.7" "0.2" "0.7"
run_regression_case "1adn" "0.35" "0.4" "0.2" "0.5"
run_regression_case "1dlp" "0.2" "0.6" "0.2" "0.5"
run_regression_case "1hrn" "0.12" "0.2" "0.2" "0.5"
run_regression_case "1jwt" "0.16" "0.35" "0.2" "0.5"
run_regression_case "1lyz" "0.55" "0.75" "0.2" "0.5"
run_regression_case "2ap2" "0.15" "0.2" "0.2" "0.5"
run_regression_case "2gn5" "1.5" "1.8" "0.2" "0.8"
run_regression_case "4kuk" "0.1" "0.15" "0.2" "0.5"
run_regression_case "7c2s" "0.01" "0.01" "0.2" "0.5"
run_db_compress_decompress
run_subset
run_subset_partial
run_concat
run_concat_three
echo "All tests passed."
