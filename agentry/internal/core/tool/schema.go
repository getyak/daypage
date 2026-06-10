package tool

// Lightweight, dependency-free JSON Schema validation for tool-call arguments.
//
// The agent loop advertises each tool's Schema() to the model, but the model is
// free to return whatever it likes. Before a tool runs, the engine validates the
// model-supplied arguments against the tool's declared schema so a malformed call
// (missing a required field, a wrong-typed value, an out-of-range number, an
// unknown property when additionalProperties is false, …) is turned into a clear,
// structured, model-visible error *at one chokepoint* — instead of every tool
// re-implementing partial, inconsistent checks, or advertised constraints like
// minimum/maximum being silently ignored.
//
// Design constraints that make this safe to apply to EVERY tool, including
// MCP-proxied tools whose schemas are authored by third parties:
//
//   - Permissive by default. Only the well-understood Draft-07 subset actually
//     used by agentry's tools is enforced: object "type", "properties",
//     "required", "additionalProperties:false", scalar "type", "enum",
//     numeric "minimum"/"maximum"/"exclusiveMinimum"/"exclusiveMaximum",
//     string "minLength"/"maxLength", and array "minItems"/"maxItems"/"items".
//     Any keyword it does not understand ($ref, oneOf/anyOf/allOf, patterns,
//     formats, dependencies, conditional schemas, …) is treated as "no opinion"
//     and never causes a rejection. This guarantees we never reject a call that a
//     real validator would accept just because we don't model some keyword.
//
//   - A schema that is absent, empty, `true`, or not a JSON object imposes no
//     constraints (everything validates). A schema we cannot parse is ignored
//     rather than failing the call — validation must never be *stricter* than the
//     author intended due to our own limitations.
//
//   - Numbers are compared as float64 (JSON's number model); integer "type" also
//     accepts an integral float (e.g. 3 or 3.0) since JSON has no integer type on
//     the wire.
//
// The result is a slice of human-readable, field-anchored problems (empty when
// the arguments satisfy the understood constraints), which the engine formats
// into a tool_result the model can read and self-correct from.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
)

// FormatValidationProblems renders the problems from ValidateArgs into a single,
// model-legible string for a tool_result. The leading line names the failure and
// the tool so the model knows the call was rejected before any side effect ran;
// each problem is its own bullet so multi-field failures are surfaced together
// and can be fixed in one corrected call. Returns "" for no problems.
func FormatValidationProblems(toolName string, problems []string) string {
	if len(problems) == 0 {
		return ""
	}
	var b strings.Builder
	fmt.Fprintf(&b, "tool %q received invalid arguments (the call was not executed); fix and retry:", toolName)
	for _, p := range problems {
		fmt.Fprintf(&b, "\n  - %s", p)
	}
	return b.String()
}

// ValidateArgs checks raw JSON arguments against a JSON Schema (the kind a Tool
// returns from Schema()) and reports any violations of the understood subset.
//
// It returns nil when the arguments satisfy every constraint it understands —
// which includes the cases where the schema imposes nothing (absent/empty/`true`/
// unparsable) or the arguments are empty and nothing is required. A non-nil,
// non-empty slice lists each problem in a stable order suitable for showing to a
// model. ValidateArgs never panics and never returns an error value: a problem it
// cannot reason about is simply not reported.
func ValidateArgs(schema, args json.RawMessage) []string {
	sc, ok := parseSchemaObject(schema)
	if !ok {
		// No schema, a boolean/`true` schema, or something we can't parse: impose
		// nothing. (A `false` schema would forbid everything, but tools never
		// advertise that; treating it as permissive is the safe direction.)
		return nil
	}

	// Decode the arguments. Empty/blank args are treated as an empty object so a
	// no-arg call validates against a schema whose fields are all optional.
	var val any
	trimmed := bytes.TrimSpace(args)
	if len(trimmed) == 0 {
		val = map[string]any{}
	} else {
		dec := json.NewDecoder(bytes.NewReader(trimmed))
		dec.UseNumber() // keep numeric precision; we convert per-constraint
		if err := dec.Decode(&val); err != nil {
			// The arguments are not even valid JSON. That is a genuine, reportable
			// problem regardless of schema (the model emitted a broken tool call).
			return []string{fmt.Sprintf("arguments are not valid JSON: %v", err)}
		}
	}

	var problems []string
	validateValue(sc, val, "", &problems)
	return problems
}

// schemaObject is a lenient view of a JSON Schema node. Unknown keywords are left
// in Raw so we can ignore them; the typed fields capture only the subset we
// enforce. All numeric bounds are pointers so "absent" is distinguishable from a
// legitimate zero bound.
type schemaObject struct {
	Type                 []string                   // normalized: 0+ accepted types
	Properties           map[string]json.RawMessage // sub-schemas, validated lazily
	Required             []string
	AdditionalProperties *bool // explicit false forbids unknown props
	Enum                 []any
	Minimum              *float64
	Maximum              *float64
	ExclusiveMinimum     *float64
	ExclusiveMaximum     *float64
	MinLength            *float64
	MaxLength            *float64
	MinItems             *float64
	MaxItems             *float64
	Items                json.RawMessage // sub-schema for array elements
}

// parseSchemaObject decodes a schema node into the lenient view. It returns
// ok=false when the schema imposes nothing we can act on (absent, empty, a
// boolean, or unparsable), signaling the caller to skip validation entirely.
func parseSchemaObject(raw json.RawMessage) (schemaObject, bool) {
	b := bytes.TrimSpace(raw)
	if len(b) == 0 {
		return schemaObject{}, false
	}
	// A boolean schema (`true`/`false`) is valid JSON Schema but carries no
	// property/type structure; treat as "no constraints".
	if string(b) == "true" || string(b) == "false" || string(b) == "null" {
		return schemaObject{}, false
	}

	var rawObj map[string]json.RawMessage
	if err := json.Unmarshal(b, &rawObj); err != nil {
		return schemaObject{}, false // not an object schema we can read
	}

	var sc schemaObject

	// "type" may be a single string or an array of strings.
	if t, ok := rawObj["type"]; ok {
		sc.Type = decodeStringOrArray(t)
	}
	if p, ok := rawObj["properties"]; ok {
		_ = json.Unmarshal(p, &sc.Properties)
	}
	if r, ok := rawObj["required"]; ok {
		_ = json.Unmarshal(r, &sc.Required)
	}
	if ap, ok := rawObj["additionalProperties"]; ok {
		// Only the boolean form is meaningful to us; a sub-schema form is ignored
		// (treated as "additional allowed") to stay permissive.
		var b bool
		if err := json.Unmarshal(ap, &b); err == nil {
			sc.AdditionalProperties = &b
		}
	}
	if e, ok := rawObj["enum"]; ok {
		_ = json.Unmarshal(e, &sc.Enum)
	}
	sc.Minimum = decodeNumber(rawObj["minimum"])
	sc.Maximum = decodeNumber(rawObj["maximum"])
	sc.ExclusiveMinimum = decodeNumber(rawObj["exclusiveMinimum"])
	sc.ExclusiveMaximum = decodeNumber(rawObj["exclusiveMaximum"])
	sc.MinLength = decodeNumber(rawObj["minLength"])
	sc.MaxLength = decodeNumber(rawObj["maxLength"])
	sc.MinItems = decodeNumber(rawObj["minItems"])
	sc.MaxItems = decodeNumber(rawObj["maxItems"])
	if it, ok := rawObj["items"]; ok {
		sc.Items = it
	}
	return sc, true
}

// validateValue checks a decoded value against a schema node, appending any
// problems. path is a dotted/bracketed locator (e.g. "user.tags[0]") used in
// messages; empty path means the root.
func validateValue(sc schemaObject, val any, path string, problems *[]string) {
	// type
	if len(sc.Type) > 0 && !typeMatchesAny(sc.Type, val) {
		*problems = append(*problems, fmt.Sprintf("%s: expected type %s, got %s",
			loc(path), strings.Join(sc.Type, "|"), jsonTypeName(val)))
		// A wrong type makes deeper checks meaningless; stop descending here.
		return
	}

	// enum (applies to any type)
	if len(sc.Enum) > 0 && !enumContains(sc.Enum, val) {
		*problems = append(*problems, fmt.Sprintf("%s: value %s is not one of the allowed values %s",
			loc(path), compact(val), compact(sc.Enum)))
	}

	switch v := val.(type) {
	case map[string]any:
		validateObject(sc, v, path, problems)
	case []any:
		validateArray(sc, v, path, problems)
	case json.Number:
		validateNumber(sc, v, path, problems)
	case string:
		validateString(sc, v, path, problems)
	}
}

// validateObject enforces required, additionalProperties:false, and recurses into
// declared properties.
func validateObject(sc schemaObject, obj map[string]any, path string, problems *[]string) {
	// required
	for _, req := range sc.Required {
		if _, present := obj[req]; !present {
			*problems = append(*problems, fmt.Sprintf("%s: missing required property %q", loc(path), req))
		}
	}

	// additionalProperties:false → reject unknown keys (only when properties are
	// declared; with no declared properties we can't know the intent, so allow).
	if sc.AdditionalProperties != nil && !*sc.AdditionalProperties && sc.Properties != nil {
		var unknown []string
		for k := range obj {
			if _, declared := sc.Properties[k]; !declared {
				unknown = append(unknown, k)
			}
		}
		sort.Strings(unknown)
		for _, k := range unknown {
			*problems = append(*problems, fmt.Sprintf("%s: unknown property %q is not allowed", loc(path), k))
		}
	}

	// Recurse into declared properties that are present.
	for name, subRaw := range sc.Properties {
		cv, present := obj[name]
		if !present {
			continue
		}
		sub, ok := parseSchemaObject(subRaw)
		if !ok {
			continue // sub-schema imposes nothing we understand
		}
		validateValue(sub, cv, childPath(path, name), problems)
	}
}

// validateArray enforces minItems/maxItems and recurses into items.
func validateArray(sc schemaObject, arr []any, path string, problems *[]string) {
	n := float64(len(arr))
	if sc.MinItems != nil && n < *sc.MinItems {
		*problems = append(*problems, fmt.Sprintf("%s: array has %d items, fewer than the minimum %s",
			loc(path), len(arr), num(*sc.MinItems)))
	}
	if sc.MaxItems != nil && n > *sc.MaxItems {
		*problems = append(*problems, fmt.Sprintf("%s: array has %d items, more than the maximum %s",
			loc(path), len(arr), num(*sc.MaxItems)))
	}
	if len(sc.Items) > 0 {
		if sub, ok := parseSchemaObject(sc.Items); ok {
			for i, el := range arr {
				validateValue(sub, el, fmt.Sprintf("%s[%d]", path, i), problems)
			}
		}
	}
}

// validateNumber enforces minimum/maximum (inclusive and exclusive forms).
func validateNumber(sc schemaObject, jn json.Number, path string, problems *[]string) {
	f, err := jn.Float64()
	if err != nil {
		return // unrepresentable; don't invent a problem
	}
	if sc.Minimum != nil && f < *sc.Minimum {
		*problems = append(*problems, fmt.Sprintf("%s: %s is less than the minimum %s",
			loc(path), jn.String(), num(*sc.Minimum)))
	}
	if sc.Maximum != nil && f > *sc.Maximum {
		*problems = append(*problems, fmt.Sprintf("%s: %s is greater than the maximum %s",
			loc(path), jn.String(), num(*sc.Maximum)))
	}
	if sc.ExclusiveMinimum != nil && f <= *sc.ExclusiveMinimum {
		*problems = append(*problems, fmt.Sprintf("%s: %s must be greater than %s",
			loc(path), jn.String(), num(*sc.ExclusiveMinimum)))
	}
	if sc.ExclusiveMaximum != nil && f >= *sc.ExclusiveMaximum {
		*problems = append(*problems, fmt.Sprintf("%s: %s must be less than %s",
			loc(path), jn.String(), num(*sc.ExclusiveMaximum)))
	}
}

// validateString enforces minLength/maxLength (counted in Unicode code points,
// matching JSON Schema's definition of string length).
func validateString(sc schemaObject, s string, path string, problems *[]string) {
	n := float64(len([]rune(s)))
	if sc.MinLength != nil && n < *sc.MinLength {
		*problems = append(*problems, fmt.Sprintf("%s: string length %d is less than the minimum %s",
			loc(path), len([]rune(s)), num(*sc.MinLength)))
	}
	if sc.MaxLength != nil && n > *sc.MaxLength {
		*problems = append(*problems, fmt.Sprintf("%s: string length %d is greater than the maximum %s",
			loc(path), len([]rune(s)), num(*sc.MaxLength)))
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// typeMatchesAny reports whether val satisfies at least one of the JSON Schema
// type names. An empty list means "no type constraint" (handled by the caller).
func typeMatchesAny(types []string, val any) bool {
	for _, t := range types {
		if typeMatches(t, val) {
			return true
		}
	}
	return false
}

// typeMatches reports whether val matches a single JSON Schema type name. JSON
// has no integer wire type, so "integer" accepts an integral number; "number"
// accepts any number. Unknown type names are treated as a match (permissive: we
// won't reject on a type keyword we don't model).
func typeMatches(t string, val any) bool {
	switch t {
	case "object":
		_, ok := val.(map[string]any)
		return ok
	case "array":
		_, ok := val.([]any)
		return ok
	case "string":
		_, ok := val.(string)
		return ok
	case "boolean":
		_, ok := val.(bool)
		return ok
	case "null":
		return val == nil
	case "number":
		_, ok := val.(json.Number)
		return ok
	case "integer":
		jn, ok := val.(json.Number)
		if !ok {
			return false
		}
		f, err := jn.Float64()
		if err != nil {
			return false
		}
		return f == math.Trunc(f) && !math.IsInf(f, 0)
	default:
		return true // unknown type keyword: don't reject on it
	}
}

// jsonTypeName names the JSON type of a decoded value for error messages.
func jsonTypeName(val any) string {
	switch val.(type) {
	case map[string]any:
		return "object"
	case []any:
		return "array"
	case string:
		return "string"
	case bool:
		return "boolean"
	case json.Number:
		return "number"
	case nil:
		return "null"
	default:
		return "value"
	}
}

// enumContains reports whether val deep-equals one of the enum members. Both
// sides are normalized through JSON so a json.Number compares equal to a numeric
// enum literal decoded by the standard library.
func enumContains(enum []any, val any) bool {
	target := compact(val)
	for _, e := range enum {
		if compact(e) == target {
			return true
		}
	}
	return false
}

// decodeStringOrArray reads a JSON value that may be a single string or an array
// of strings into a string slice. Anything else yields an empty slice (no type
// constraint enforced).
func decodeStringOrArray(raw json.RawMessage) []string {
	var single string
	if err := json.Unmarshal(raw, &single); err == nil {
		if single == "" {
			return nil
		}
		return []string{single}
	}
	var many []string
	if err := json.Unmarshal(raw, &many); err == nil {
		return many
	}
	return nil
}

// decodeNumber reads a JSON number constraint into a *float64, returning nil when
// the keyword is absent or not a number.
func decodeNumber(raw json.RawMessage) *float64 {
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil
	}
	var f float64
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil
	}
	return &f
}

// compact renders a value as its compact JSON form for stable comparisons and
// messages. Failures fall back to fmt so we never panic on exotic values.
func compact(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	return string(b)
}

// num formats a float bound without a trailing ".0" for whole numbers, so a
// "maximum": 120 reads as "120" rather than "120.000000" in messages.
func num(f float64) string {
	if f == math.Trunc(f) && !math.IsInf(f, 0) && math.Abs(f) < 1e15 {
		return fmt.Sprintf("%d", int64(f))
	}
	return fmt.Sprintf("%g", f)
}

// loc renders a path for messages, naming the document root when empty.
func loc(path string) string {
	if path == "" {
		return "arguments"
	}
	return path
}

// childPath joins an object property onto a parent path.
func childPath(parent, name string) string {
	if parent == "" {
		return name
	}
	return parent + "." + name
}
