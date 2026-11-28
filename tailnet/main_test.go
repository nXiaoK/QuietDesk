package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNormalizedControlURL(t *testing.T) {
	for _, value := range []string{"", "https://headscale.example", "https://headscale.example:8443/tailnet",
		"https://192.0.2.1", "https://[2001:db8::1]:8443", "http://127.0.0.1:8080", "http://localhost:8080"} {
		if got, err := normalizedControlURL("  " + value + "  "); err != nil || got != value {
			t.Errorf("normalize %q: got %q, %v", value, got, err)
		}
	}
	for _, value := range []string{"headscale.example", "https:///headscale", "http://headscale.example", "http://127.0.0.2",
		"https://user:pass@headscale.example", "https://headscale.example/path?flag", "https://headscale.example/#", "https://headscale.example?",
		"https://headscale.example:0", "https://headscale.example:65536", "https://headscale.example:", "https://head_scale.example",
		"https://2001:db8::1", "https://[192.0.2.1]", "https://[fe80::1%25en0]"} {
		if got, err := normalizedControlURL(value); err == nil {
			t.Errorf("accepted %q as %q", value, got)
		}
	}
}

func TestControlStatePreservesSeparateEnrollments(t *testing.T) {
	base := t.TempDir()
	if got := nodeStateDir(base, ""); got != base {
		t.Fatalf("official state moved to %s", got)
	}
	stateFor := func(value string) string {
		t.Helper()
		control, err := normalizedControlURL(value)
		if err != nil {
			t.Fatal(err)
		}
		return nodeStateDir(base, control)
	}
	custom := stateFor("https://headscale.example")
	if filepath.Dir(custom) != base || custom == stateFor("https://other.example") || custom == stateFor("https://headscale.example/other") {
		t.Fatal("custom control services must have separate private state directories")
	}
	if equivalent := stateFor("https://Headscale.Example:443/"); equivalent != custom {
		t.Fatalf("equivalent control URL selected a different state directory: %s", equivalent)
	}
}

func TestPersistedListenPort(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	type result struct {
		port uint16
		err  error
	}
	results := make(chan result, 4)
	for range cap(results) {
		go func() {
			port, err := persistedListenPort(dir)
			results <- result{port, err}
		}()
	}
	first := <-results
	if first.err != nil || first.port < 1024 {
		t.Fatalf("failed to create a high UDP port: %v", first)
	}
	for range cap(results) - 1 {
		if got := <-results; got != first {
			t.Errorf("concurrent start chose %v, want %v", got, first)
		}
	}
	if reopened, err := persistedListenPort(dir); err != nil || reopened != first.port {
		t.Fatalf("reopened state used port %d, %v", reopened, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "wg-port"), []byte("65536\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := persistedListenPort(dir); err == nil {
		t.Fatal("accepted an out-of-range persisted port")
	}
}
