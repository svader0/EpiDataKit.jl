// This Go script is a quick little sanity check that Arrow files produced
// by the package are portable beyond Julia.
//
//	go -C test/portability_check run . "$PWD/file.arrow"
//
// .
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/apache/arrow-go/v18/arrow"
	"github.com/apache/arrow-go/v18/arrow/array"
	"github.com/apache/arrow-go/v18/arrow/ipc"
)

// extensionNameKey is the schema-level metadata Arrow uses to tag a logical type layered
// on top of a storage type.
const extensionNameKey = "ARROW:extension:name"

var plainIntColumns = []string{"geo_level", "missing_code"}

var expectedColumns = []string{
	"source", "signal", "geo_level", "geo_id", "period_start", "period_end",
	"value", "stderr", "sample_size", "issue", "lag", "missing_code",
}

// storageType looks through dictionary encoding to the type a consumer actually decodes.
// The enum columns are dictionary-encoded for size, so their reported type is
// dictionary<values=int8>; what matters is that the values underneath are integers.
func storageType(dt arrow.DataType) arrow.DataType {
	if d, ok := dt.(*arrow.DictionaryType); ok {
		return d.ValueType
	}
	return dt
}

func extensionName(f arrow.Field) (string, bool) {
	if i := f.Metadata.FindKey(extensionNameKey); i >= 0 {
		return f.Metadata.Values()[i], true
	}
	return "", false
}

// stringAt reads element i of a string column, transparently handling the
// dictionary-encoded case.
func stringAt(col arrow.Array, i int) (string, bool) {
	if col.IsNull(i) {
		return "", false
	}
	switch a := col.(type) {
	case *array.String:
		return a.Value(i), true
	case *array.LargeString:
		return a.Value(i), true
	case *array.Dictionary:
		switch d := a.Dictionary().(type) {
		case *array.String:
			return d.Value(a.GetValueIndex(i)), true
		case *array.LargeString:
			return d.Value(a.GetValueIndex(i)), true
		}
	}
	return "", false
}

func run(path string) []string {
	var failures []string

	f, err := os.Open(path)
	if err != nil {
		msg := fmt.Sprintf("cannot open %s: %v", path, err)
		if !filepath.IsAbs(path) {
			// Under `go -C dir run .` the child process inherits `dir` as its working
			// directory, so a path relative to where you typed the command will not
			// resolve. Worth saying outright — the failure is otherwise baffling.
			msg += "\n    (relative paths resolve against this module's directory; pass an absolute path)"
		}
		return []string{msg}
	}
	defer f.Close()

	r, err := ipc.NewFileReader(f)
	if err != nil {
		return []string{fmt.Sprintf("not a readable Arrow IPC file: %v", err)}
	}
	defer r.Close()

	schema := r.Schema()

	present := make(map[string]bool, len(schema.Fields()))
	for _, fld := range schema.Fields() {
		present[fld.Name] = true
	}
	var missing []string
	for _, name := range expectedColumns {
		if !present[name] {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		failures = append(failures,
			fmt.Sprintf("missing columns: %s", strings.Join(missing, ", ")))
	}

	for _, name := range plainIntColumns {
		idx := schema.FieldIndices(name)
		if len(idx) == 0 {
			continue
		}
		fld := schema.Field(idx[0])
		if ext, ok := extensionName(fld); ok {
			failures = append(failures, fmt.Sprintf(
				"%s: carries extension metadata %q; a foreign reader would need EpiDataKit to interpret it",
				name, ext))
		}
		if st := storageType(fld.Type); !arrow.IsInteger(st.ID()) {
			failures = append(failures, fmt.Sprintf(
				"%s: storage type is %s, expected an integer type", name, st))
		}
	}

	// print schema for inspection
	var rows int64
	for _, fld := range schema.Fields() {
		note := ""
		if ext, ok := extensionName(fld); ok {
			note = "   [" + ext + "]"
		}
		fmt.Printf("  %-14s %-48s%s\n", fld.Name, fld.Type.String(), note)
	}

	// check that geo_id values are as expected
	geoIdx := schema.FieldIndices("geo_id")
	for i := 0; i < r.NumRecords(); i++ {
		rec, err := r.RecordBatch(i)
		if err != nil {
			failures = append(failures, fmt.Sprintf("reading record %d: %v", i, err))
			break
		}
		rows += rec.NumRows()
		if len(geoIdx) == 0 {
			continue
		}
		col := rec.Column(geoIdx[0])
		for j := 0; j < int(rec.NumRows()); j++ {
			gid, ok := stringAt(col, j)
			if !ok {
				continue
			}
			if isAllDigits(gid) && len(gid) != 1 && len(gid) != 2 && len(gid) != 5 {
				failures = append(failures,
					fmt.Sprintf("geo_id %q has a suspicious length", gid))
			}
		}
	}

	fmt.Printf("\n%s: %d rows, %d columns\n", path, rows, len(schema.Fields()))
	return failures
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: go run ./test/portability_check <file.arrow>")
		os.Exit(2)
	}

	failures := run(os.Args[1])
	if len(failures) > 0 {
		fmt.Println("\nFAIL")
		for _, f := range failures {
			fmt.Printf("  - %s\n", f)
		}
		os.Exit(1)
	}

	fmt.Println("\nOK: enum columns are plain integers with no Julia-specific metadata.")
	fmt.Println("    Symbol/Date columns carry JuliaLang.* annotations, which readers ignore,")
	fmt.Println("    falling back to the underlying utf8 and date32 types.")
}
