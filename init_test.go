package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestEnv(t *testing.T) {
	const key = "HAPROXY_INIT_TEST_VAR"

	if got := env(key, "default"); got != "default" {
		t.Errorf("env(%q, %q) = %q, want default value", key, "default", got)
	}

	t.Setenv(key, "custom")
	if got := env(key, "default"); got != "custom" {
		t.Errorf("env(%q, ...) = %q, want %q", key, got, "custom")
	}

	t.Setenv(key, "")
	if got := env(key, "default"); got != "default" {
		t.Errorf("env(%q, ...) with empty value = %q, want fallback %q", key, got, "default")
	}
}

func TestExists(t *testing.T) {
	dir := t.TempDir()
	present := filepath.Join(dir, "present")

	if exists(present) {
		t.Errorf("exists(%q) = true before file creation", present)
	}

	if err := os.WriteFile(present, nil, 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	if !exists(present) {
		t.Errorf("exists(%q) = false after file creation", present)
	}

	if exists(filepath.Join(dir, "absent")) {
		t.Errorf("exists() reported true for a path that was never created")
	}
}

func TestWriteOK(t *testing.T) {
	dir := t.TempDir()
	if !writeOK(dir) {
		t.Errorf("writeOK(%q) = false for a writable temp dir", dir)
	}

	if writeOK(filepath.Join(dir, "does-not-exist")) {
		t.Errorf("writeOK() = true for a non-existent directory")
	}
}

// VyOS passe `arguments "-W -f ..."`, qui remplace le CMD : sans le nom du
// binaire. L'init doit le remettre, et ne rien toucher a une commande complete.
func TestCommandLine(t *testing.T) {
	cases := []struct {
		in, want []string
	}{
		{nil, []string{"haproxy", "-W", "-db", "-f", defaultConf}},
		{[]string{"-W", "-f", "/x.cfg"}, []string{"haproxy", "-W", "-f", "/x.cfg"}},
		{[]string{"haproxy", "-v"}, []string{"haproxy", "-v"}},
	}
	for _, c := range cases {
		if got := commandLine(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("commandLine(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestConfigFiles(t *testing.T) {
	got := configFiles([]string{"haproxy", "-W", "-f", "/a.cfg", "-f", "/conf.d", "-db"})
	want := []string{"/a.cfg", "/conf.d"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("configFiles = %q, want %q", got, want)
	}
	if got := configFiles([]string{"haproxy", "-f"}); len(got) != 0 {
		t.Errorf("configFiles with dangling -f = %q, want none", got)
	}
}
