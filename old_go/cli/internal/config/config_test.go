package config

import (
	"reflect"
	"testing"

	"github.com/goccy/go-yaml"
)

func TestSampleConfigRoundtrip(t *testing.T) {
	projectName := "testProject"
	original := SampleConfig(projectName)

	// Marshal the configuration to YAML.
	data, err := yaml.Marshal(original)
	if err != nil {
		t.Fatalf("Failed to marshal SampleConfig: %v", err)
	}

	envMap := map[string]string{}

	roundTrip, err := parseConfig(data, envMap)
	if err != nil {
		t.Fatalf("Failed to unmarshal YAML: %v", err)
	}

	if !reflect.DeepEqual(original, *roundTrip) {
		t.Errorf("Roundtrip mismatch:\nExpected: %#v\nGot: %#v", original, roundTrip)
	}
}
