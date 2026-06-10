package tool

import (
	"encoding/json"
	"strings"
	"testing"
)

// hasProblemContaining reports whether any problem string contains sub.
func hasProblemContaining(problems []string, sub string) bool {
	for _, p := range problems {
		if strings.Contains(p, sub) {
			return true
		}
	}
	return false
}

func TestValidateArgs_NoSchemaImposesNothing(t *testing.T) {
	// Absent, empty, boolean, and unparsable schemas all impose no constraints.
	for _, sc := range []string{``, `   `, `true`, `false`, `null`, `not json`, `[1,2,3]`} {
		if p := ValidateArgs(json.RawMessage(sc), json.RawMessage(`{"anything":1}`)); len(p) != 0 {
			t.Errorf("schema %q: expected no problems, got %v", sc, p)
		}
	}
}

func TestValidateArgs_EmptyArgsAllOptional(t *testing.T) {
	schema := json.RawMessage(`{"type":"object","properties":{"x":{"type":"string"}}}`)
	for _, args := range []string{``, `  `, `{}`} {
		if p := ValidateArgs(schema, json.RawMessage(args)); len(p) != 0 {
			t.Errorf("args %q: expected no problems, got %v", args, p)
		}
	}
}

func TestValidateArgs_InvalidJSONArgs(t *testing.T) {
	schema := json.RawMessage(`{"type":"object"}`)
	p := ValidateArgs(schema, json.RawMessage(`{"x": }`))
	if len(p) == 0 || !hasProblemContaining(p, "not valid JSON") {
		t.Fatalf("expected a JSON-parse problem, got %v", p)
	}
}

func TestValidateArgs_RequiredMissing(t *testing.T) {
	schema := json.RawMessage(`{
	  "type":"object",
	  "properties":{"path":{"type":"string"}},
	  "required":["path"]
	}`)
	p := ValidateArgs(schema, json.RawMessage(`{}`))
	if !hasProblemContaining(p, `missing required property "path"`) {
		t.Fatalf("expected missing-required problem, got %v", p)
	}
	// Present -> no problem.
	if p := ValidateArgs(schema, json.RawMessage(`{"path":"/tmp/x"}`)); len(p) != 0 {
		t.Fatalf("present required: expected no problems, got %v", p)
	}
}

func TestValidateArgs_TypeMismatch(t *testing.T) {
	schema := json.RawMessage(`{"type":"object","properties":{"path":{"type":"string"}}}`)
	p := ValidateArgs(schema, json.RawMessage(`{"path":123}`))
	if !hasProblemContaining(p, "expected type string, got number") {
		t.Fatalf("expected type-mismatch problem, got %v", p)
	}
}

func TestValidateArgs_RootTypeMismatch(t *testing.T) {
	schema := json.RawMessage(`{"type":"object"}`)
	// A top-level array is not an object.
	p := ValidateArgs(schema, json.RawMessage(`[1,2,3]`))
	if !hasProblemContaining(p, "expected type object, got array") {
		t.Fatalf("expected root type-mismatch, got %v", p)
	}
}

func TestValidateArgs_IntegerAcceptsIntegralFloatRejectsFraction(t *testing.T) {
	schema := json.RawMessage(`{"type":"object","properties":{"n":{"type":"integer"}}}`)
	// 3 and 3.0 are valid integers on the JSON wire.
	for _, ok := range []string{`{"n":3}`, `{"n":3.0}`, `{"n":-7}`} {
		if p := ValidateArgs(schema, json.RawMessage(ok)); len(p) != 0 {
			t.Errorf("args %s: expected no problems, got %v", ok, p)
		}
	}
	// 3.5 is not an integer.
	p := ValidateArgs(schema, json.RawMessage(`{"n":3.5}`))
	if !hasProblemContaining(p, "expected type integer") {
		t.Fatalf("expected integer type problem for 3.5, got %v", p)
	}
}

func TestValidateArgs_MinimumMaximum(t *testing.T) {
	// Mirrors web.fetch's max_bytes and shell.exec's timeout_sec constraints.
	schema := json.RawMessage(`{
	  "type":"object",
	  "properties":{"max_bytes":{"type":"integer","minimum":1,"maximum":8388608}}
	}`)
	// Above maximum.
	p := ValidateArgs(schema, json.RawMessage(`{"max_bytes":99999999}`))
	if !hasProblemContaining(p, "greater than the maximum 8388608") {
		t.Fatalf("expected maximum problem, got %v", p)
	}
	// Below minimum.
	p = ValidateArgs(schema, json.RawMessage(`{"max_bytes":0}`))
	if !hasProblemContaining(p, "less than the minimum 1") {
		t.Fatalf("expected minimum problem, got %v", p)
	}
	// In range -> clean.
	if p := ValidateArgs(schema, json.RawMessage(`{"max_bytes":1024}`)); len(p) != 0 {
		t.Fatalf("in-range: expected no problems, got %v", p)
	}
}

func TestValidateArgs_ExclusiveBounds(t *testing.T) {
	schema := json.RawMessage(`{"type":"object","properties":{"x":{"type":"number","exclusiveMinimum":0,"exclusiveMaximum":10}}}`)
	if p := ValidateArgs(schema, json.RawMessage(`{"x":0}`)); !hasProblemContaining(p, "must be greater than 0") {
		t.Fatalf("expected exclusiveMinimum problem, got %v", p)
	}
	if p := ValidateArgs(schema, json.RawMessage(`{"x":10}`)); !hasProblemContaining(p, "must be less than 10") {
		t.Fatalf("expected exclusiveMaximum problem, got %v", p)
	}
	if p := ValidateArgs(schema, json.RawMessage(`{"x":5}`)); len(p) != 0 {
		t.Fatalf("in-range exclusive: expected no problems, got %v", p)
	}
}

func TestValidateArgs_AdditionalPropertiesFalse(t *testing.T) {
	schema := json.RawMessage(`{
	  "type":"object",
	  "properties":{"url":{"type":"string"}},
	  "additionalProperties":false
	}`)
	p := ValidateArgs(schema, json.RawMessage(`{"url":"http://x","oops":1,"also":2}`))
	if !hasProblemContaining(p, `unknown property "oops"`) || !hasProblemContaining(p, `unknown property "also"`) {
		t.Fatalf("expected unknown-property problems for both, got %v", p)
	}
	// Only declared props -> clean.
	if p := ValidateArgs(schema, json.RawMessage(`{"url":"http://x"}`)); len(p) != 0 {
		t.Fatalf("declared only: expected no problems, got %v", p)
	}
}

func TestValidateArgs_AdditionalPropertiesTrueAllows(t *testing.T) {
	// When additionalProperties is absent/true, extra keys are fine.
	schema := json.RawMessage(`{"type":"object","properties":{"url":{"type":"string"}}}`)
	if p := ValidateArgs(schema, json.RawMessage(`{"url":"x","extra":true}`)); len(p) != 0 {
		t.Fatalf("expected extras allowed, got %v", p)
	}
}

func TestValidateArgs_Enum(t *testing.T) {
	schema := json.RawMessage(`{"type":"object","properties":{"mode":{"enum":["fast","slow"]}}}`)
	if p := ValidateArgs(schema, json.RawMessage(`{"mode":"medium"}`)); !hasProblemContaining(p, "not one of the allowed values") {
		t.Fatalf("expected enum problem, got %v", p)
	}
	if p := ValidateArgs(schema, json.RawMessage(`{"mode":"fast"}`)); len(p) != 0 {
		t.Fatalf("valid enum: expected no problems, got %v", p)
	}
}

func TestValidateArgs_StringLength(t *testing.T) {
	schema := json.RawMessage(`{"type":"object","properties":{"q":{"type":"string","minLength":2,"maxLength":5}}}`)
	if p := ValidateArgs(schema, json.RawMessage(`{"q":"a"}`)); !hasProblemContaining(p, "less than the minimum 2") {
		t.Fatalf("expected minLength problem, got %v", p)
	}
	if p := ValidateArgs(schema, json.RawMessage(`{"q":"abcdef"}`)); !hasProblemContaining(p, "greater than the maximum 5") {
		t.Fatalf("expected maxLength problem, got %v", p)
	}
	// Length is counted in runes (a 3-codepoint multibyte string is within 2..5).
	if p := ValidateArgs(schema, json.RawMessage(`{"q":"héy"}`)); len(p) != 0 {
		t.Fatalf("rune-length string: expected no problems, got %v", p)
	}
}

func TestValidateArgs_ArrayItemsAndBounds(t *testing.T) {
	schema := json.RawMessage(`{
	  "type":"object",
	  "properties":{"tags":{"type":"array","minItems":1,"maxItems":2,"items":{"type":"string"}}}
	}`)
	// Too few.
	if p := ValidateArgs(schema, json.RawMessage(`{"tags":[]}`)); !hasProblemContaining(p, "fewer than the minimum 1") {
		t.Fatalf("expected minItems problem, got %v", p)
	}
	// Too many.
	if p := ValidateArgs(schema, json.RawMessage(`{"tags":["a","b","c"]}`)); !hasProblemContaining(p, "more than the maximum 2") {
		t.Fatalf("expected maxItems problem, got %v", p)
	}
	// Wrong element type is reported with an index in the path.
	if p := ValidateArgs(schema, json.RawMessage(`{"tags":["a",7]}`)); !hasProblemContaining(p, "tags[1]: expected type string") {
		t.Fatalf("expected indexed item type problem, got %v", p)
	}
	// Valid.
	if p := ValidateArgs(schema, json.RawMessage(`{"tags":["a","b"]}`)); len(p) != 0 {
		t.Fatalf("valid array: expected no problems, got %v", p)
	}
}

func TestValidateArgs_NestedObjectPath(t *testing.T) {
	schema := json.RawMessage(`{
	  "type":"object",
	  "properties":{
	    "opts":{"type":"object","properties":{"timeout":{"type":"integer","minimum":1}}}
	  }
	}`)
	p := ValidateArgs(schema, json.RawMessage(`{"opts":{"timeout":0}}`))
	if !hasProblemContaining(p, "opts.timeout: 0 is less than the minimum 1") {
		t.Fatalf("expected nested-path problem, got %v", p)
	}
}

func TestValidateArgs_UnknownKeywordsArePermissive(t *testing.T) {
	// A schema using features we don't model ($ref, oneOf, pattern, format) must
	// never cause a rejection — critical for third-party (MCP-proxied) schemas.
	schema := json.RawMessage(`{
	  "type":"object",
	  "properties":{
	    "x":{"type":"string","pattern":"^[a-z]+$","format":"email"},
	    "y":{"oneOf":[{"type":"string"},{"type":"integer"}]}
	  },
	  "$ref":"#/definitions/whatever",
	  "patternProperties":{"^z":{"type":"number"}}
	}`)
	// "x" violates the pattern and format, but we don't model those, so: clean.
	if p := ValidateArgs(schema, json.RawMessage(`{"x":"NOT-an-email-123","y":{"deep":true}}`)); len(p) != 0 {
		t.Fatalf("unmodeled keywords should not reject; got %v", p)
	}
}

func TestValidateArgs_TypeAsArrayUnion(t *testing.T) {
	// "type": ["string","null"] accepts either.
	schema := json.RawMessage(`{"type":"object","properties":{"x":{"type":["string","null"]}}}`)
	if p := ValidateArgs(schema, json.RawMessage(`{"x":null}`)); len(p) != 0 {
		t.Fatalf("null in union: expected no problems, got %v", p)
	}
	if p := ValidateArgs(schema, json.RawMessage(`{"x":"hi"}`)); len(p) != 0 {
		t.Fatalf("string in union: expected no problems, got %v", p)
	}
	if p := ValidateArgs(schema, json.RawMessage(`{"x":5}`)); !hasProblemContaining(p, "expected type string|null") {
		t.Fatalf("number not in union: expected problem, got %v", p)
	}
}

func TestValidateArgs_MultipleProblemsAllReported(t *testing.T) {
	schema := json.RawMessage(`{
	  "type":"object",
	  "properties":{
	    "url":{"type":"string"},
	    "max_bytes":{"type":"integer","maximum":100}
	  },
	  "required":["url"],
	  "additionalProperties":false
	}`)
	// Missing required "url", out-of-range max_bytes, and an unknown property.
	p := ValidateArgs(schema, json.RawMessage(`{"max_bytes":9999,"junk":1}`))
	if !hasProblemContaining(p, `missing required property "url"`) ||
		!hasProblemContaining(p, "greater than the maximum 100") ||
		!hasProblemContaining(p, `unknown property "junk"`) {
		t.Fatalf("expected all three problems, got %v", p)
	}
}
