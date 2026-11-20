# V5 cast-API, served from delphi.cmu.edu. See test/fixtures/README.md for the recorded
# contract.

const V5_SNAPSHOT_ENDPOINT = "v5/snapshot/"
const V5_ARCHIVE_ENDPOINT = "v5/archive/"
const V5_METADATA_ENDPOINT = "v5/metadata/"
const V5_REFERENCE_TIMES_ENDPOINT = "v5/metadata/reference_times/"

"""
Start of the CSV header every V5 data response shares; `age_group` and the CI columns
may follow, and `value` is last.
"""
const V5_CSV_HEADER_PREFIX = "signal,report_time,geo_type,geo_value,fill_method,reference_time"

csv_header(::DelphiV5) = V5_CSV_HEADER_PREFIX
